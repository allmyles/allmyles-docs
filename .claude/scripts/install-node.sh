#!/usr/bin/env bash
# install-node.sh — hardened, provider-resilient Node.js installer for consumer
# Docker image builds. Shipped by claude-kit (INF-246, hardened by INF-248).
#
# WHY: the ubiquitous `curl -fsSL https://deb.nodesource.com/setup_XX.x | bash -`
# pattern couples every image build to NodeSource's *setup-script* endpoint
# being reachable AND returning 200, and executes a remote script as root at
# build time. On 2026-07-27 that endpoint began returning HTTP 403 globally
# (NodeSource has signalled deprecation of the legacy setup_XX.x scripts),
# which broke mileometer's master deploy at the "Build Docker images" step —
# every consumer using this pattern is exposed to the same single point of
# failure. This recipe removes the remote-bash coupling and adds a
# non-NodeSource fallback so one provider outage cannot block builds.
#
# STRATEGY (two tiers, fail loud, never `curl | bash`):
#   1. PRIMARY — NodeSource *apt keyring* method: fetch the NodeSource GPG key
#      into /usr/share/keyrings/, write a pinned apt source (node_<MAJOR>.x),
#      `apt-get install -y nodejs`. No remote script execution; a bad key or a
#      403 on the apt repo fails the step instead of silently running.
#   2. FALLBACK — if ANY part of the NodeSource path fails, install the official
#      nodejs.org binary tarball (arch-aware). Integrity is established in
#      descending order of strength:
#        (a) NODE_FALLBACK_SHA256 — caller-pinned exact hash (zero external
#            trust; strongest, no network beyond the tarball itself);
#        (b) SHASUMS256.txt whose detached GPG signature (SHASUMS256.txt.sig)
#            is verified against a KIT-BUNDLED Node release keyring embedded in
#            this script (INF-248) — no keyserver is contacted at runtime;
#        (c) NODE_DISABLE_GPG=1 — explicit opt-out that trusts the TLS-served
#            SHASUMS256.txt without signature verification (pre-INF-248
#            behavior; use only when gpg is unavailable and a pin is not).
#
# USAGE (Debian/Ubuntu-based Dockerfile; run as root at build time):
#   COPY .claude/scripts/install-node.sh /tmp/install-node.sh
#   RUN /tmp/install-node.sh            # defaults to Node major 22
#   RUN /tmp/install-node.sh 20         # or pin another major positionally
#   # The Node release keyring is EMBEDDED in this script — copying this one
#   # file is sufficient; there is no sidecar keyring to keep in sync.
#
# PARAMETERS (positional arg wins over env; env over default):
#   $1 / NODE_MAJOR            major channel (default: 22) — NodeSource
#                              node_<MAJOR>.x + fallback tarball major line.
#   NODE_FALLBACK_VERSION      exact nodejs.org version for the fallback tarball
#                              (default: latest <MAJOR>.x resolved at runtime
#                              from nodejs.org/dist/index.json). Pin it for a
#                              fully reproducible fallback.
#   NODE_FALLBACK_SHA256       optional; when set, the tarball is verified
#                              against THIS value instead of the fetched
#                              SHASUMS256.txt (strict supply-chain pin — the
#                              strongest path; skips the GPG step entirely).
#   NODE_DISABLE_GPG=1         skip GPG-signature verification of SHASUMS256.txt
#                              in the fallback tier and trust the TLS-served
#                              checksum file directly (pre-INF-248 behavior).
#                              Ignored when NODE_FALLBACK_SHA256 is set (a pin
#                              is already stronger). Use only when gpg cannot be
#                              installed and a hash pin is not available.
#   NODE_DISABLE_FALLBACK=1    fail immediately if the NodeSource path fails,
#                              instead of trying the tarball (for callers that
#                              require the apt/nodejs package specifically).
#
# The installer is idempotent-friendly: it does not `apt-get upgrade`, only
# installs nodejs (+ npm) and leaves global npm packages to the caller.
set -euo pipefail

NODE_MAJOR="${1:-${NODE_MAJOR:-22}}"
NODE_FALLBACK_VERSION="${NODE_FALLBACK_VERSION:-}"
NODE_FALLBACK_SHA256="${NODE_FALLBACK_SHA256:-}"

log()  { printf '[install-node] %s\n' "$*" >&2; }
die()  { printf '[install-node] ERROR: %s\n' "$*" >&2; exit 1; }

# Validate the major is a bare integer — it is interpolated into an apt source
# URL and a tarball path, so reject anything that is not digits (no injection
# via a stray NODE_MAJOR).
case "$NODE_MAJOR" in
  ''|*[!0-9]*) die "NODE_MAJOR must be a positive integer (got: '${NODE_MAJOR}')" ;;
esac

require_root() {
  # apt + writing to /usr/share/keyrings + /usr/local needs root. In a
  # Dockerfile RUN this is root already; guard so a mis-invocation fails loud.
  if [ "$(id -u)" != "0" ]; then
    die "must run as root (apt + /usr/share/keyrings + /usr/local writes)"
  fi
}

ensure_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # ca-certificates + curl + gnupg are needed by BOTH tiers; xz-utils for the
  # fallback tarball. gnupg also backs the INF-248 SHASUMS256.txt.sig check.
  # Installing them up front keeps the fallback usable even if the NodeSource
  # tier partially ran.
  apt-get install -y --no-install-recommends ca-certificates curl gnupg xz-utils
}

install_via_nodesource() {
  log "PRIMARY: NodeSource apt keyring method (node_${NODE_MAJOR}.x)"
  # CR round 1.1 (Major): `set -e` is SUPPRESSED when a function runs as an
  # `if` condition, so an intermediate failure here would NOT abort — the
  # function would return its LAST command's status, masking (e.g.) a 403 on
  # the key fetch behind a successful `apt-get install`. Make every step
  # propagate explicitly with `|| return 1` so the caller's fallback triggers
  # on ANY primary-tier failure, regardless of the `if` context.
  install -d -m 0755 /usr/share/keyrings || return 1
  # `set -o pipefail` (from set -e above) makes a 403 on the key URL fail the
  # pipe; `|| return 1` propagates it even in the if-condition context.
  # `--batch --yes`: `gpg --dearmor -o <file>` PROMPTS (and fails non-
  # interactively) if the target already exists — so a re-run, or a base image
  # that already seeded the keyring, would break the primary tier. --yes forces
  # the overwrite; --batch keeps it non-interactive. (CR round 1.1 on PR #97.)
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/nodesource.gpg || return 1
  # `nodistro` is NodeSource's distro-agnostic suite name for the node_XX.x repos.
  printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
    "$NODE_MAJOR" > /etc/apt/sources.list.d/nodesource.list || return 1
  apt-get update || return 1
  apt-get install -y nodejs || return 1
}

resolve_fallback_version() {
  # If not pinned, resolve the newest published <MAJOR>.x from nodejs.org's
  # index. Kept dependency-free (no jq in a minimal base): grep the version
  # strings and pick the highest matching major via sort -V.
  if [ -n "$NODE_FALLBACK_VERSION" ]; then
    # CR round 1.1 (Major): a pinned fallback version must be the SAME major as
    # requested, or the fallback would silently install a different Node line.
    local pinned="${NODE_FALLBACK_VERSION#v}"
    case "$pinned" in
      "${NODE_MAJOR}".*) printf '%s' "$pinned"; return 0 ;;
      *) die "NODE_FALLBACK_VERSION='${NODE_FALLBACK_VERSION}' is not major ${NODE_MAJOR} (set NODE_MAJOR to match, or fix the pin)" ;;
    esac
  fi
  local idx
  idx="$(curl -fsSL https://nodejs.org/dist/index.json)" \
    || die "fallback: could not fetch nodejs.org/dist/index.json"
  printf '%s' "$idx" \
    | grep -oE '"version":"v'"${NODE_MAJOR}"'\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*"v([0-9.]+)".*/\1/' \
    | sort -V | tail -1
}

node_arch() {
  # Map dpkg arch → nodejs.org tarball arch token.
  local a; a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    amd64|x86_64)  printf 'x64' ;;
    arm64|aarch64) printf 'arm64' ;;
    armhf)         printf 'armv7l' ;;
    ppc64el)       printf 'ppc64le' ;;
    s390x)         printf 's390x' ;;
    *) die "fallback: unsupported architecture '$a'" ;;
  esac
}

# Verify SHASUMS256.txt against its detached signature (SHASUMS256.txt.sig)
# using the kit-bundled Node release keyring embedded in this script (INF-248).
# No keyserver is contacted at runtime — the trusted keys travel with the file
# (see emit_node_keyring below; regenerate via refresh-node-keyring.sh). On ANY
# failure this dies (supply-chain guard): a mismatched/absent signature or a
# key the bundled ring does not carry must NOT fall through to trusting the
# checksum. Isolated in an ephemeral GNUPGHOME so the caller's keyring is never
# touched or trusted.
verify_shasums_signature() {
  local ver="$1" sums="$2" tmp="$3"
  command -v gpg >/dev/null 2>&1 \
    || die "fallback: gpg is required to verify SHASUMS256.txt.sig but is not installed (install gnupg, or set NODE_FALLBACK_SHA256 to pin the hash, or NODE_DISABLE_GPG=1 to skip verification)"
  curl -fsSL -o "${sums}.sig" "https://nodejs.org/dist/v${ver}/SHASUMS256.txt.sig" \
    || die "fallback: could not fetch SHASUMS256.txt.sig (set NODE_FALLBACK_SHA256 to pin the hash, or NODE_DISABLE_GPG=1 to skip)"
  local gnupghome; gnupghome="$(mktemp -d)"
  chmod 700 "$gnupghome"
  # Import the bundled ring into the ephemeral home; clean it up on every path.
  if ! emit_node_keyring | GNUPGHOME="$gnupghome" gpg --batch --quiet --import >/dev/null 2>&1; then
    rm -rf "$gnupghome"
    die "fallback: could not import the bundled Node release keyring (INF-248)"
  fi
  if GNUPGHOME="$gnupghome" gpg --batch --verify "${sums}.sig" "$sums" >/dev/null 2>&1; then
    rm -rf "$gnupghome"
    log "integrity: SHASUMS256.txt GPG signature verified against bundled Node release keyring"
  else
    rm -rf "$gnupghome"
    die "fallback: SHASUMS256.txt.sig did NOT verify against the bundled Node release keyring (supply-chain guard). If Node rotated its release keys, refresh the bundle with refresh-node-keyring.sh; to override for this build, set NODE_FALLBACK_SHA256 (a hash pin) or NODE_DISABLE_GPG=1."
  fi
}

install_via_tarball() {
  local ver arch tarball url tmp
  ver="$(resolve_fallback_version)"
  [ -n "$ver" ] || die "fallback: could not resolve a Node ${NODE_MAJOR}.x version"
  arch="$(node_arch)"
  tarball="node-v${ver}-linux-${arch}.tar.xz"
  url="https://nodejs.org/dist/v${ver}/${tarball}"
  log "FALLBACK: nodejs.org binary tarball v${ver} (${arch})"
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/${tarball}" "$url" \
    || die "fallback: download failed: ${url}"

  # Integrity: prefer a caller-pinned SHA256; else verify against the
  # SHASUMS256.txt published next to the tarball, whose detached GPG signature
  # is checked against the kit-bundled Node release keyring (INF-248) before
  # any checksum in it is trusted.
  local expected
  if [ -n "$NODE_FALLBACK_SHA256" ]; then
    expected="$NODE_FALLBACK_SHA256"
    log "integrity: caller-pinned NODE_FALLBACK_SHA256 (strongest path)"
  else
    local sums="${tmp}/SHASUMS256.txt"
    curl -fsSL -o "$sums" "https://nodejs.org/dist/v${ver}/SHASUMS256.txt" \
      || die "fallback: could not fetch SHASUMS256.txt"
    if [ "${NODE_DISABLE_GPG:-0}" = "1" ]; then
      log "WARNING: NODE_DISABLE_GPG=1 — trusting TLS-served SHASUMS256.txt WITHOUT GPG verification. Set NODE_FALLBACK_SHA256 to pin the exact hash for zero-trust integrity."
    else
      verify_shasums_signature "$ver" "$sums" "$tmp"
    fi
    expected="$(awk -v f="$tarball" '$2==f {print $1}' "$sums")" \
      || die "fallback: could not read checksum from SHASUMS256.txt"
  fi
  [ -n "$expected" ] || die "fallback: no expected checksum for ${tarball}"
  printf '%s  %s\n' "$expected" "${tmp}/${tarball}" | sha256sum -c - \
    || die "fallback: checksum mismatch for ${tarball} (supply-chain guard)"

  # Extract into /usr/local (strip the top-level node-vX dir → bin/, lib/, …).
  tar -xJf "${tmp}/${tarball}" -C /usr/local --strip-components=1 \
    --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
  rm -rf "$tmp"
}

# Boolean: is a working `node`/`npm` present AND is `node` the requested major?
# CR round 1.1 (Major): existence alone is not enough — a distro/preinstalled
# node could satisfy `command -v node` while resolving to a DIFFERENT major,
# making a requested Node 22 install report success on Node 18. Checking the
# major here (returning non-zero on mismatch) lets the PRIMARY tier's mismatch
# route into the fallback instead of silently accepting the wrong runtime.
node_major_ok() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm  >/dev/null 2>&1 || return 1
  local got; got="$(node --version 2>/dev/null)"   # e.g. v22.5.1
  case "$got" in
    v"${NODE_MAJOR}".*) return 0 ;;
    *) log "installed node ${got:-<none>} != requested major v${NODE_MAJOR}.x"; return 1 ;;
  esac
}

node_report() { log "installed node $(node --version) / npm $(npm --version)"; }

# ── Kit-bundled Node.js release keyring (INF-248) ─────────────────────────────
# Emits the ASCII-armored public keys used to verify SHASUMS256.txt.sig in the
# fallback tier. PROVENANCE: the fingerprints below are the "Release keys" list
# published in the nodejs/node README; each armored key was fetched by that
# fingerprint from keys.openpgp.org (a by-fingerprint lookup returns exactly the
# key with that fingerprint). No keyserver is contacted at RUNTIME — the keys
# travel embedded in this script. REFRESH: Node rotates this set over time; run
# refresh-node-keyring.sh to regenerate the block between the generated markers
# below. Do NOT hand-edit the key blocks.
emit_node_keyring() {
  cat <<'NODE_RELEASE_KEYRING_EOF'
# >>> BEGIN GENERATED NODE RELEASE KEYRING (refresh-node-keyring.sh) >>>
# Node.js release key 5BE8A3F6C8A5C01D106C0AD820B1A390B168D356
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 5BE8 A3F6 C8A5 C01D 106C  0AD8 20B1 A390 B168 D356
Comment: Antoine du Hamel <antoine.duhamel@platformatic.dev>
Comment: Antoine du Hamel <antoine.duhamel@rosa.be>
Comment: Antoine du Hamel <duhamelantoine1995@gmail.com>

xjMEaGA63BYJKwYBBAHaRw8BAQdAo/yU+MutacFmmn0CEX495goNrBxR24235XLM
cvHYjfrNM0FudG9pbmUgZHUgSGFtZWwgPGFudG9pbmUuZHVoYW1lbEBwbGF0Zm9y
bWF0aWMuZGV2PsKOBBMWCgA2FiEEW+ij9silwB0QbArYILGjkLFo01YFAmmwIzEC
GwMECwkIBwQVCgkIBRYCAwEAAh4BAheAAAoJECCxo5CxaNNWv+wA/AgGwbyDo0PO
g1FNfXA8oG99mDU0/u1gLIzmzFB+um4sAQDTkCEbjEEgt+Ev9/SmpHmNd/GDqDNP
pZ95V5LrN4dnB80qQW50b2luZSBkdSBIYW1lbCA8YW50b2luZS5kdWhhbWVsQHJv
c2EuYmU+wo4EExYKADYWIQRb6KP2yKXAHRBsCtggsaOQsWjTVgUCaGA8IAIbAwQL
CQgHBBUKCQgFFgIDAQACHgUCF4AACgkQILGjkLFo01YijwD/Y+EluykekiXjDgnH
Yx/FvaVQ0+d/XkylzTgBHi/yORsBAMFOTpJm6j9Gh/CJwAPof0U4ln/t6UWdt1CD
lfa49IAMzS9BbnRvaW5lIGR1IEhhbWVsIDxkdWhhbWVsYW50b2luZTE5OTVAZ21h
aWwuY29tPsKOBBMWCgA2FiEEW+ij9silwB0QbArYILGjkLFo01YFAmhgOtwCGwME
CwkIBwQVCgkIBRYCAwEAAh4FAheAAAoJECCxo5CxaNNWn4MBAP7Cx6rI+5pdr8g6
EygzxPJ/WvNGTodeDn55TntHAmQPAQDBDjpO0BSOvQyJVdZzIqnBQqkBaEswVNi5
CEde6f4+Dc44BGhgOtwSCisGAQQBl1UBBQEBB0BBWa2KHwA7evIFAxH/bbFYdUou
MBsKIfZwzE0f6LLVFAMBCAfCeAQYFgoAIBYhBFvoo/bIpcAdEGwK2CCxo5CxaNNW
BQJoYDrcAhsMAAoJECCxo5CxaNNW7ygA/0Fz5Bj70WKRfdi8yBYCqIOVU7KjTLpQ
hkYExJCUXzTAAP93fguq1UhV72h7k07fEDvn7oTDy0Z4CNSr+i9qCvl0BQ==
=3wed
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key DD792F5973C6DE52C432CBDAC77ABFA00DDBF2B7
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: DD79 2F59 73C6 DE52 C432  CBDA C77A BFA0 0DDB F2B7
Comment: Juan José Arboleda <soyjuanarbol@gmail.com>

xjMEZAFttBYJKwYBBAHaRw8BAQdA9UUQNclFp0rIrgtQnNw6BgjDINkFPoVbuS4H
sQNEf+fNLEp1YW4gSm9zw6kgQXJib2xlZGEgPHNveWp1YW5hcmJvbEBnbWFpbC5j
b20+wpMEExYKADsWIQTdeS9Zc8beUsQyy9rHer+gDdvytwUCZAFttAIbAwULCQgH
AgIiAgYVCgkICwIEFgIDAQIeBwIXgAAKCRDHer+gDdvyt3PYAP9A8XbvZYT+N7k9
2xnRMfrAUep6TLfWbx9uf7k/hm/+KAEAmqUYV1afcuwU2xXE5I8m25VMnCEKFFEF
52tW2baWkQXOOARkAW20EgorBgEEAZdVAQUBAQdAtwscgbxby3vew2hn9F+KlVPL
vFBPjnvODcnsqlO2mXQDAQgHwngEGBYKACAWIQTdeS9Zc8beUsQyy9rHer+gDdvy
twUCZAFttAIbDAAKCRDHer+gDdvytzxaAQDvYX4o1Y6R30bYwIXemGgbO8GlCkgk
5it7MjeSk8vUygEApE5zIi5OtP8TlPiMgu2MoJbIltqqDCKWTtHPIQRNIwk=
=KIdF
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key CC68F5A3106FF448322E48ED27F5E38D5B0A215F
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: CC68 F5A3 106F F448 322E  48ED 27F5 E38D 5B0A 215F
Comment: marco-ippolito <marcoippolito54@gmail.com>

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
ZWf0a3VP6Gco5bmDPhvGoLEs9Vw5
=ITi7
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key 8FCCA13FEF1D0C2E91008E09770F7A9A5AE15600
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 8FCC A13F EF1D 0C2E 9100  8E09 770F 7A9A 5AE1 5600
Comment: Michaël Zasso (Targos) <targos@protonmail.com>

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
ZXqeJswewa5J+KdH/lE=
=cWHZ
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key 890C08DB8579162FEE0DF9DB8BEAB4DFCF555EF4
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 890C 08DB 8579 162F EE0D  F9DB 8BEA B4DF CF55 5EF4
Comment: RafaelGSS <rafael.nunu@hotmail.com>

xsDNBGKD3OQBDAC3ESxNd7dHfM7Hl3sE7Xn2osS4UZkJtmXA7hdbfybzf164wCbL
cYECq0GrGfgdnKEMWNzr2S08KkUWQwJZd70Jt1voVpqWVXdtBH/KxGwifixMkTEy
lu0ePvJM7L5HNOIZP5njcAU03hKgIibYQW+SWj/G37yfdyNprN2uX8p4CUyJbnBc
YOZ2W1tUzNsddvTV03JlDmfR5kwHoi5sTCqvQWTzsIQn/vGHxMqa3XjabfSvim1A
ytE1J7VIiu7P9hW1prEfUVY5+ggswUCfJl4A4WcCwFLIaIdOreiakAix7Hn5AD4D
lyskTzDy6QRpzFVm6YyrKzUzggqa+bQ5/9aq8LdKVim/f/LmEuSQdwkEt0rOWhAX
YJQrnJT8IFLqmgnJEygGkwcdXOBGRERRB8Mes0rfrgYHYW0WqGI5fMxyL1Ti9w+0
AH6QFq1IoWZY8bzGk1bJe57lgJrshavpSc1ftKTqsFAoLYDsMF6lxkNyS7+OZMIx
U9hbvuJgdPj7/lUAEQEAAc0jUmFmYWVsR1NTIDxyYWZhZWwubnVudUBob3RtYWls
LmNvbT7CwRQEEwEKAD4CGwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AWIQSJDAjb
hXkWL+4N+duL6rTfz1Ve9AUCZowKYQUJB8qUfQAKCRCL6rTfz1Ve9OI7C/9mQxcc
g/oZxn4QlxWaNjqrLLjDt5D64BMFWlqAIg+9OiABF3dAAYdkRLvQ4Wxq2xHauf2z
du1pbCdKxO4lhGDVbMjKgCvfjH21foORH/ZR/daOt9lc3ywFGg9WMN4Vlt9+cO4f
dENOMMNpDVPWiIZ0VPJZcFNXtHmBgT3CmKjVZQUDUerhp6qaRxkMqUdVnYfieUKX
lDdviMKQoVHmzaDlexgvsKyCX6NzjCBKsigOQeC+hqt3AdyN3IG2sBAVBrMGvqN2
MXfgebr1ZDJnC0Y0hA6zAeyzKrR5vrzB7oDQAl2Jze9e0hinjtcCGOo7+Xna6Dm2
GP2Gj04hNSk6JXARU03KZWnMryRqQCDNxfdHy9ShmPAD3PuH/g/VCQMeQsB1S1H+
m/XVp2I+G/fZj6L7iZpR5URbYQFSSL7UIVjyFTymU8e8PkkRqXDI0nboaZBVikbl
FmYAINtsVJLHY70lAZ+0BJCGs9QIETguxFtsofRw3pqnuy93FKV2/T2wJUbCwRQE
EwEKAD4WIQSJDAjbhXkWL+4N+duL6rTfz1Ve9AUCYoPc5AIbAwUJA8JnAAULCQgH
AgYVCgkICwIEFgIDAQIeAQIXgAAKCRCL6rTfz1Ve9IWOC/0bSb8LUFtOXaV87UTk
fNHqe+0JIbZh9kpFKX5E8PSIkRUAMH+yJbx+tw+6OKWf1Ofu4NU4Kc6T2wXqH8k0
XF0mIYlJf6sZWrrqYVcyPLKGmGHXrMfywg8QGlPhD2ZHrVermfVMfA40v/1QpHAO
fW2OZpJq/7GlrXrpaXK/BCjO0GBQu1omQwe/NPBXIHeSyamR6iexWvcEWszAdcCK
aQrRMVZdJ7v3OGG/KtviW5c1qH97gfulrOgqQ9Phj5ABu1yD55AHSXlhRUcWzAeT
YdvzNDT+PYC9IPaAHg05tRfl8tlX+CdZU41cQKKIhypPgxlxsR6zmWb2FinuKDeH
tb7gcUqBhrxXbqQDfcWf9YxdTtbbxnObQ2vhWbscftVOBDieXFEZvNCv2fz/uYHT
WGew4Sio1esgE88yWBSE55liZgBKdh2LgYOr5kWnr1eoGjgukd2cRv+HOJYSxwyf
BTjT7lTFuPz02t89JEt1AgmyLwWfvPwu3IsbkLZNgDnoshnOwM0EYoPc5AEMAN+Z
6DX1O0fLkt0lq+N70gmO+AlFI9l4L2HKBiPCMMPCXP/iX/04zVzm6n3rl5ypNo+Q
4um6eGwL9UGrzUJSwcD0nsvK8U+SVyDpp8e3i4+ph2XRiC5Bkktfgye2vTAgE9cl
qnDpQGnaQ689gOd9nPQAUqNXnibuZsnETusbu/+HQDqM4wdSxTGXQ4PaqjmyATeU
cTVwh8bzdBOLZ8O2eilFgNhY30cycxevI68SnLzPz7riXTQo0pKbf6hvK5kn3nUL
n5l7b+QFtuVbffe9vo3J3OT8lEX9Cvd73y01fgDRXs5j1Zbg5OaOMXqMthbndq+e
nlhkD4vyCF07LkuHBk8lMX1yUVysMx/iqN7YS/2ZEMkJt095Q/6DcNigEUpTvgtP
JYxHam1uXQb3Ellhap/YeCkkgOs2FOeytaIR8na/A7TjPwOM6v/tar+ENQDF1nCh
rqhlLin9j+kyiwkTypWJ0kmyU58fZGvlSh1JfjVNaMuM4f6xoFQFb88Au4p8swAR
AQABwsD8BBgBCgAmAhsMFiEEiQwI24V5Fi/uDfnbi+q0389VXvQFAmaMCowFCQfK
lKgACgkQi+q0389VXvSQBQwAsMvjMThyU14b/Ba3zfC4fqtBd17lRExTlyCpjJj7
Kt8tiFSM1Yq0M30ndQtZY2+tpiX8iyjgWPYpcbNgm6T3jOFV1tgtp2m7bYiGTqa7
o0VQEcdu+52GqNmrLv7aLZGoCM8kNWaRGyi32433EWdz6b+1cfT8H7lIrLKvBdwr
OV5q1XMQLf2DDNLQUhLqGb6qE6EG9/Rw4e8uc10w3wz0xr3Le1+FlrC1KFC0XaHo
BCW0gNq7tK0gG+aaASIXg8qQS/cT3Tf00jq/M7j4Vl6QwOsOwZw1hn/ydBQfK3Tv
+Hxe060vWehIyc/nfnw9oo4AetNKQqieNFjfh7CHhAIaTVDisc130rQWJtTmloRB
oXA0uwLc6dIvIWi1hL7KgEI55zSeXUdFIpwWjRcNxdiLQ46GagtVMj+1hz8EOU7J
3vY04ZRHDyapCRYoRXd/N8MUnsZ/ySRdA/Sk57Ujn9UH3nFEhD6AH9y08K6zB4JF
N7saJiCj2Q7W2nXuEUhRVs2KwsD8BBgBCgAmFiEEiQwI24V5Fi/uDfnbi+q0389V
XvQFAmKD3OQCGwwFCQPCZwAACgkQi+q0389VXvSWogv/aha894ratff+Dxq9bCvc
l6n+HNRh6vAiDlaLM5c8S2B4qA1BvlylavjGuVy/lQyr4NYl7CeMn7aRB9/am2Hi
It7dSI6Mjsv0lXTzIXQgGjyrK14rO6HgB9TI22H+8W2g+zzWR3RQ76NyVnHHil0Y
eHpj4LpZbFNTKUpAOjv1vopWe7gkkjGFTw4rtZqLbXOYtcQWvb00x/UG928konaK
wpNELX5wKPxxsOPpGciKSS8Oq/K5KGTmnafJgObQgwB6AwrL2wBfuGTXQAMMs4PN
48xAijskGjuGFxarBM/CvZ83L1OqRB+0g6T0Z1gHpq1s7t2WybE7KZh21yQuWN42
QH6HLk7Gzbx9HodmUrdHoqPhzXfnmMtlCXefdyYDPvFjwEn7w1P8wey/USOQAEyb
YQKbWzSdZO6LnLNFwBaN3+PyItW97aNoeiJRtDFaNggTICHCcPlope/4LYkrLQjP
X35+Mt0c0N1iYrLUzLmu1v56i/h6AgpNU4VXo+mHhSxK
=aMvn
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: C82F A3AE 1CBE DC6B E46B  9360 C43C EC45 C17A B93C
Comment: Richard Lau <richard.lau@ibm.com>

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
jDQRthc=
=eqPG
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key 108F52B48DB57BB0CC439B2997B01419BD92F80A
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 108F 52B4 8DB5 7BB0 CC43  9B29 97B0 1419 BD92 F80A
Comment: Ruy Adorno <ruyadorno@hotmail.com>

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
=jjU8
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key 655F3B5C1FB3FA8D1A0CA6BDE4A7D232B936D2FD
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: 655F 3B5C 1FB3 FA8D 1A0C  A6BD E4A7 D232 B936 D2FD
Comment: Stewart X Addison <sxa@ibm.com>

xjMEakIjcxYJKwYBBAHaRw8BAQdAYRFWvBCAd9dDjKTePuAvvzAWxhvojAXco0m4
2AMh/MDNH1N0ZXdhcnQgWCBBZGRpc29uIDxzeGFAaWJtLmNvbT7CmQQTFgoAQRYh
BGVfO1wfs/qNGgymveSn0jK5NtL9BQJqQiNzAhsDBQkDwmcABQsJCAcCAiICBhUK
CQgLAgQWAgMBAh4HAheAAAoJEOSn0jK5NtL9FOEBAMpIjknm4fnEQvTmIlzy0kDu
VplF4HR78+lBef2i4590AP9i82wtP4pH1/vynoSBMkCauFIPmF1c9MYLFF0f53zq
As44BGpCI3MSCisGAQQBl1UBBQEBB0AVa1WJ4P8ir/M7NaCGrX7PDs0QU9qzpzme
a5TZ44b/YgMBCAfCfgQYFgoAJhYhBGVfO1wfs/qNGgymveSn0jK5NtL9BQJqQiNz
AhsMBQkDwmcAAAoJEOSn0jK5NtL9EzYA/Arr4hbKLaU6OUjAVbH7HGLEl0HSvxE8
5lEgWfuNbqOtAQCF9UT0wQEfiIj2R358Ce62zV43w2yaD8Xu0M/S+hz8AQ==
=Lb6H
-----END PGP PUBLIC KEY BLOCK-----
# Node.js release key A363A499291CBBC940DD62E41F10027AF002F8B0
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: A363 A499 291C BBC9 40DD  62E4 1F10 027A F002 F8B0
Comment: ulises Gascon <ulisesgascongonzalez@gmail.com>

xsFNBF0VqLoBEACiPJYKX/UT5OFnucsBQqSmFNPsRD6JaClRqNe8wQfOZKFNLyat
jtNj2Bvuq2wDTdKSiwcT3PWtPCEVEQ5i4MMzwmnflAV4KTtj8mLCGTR3ighnf9kF
hBdX+G4I3lQ2rIAc7ie+sI67zFmsAC7wFTw06DrB18vxl5uX7H5UqDXLsOQKE3+D
Q2SsygI+JsCanaZ+kk6pxgflNDlWj5uRIPe82Cwxg0gS0aQKX5m//diavfhlPmuo
YaQioe8/b6Bo9re7opWhtEFfYyGUxaRxVTLoMRwWcacspwqHcGe+rp88YmLMUXDh
PLmgGw8aAsf+b6Wcj12zPusny1sJoG7zwm37a98blyCoYFzx/xTG6gq/RLud/xdU
OOOhPGMH9wQK9ngVYG3Wr+LWU0ABrUBayY1wE3QBj7wYkoK6BEYknzkzm7y4tO2j
rv/9dxV8kt8zUEDwUq01Uj3TDe3YAbbYhXTVIXFwVarCM4AmdIrvKbJZz0JWCIA9
6M3NVyIJHqY2KYsm/YWsWMDqieLQci5M78o3wSdr4vsbvTRRGnmpEXw5cU16qY+/
npWm3R2H4o3IV9qRrrcYTgMdS6QohCV3qBeTRCdy7n3YB6X78ITIo/I9ogGG2nrs
i+mj0R6F39Y6Y/KQzDM1ECWjsk4pxdK71JGXWZWersmI8rymbtd/WT+UKwARAQAB
zS51bGlzZXMgR2FzY29uIDx1bGlzZXNnYXNjb25nb256YWxlekBnbWFpbC5jb20+
wsGUBBMBCAA+AhsDBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAFiEEo2OkmSkcu8lA
3WLkHxACevAC+LAFAmg9l54FCRDLiWQACgkQHxACevAC+LAE/g/7BmvYINuaFeQX
HjGRXVfkcXojrNKF5/co5XpvxaNl50UOrq+tInUg23/Q2ES76VMgONUIgIUqP71d
/09D/dehFnEeHCJhflCMjAbuZPTovjyfTPPwqKQUMLl+P4z7QAq4HKiuqP6hQW0r
IDsRsiODmDGMXgxA3O8tIphUmgQJi1GhiZXRZh8kNAo3d4pbkhoBXXXlgm+vJVu6
hcf2KCjciNrsqw+V9oNq8LyZytpKBdYprph6eCvaiGlGUk6PMzM+6tNBPbYJPt0v
yVQTGvfZrHe1auEjbh/oFColO/UgHfyAKe3yc+AnKuUWyLei+imz0fTio7Oj5d5C
5HTUQCaWTwEM0sODb05zI9EHjkpzRHyTwEuZM9gO+by5M9M8pxJ60wrUrftOgDMe
Km8+lIXmz6mYgfoOFHAzozwQDjfSCT1Fq30pWcCb3UiBb/zYV/N1CTqjnoEmHXiB
5dSrEzNDBmSIVvJpbY1sokOfxD8PNi0kcvNiZnxZg+ogECjPKtPx5VbEr0FYZEW7
QddAM163jfxmnLdYdtst9CxSqB6uMiz9F1ybMp8H4QE4wbmdGziqqebRV0m4EOiJ
rJWmJnWFzaScG1dGU+Ez3ICL3Q4JHfHiQi8tu6rRUa7nCBtA28h43H+uIoHqapOZ
Ow/ZPZtFApgGgnLyN6VT38mTgIuRq5bCwZQEEwEIAD4CGwMFCwkIBwIGFQoJCAsC
BBYCAwECHgECF4AWIQSjY6SZKRy7yUDdYuQfEAJ68AL4sAUCZHme/QUJCyZdQwAK
CRAfEAJ68AL4sFb+EACOc8YAcl6I3uGnRAhiu0F4tUI+ls0W+1FgMTZItkCH7Yg5
BLsu5arxs/Jn5YtEuV2Q2RipC2RJtNf/MKtJ94ubrljZQ3Ha3UApwq4qojiIm4mM
BlK+gKnewX76axyauXU+WC0cmpTTAhTYPpFFNG80J3aWIJa6gbuMvqnfvuA3Spwx
/SOsmUfnpKVFc11Tf1pE+1KcvvoKlAN2Xx/xNGT6GTsgxNWNCFpDVomSV5tnNd6g
HT1/k6nnefrC11NqzqSwy6DLNjijFZ0jn6tJFZThg2r2RQC5RZvXoM448+aeBN4k
zr3D16ojbXvCMpqHuU2PkZUgLjw7wVSaUbe1xUv5OmseprV+4R7t6FRIcc2yfRA9
LUdh44bmdGBJ1yxiP+eFay+NqNiK7LYo3Z/Rbcdc/KLttR6wB6l4BLZ31VP0Dm7J
Sk5VK9LlsBleifYkldI14e4GkA3qR9C23YLyiAEeUi+bd/yW1wirCFxoplx0pwCr
Hi+Gr5EgLWDia/ODfQh3ZJfRI37efaMmRqjN4FyGvQaIyqCu9/Qv9MNE9JZSw93m
9/2kK84lH+LyCoqDmFN1WlRs+FSc7PpR401bmthtruj1zDmvwxZOB/xmSdPE2R6R
3JO9S0DqvVuNhbv4sntegLXY9tNJzfBKFkcPm84WJkOg7TzYkOE5eyLN4aG7mMLB
lAQTAQgAPgIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgBYhBKNjpJkpHLvJQN1i
5B8QAnrwAviwBQJgthu8BQkHYtoCAAoJEB8QAnrwAviw9SsP/0VnbVs2BDS9BzzR
8mjF7xcGGXgUJosusaDRmNHfGBgnH0SKH8TOql295TyGwzJyI4yUf/snq5YL6tUf
5rPDFf+YqIfWkIJZ0lqxGzDqFXxV0Q1IxrxMaLDKZ0sFsV2fxXFRhpuvzGWkn7Gb
e0EjWcHlI1a3gvdDpXV0HiH0ZwD1VAq57mooCr2UQH5A5IKgd5Kzy7z6gxBeNw5w
q/gnxwkqON7WpAg4CXlEldL+xpS6sLTfB4apPCOOfjYL3dQTvatKZswm5UdYTgk/
GO6Zqky2PZzRuXnoJ2vEDNTjNKtH33hRGLBrQDfYeAsrqQClrwJTK7cN40CC7Dh5
Z23qcyuRo5SZZP6jC8VLf5+svFv+PQUZmZ+vojp8XzdGuXxCa7eeToHJOclgyA41
Mf0LJmJuaMT/3V1FHl26awrjB4RLBnDo0ULtAMFLhP29suc88BEO1HuDlV2SoJvx
muLyPdyA+i0r5zHxROwctQygHBaHVFX8ZSwG5+ZH7Daz08/tHk9J8mt3tR4jaBV8
rn8RXaqg5lNcnXL28YSe3f7vsWzkODPEufR1dx4tvdCKM/Qpc4KUV9UIooX/QAeD
U0URc+9x09CU7Ue7rh87v+a2riG3s9fNRGK5m/I8N/wbNBorf7J7TV5yNkDXs40A
d0k7PmZYMKHxiosj1yWelPRQjokvwsGUBBMBCAA+FiEEo2OkmSkcu8lA3WLkHxAC
evAC+LAFAl0VqLoCGwMFCQPCZwAFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQ
HxACevAC+LDNmg//aDq4im2VJLm+3wY0DNYYnkyBcRupgqkFUPQD+nhbKLvCWeLt
rNZmi20ODZYNfhZqhvyfkoaq6NBCPSagVhU/2H/n/aLTM+y4VfYbtOFjWA8JrUyB
wsPgIMxNoDqe1pZNAgFdly6/wS9OUbg4HyEhvTU6LzMbXHZ6ZZDfcgMMwPV3+/sw
ge4gmhTNkAF+jeiwM097Q2zLctAeH5kxXWmhUex4oWW/mP+Z2KTp7yKc1Fg3fy21
zQ4CCyDE8lWszC+caxL6QgwRcmO5FGKGvkYTGkkGWFOa6Sfm8rJHI5XjPzXtq/+E
yUrrvV3fxdDBJYsqM5HZt0uyaB7NTU7a4VGG6aIqjlaujZSXmHs0LZWFn5SpVmwc
Q2/H7lK+lWzczOMMTmpQPiqPeRu0WIGZnrc2d8gVUTVKJOClCfQTFeBPSwwA1qFo
PbZ4dNXg/TcAWEIdtwKPVq440hH10ZyYdW2POEw1tMthy/58mpxc0+W6rixpgT+D
SEPmBdbgk4/XZOYk6sCJnp7L7CBBRXs36DTELZMzrlvTjR3weR9D32/G43Us6Se5
yNdjKrkBsmtHYrSvwtokXpCO4tu3hVsJQ9juzsx9Dsf1WTV82VDT592K4HSh5APp
1KJ2Z5gELlqqOOef9QRIK9EEgN15oSjXEkIRJkq2m7LHMingmvm+ST3qIxDOwU0E
aHptGwEQAKvzjhzR8jBL5Ey1CsD2kStMhyNMEGL+5m15Vzch06jmttzJX2xMDFLy
/Vm3vdM1YnM+gQheRZpzRbYBRtJja27CBu/YJP0/PvuIW940Lvp+MGuWdg9VJ7Hq
LjT1GQSJ4SgrkC+p7wUMtW59SeCditzRX5SIYsMryds/T8HYH8n3YyuOn0z5VjKG
wKww77mUJp6QA9CNtNxeiELJXovg0uYp/kPfAOVck8WtCHXKFm8tZ/469/PtnT3s
jFK3/nya1zBUi2OlQhhpQwRgk+tiSKWbnQEmSIh7v5ZRfYph3pdpnYWf7eHLzF+k
ZLK3kHf0S9L0QR/xraCRvViQIeVyyf3Q5sXggfxtHIF9mXPdXkMPonT8T8Bp0IGS
qFVKwvY8osQ945/WWEE06pmX6X0buE6tsnVZVHNdH76soFh3MKlg+hlxDTivhtk5
uIj8S0BG7Z0YxkVM4dobUGsum5Mbkl52Zq/+RHkFGPUvp0BL3Xw0BgOk1uj5NVOQ
S/VVN4FDkjq8iPb97JumsbxbPD3maCcM7Z8BZE1HJl0mUsqSblLLy+cARWNlWSfr
jMN2OUxhF+6a5AfndJv1PndAlGbpEd04UWaODbZ+D29DocmNKKVOuCNf0bOWZmir
oBQFzHs1CorUjg2CSZWkjoC/P1BGwWoygsYGy1QLXe2/knxCTOgVABEBAAHCw7IE
GAEKACYWIQSjY6SZKRy7yUDdYuQfEAJ68AL4sAUCaHptGwIbAgUJA8JnAAJACRAf
EAJ68AL4sMF0IAQZAQoAHRYhBMKyXZtCctspVluofzx4JPOaiVdYBQJoem0bAAoJ
EDx4JPOaiVdYgWMP/i2TATu3s+8yL74Q2W7H+85QrC3nGGN8FVeDskXwbu/fdmTF
op/6A2nPSP04f3x+OoIY+J/d1KGdk0HGEmf8DAVFJOJhc1jQ9gUteHLGfjwHXqp4
zh8tszs/HZ2zwvgO3fVN6NlhhMX5A4sH0Obzxih/KhkwlRcBbXYYvuT6WpaM1S7B
o9jthsrY2rL0lVaHL4o3dCCRVR5FKdy2mYNlgcsEyWDmGa8Ss2CqCTaIrxNxfZS3
eASxDoV380uiR2i/KV9BLtElz/YAXShmQJ8CYmFYgzCDGlTfZBoQonRnm5d1g93H
ONB7n9Vta6pBLDvDdEJiB/Oy1G8LSowW5juQB5bLf6PZksoYmbhjcIwX+gpnklZr
XxOTYe0S01y8a5lD9wx0L+WiKinwETRnn5XoMMrx9c1nfOqixkPAKy/nwnoOYSPY
wLTY1GXT87taZfc3BRGkmRxcrv3sU4qrzHab8jJ0Oax53vvcHI9qmdcRBDtb8X8h
7uXHZTu+bVRBtiFO6HhHEhY5squGzNP0YphZSdL7dXj+rBZ611MA0dmBwp27dwlA
V26KEF8DWp780akC7lOb1g83Yag4lEofCduWSHMeaLRckD7HwDjOecLXALfIJNSS
hPWPr5WP9kNnBjrnzU48tCxfnx8eJUMsy673S/8DStTyKH1mk2BBIbQ6kYzYuDkP
/j7dtChcatXNpjtV0IDctbq2tPWb67cPpTEBTaiAjoC1zFYstSblQU1h9SDFMyMU
utKlTfuqlmbiPHmSyaZyvaSVZlx1Yx8yA96Lq79ATd+CnYl8CWQDaQQ4E+i4psJp
rSn7XgnF+RBhujZiP/jcRuTwJ1RZm2v4pNtBmAaW5ZXPyR4fKZLFsW22FJDNzLtZ
cBBz8HPD3IGH0spUaf5PalYoNpBgh6euCWP8W0fCKyIPy6bIL5ycHuo3ErWzIHLe
kO9gGeaSN/t1VLgdE16Gaozu8Oypx2u0c9fhR7aqYTOxPfcrekuBEevHAKxOe1bI
Eqcgqdxht3bXFvfeqx6kvmn8Y9EhGjA8W/PWraVoCrKVdHXVe47l4i/1QZU3UxnE
eAj97ArW6H/Os1cjK9K77xzCpAz8FMT7AaPQq3uReUaDqoNIMTO+tCFB2dYQYeX8
YGgILe40bMpCnvY6zxC7UvlO+YxhZSQkF80Ytk/2eHuoLeEiM9IW/0+zxjP6SNmn
fhlkLevudlFFxoYlg5uWH6BIKLSUF1gCRIFKj3T1OnMrDlEAkNYrA3WATxHWEYAZ
NsZ4wS4I0oPY2bZ8ScS+2qwmcrUf4Zoq/praBJY9GYslAh29MmXmvSMuVt0SlYYW
KdMepn86/V0vJYpLKmNHrhToycaaVIN3p69Ap5mIztWLzsFNBF0VqLoBEAC/lPmx
QvfX2S520XOnOD0GnvqnKFUvICc+hfU9vW7o7Dy9ZdGFLRgmkrZbXCNowwPlGI66
VSOUfwueEvmJh5BQRXIv7gkvLhC7yO7OpyqAiLVrux2K69b7Jw/y91FZZZyaOyH8
kXdVNO7qAQ4aOTTln+DbIXa2WW1fljUktbFhSzjK3CRtVL7NUgHrFePGfETZimII
U4ZxjtX52NLQpyoh56WoGpW9+oXe2wEGYYYcHJszKD9iZyNCpSULT7pRNFwZQ3yQ
XNptOotYCw0L8gAmSwJ6SUge+MdLk1BGpXEji7rEvUxj99ymh3sTWqczdKAgYWtw
iis0KDpLrCtDohrc0JJxc2D2cI1FbcF+b4GA1+KGUAR9yd3+EC5yXLYPU0d3BN5a
XjCaXCr/vWLS4/LcXBAIjzGF1Jdr1a5uQBD7JBv/4JxLCd9r9aqfU+pSUgM0+4oB
1Pxqo+0fm7m42ALve9c+t5Yq7q9B/eHSx6sacfq7DD+Eo6NuxIZF9prl8b83uPE/
Yr0INE+Jm/DPLO9FfQYuuLZsyb3RcQ8RaArVdWMteYBke2tbAxlaWK2X+qvDqjsb
RNzjQKZEM+ib8uWcLxQQIF8g/6OAY6JXPNJrYTMyAkRsy8regIyZcCs9KVw6+jAn
HOXAyFURqpyDallSGd2sUFURidTqgrZIVBJ6yQARAQABwsOyBBgBCAAmAhsuFiEE
o2OkmSkcu8lA3WLkHxACevAC+LAFAmR5nv0FCQsmXUMCQAkQHxACevAC+LDBdCAE
GQEIAB0WIQSmAjUw/FNGH+yR+ZwEzT8v3geVeAUCXRWougAKCRAEzT8v3geVeFHE
EACsKQ79VNKKCjh7tcREWAIz1R/2Y6WQxBxA94swo0TxrNRKUgRdHCqQ9+hI0erf
amB4Wr3+6/qBdm93qTj8xZ9P+9EyKIEBpK1v7X0XDl21XpYjtvBIs5AcQYnPUrs/
ZpGb5yXTY1vI5cJg27aPwkeqEBpnFIz2JsgPQVnDLk0ltU/1pGtObIWH4JkRl6xY
FFuGEtxdF+0XBeaOFvL5e8Ds1bLr+wRXCYa0b1o0US8t8uqWwQ/Kg4fSfT86Gjkf
U9NtNe2LUjoKRZk4miWbC5ZvcCmS8U3/qN3+AFG5URRq86fQSSWvEqPQqmdg8E9t
Ny6KYXBCHU75hlw9zPasdc7vw3UUIqCpkohOIzdLArt+sMVklTKlhmNjCkbpguBK
/Ef7K12JyVHnUUhyxm03sKKLALn5qBlkwlXqSLgCKPYSYSFhV9uX4ZezStceV4we
x1mocU0EJZXzbhQiPhaIQFFXyIpubvFpw4lvrNZ085Qit0JduuEr4MUDDBt0HcQO
S5apPpRkNYU7ZFYgINcGbt9iUWLrTsVm6kQVAXqeIKM7uJ5LpS1ADwDOdWAK4leo
FqCReb9rcPA22raDLe8Q1PF8cADttBwX1mX9sAn6NdcBBvNemUSm8+RlL4W2g5EI
/LboJEP5seO32vQRua0MO70/G2SlzqidbVdTi/4x4BSC5EjXD/9vlfu/y2B2lHZf
HGQ5FJYFBsThjyoBxGU1aKE67vHZlei384B74J0dettcoDIKodmk7aE/kHHVdxhZ
ZAM7U3NUp8B4TyFQHpxRXtqVP26tqTnhsvHjQSwUIe/NVSVzn3buSVofXy9ViG0w
TjIIFYnMUqk7aUvZJa1lqdZ2zWuSmNOjQ1UcDNRj/fp5SU8K1qiOYCyHn230VGVT
f2UUNJn11y5/Ev2Hw3hzDwkAK+C7XhRIKE83U+tcpEs2xlPTN1glTPmKlcjj/8vr
rgiM6nc2PKF0iHbJdargKEAJZBfECs6yUJ6qqdPGLtYPecw8XVgt9ZgFvY1JveZH
TwxYPtuk+3WmL3Wu9Uqew2mmVFY6N0dYUE3A/RQWNTorRddAGhYVTeSOU+nSKUG3
vh939JLc6whDHMwR2WsvKjEoL8SiC02Jf+fS/QVDk4Gyb0aYxpe0BKijGWd/AvGZ
TaCG1w18TW69zeZKudUv1U4k2SB2Da+tx23g73GSW+gRZOLnKPtHb0T9+i2U8YKg
tc/FlkvjF1JRltNeTbk+cB0YT+UEHegvlX7umMKqUPKD54VrmafT28B1sTbIh1ir
9n2viPgGK+INdVp+7N6Gym0j4TdCnPg2X5/KX5MVBEGQpkRJCyJoSRh5QVbjwXf7
5gz29ym+3kgbwS6FwUp1P1BBxrBTTsLDsgQYAQgAJgIbLhYhBKNjpJkpHLvJQN1i
5B8QAnrwAviwBQJgthvRBQkHYtoXAkAJEB8QAnrwAviwwXQgBBkBCAAdFiEEpgI1
MPxTRh/skfmcBM0/L94HlXgFAl0VqLoACgkQBM0/L94HlXhRxBAArCkO/VTSigo4
e7XERFgCM9Uf9mOlkMQcQPeLMKNE8azUSlIEXRwqkPfoSNHq32pgeFq9/uv6gXZv
d6k4/MWfT/vRMiiBAaStb+19Fw5dtV6WI7bwSLOQHEGJz1K7P2aRm+cl02NbyOXC
YNu2j8JHqhAaZxSM9ibID0FZwy5NJbVP9aRrTmyFh+CZEZesWBRbhhLcXRftFwXm
jhby+XvA7NWy6/sEVwmGtG9aNFEvLfLqlsEPyoOH0n0/Oho5H1PTbTXti1I6CkWZ
OJolmwuWb3ApkvFN/6jd/gBRuVEUavOn0EklrxKj0KpnYPBPbTcuimFwQh1O+YZc
Pcz2rHXO78N1FCKgqZKITiM3SwK7frDFZJUypYZjYwpG6YLgSvxH+ytdiclR51FI
csZtN7CiiwC5+agZZMJV6ki4Aij2EmEhYVfbl+GXs0rXHleMHsdZqHFNBCWV824U
Ij4WiEBRV8iKbm7xacOJb6zWdPOUIrdCXbrhK+DFAwwbdB3EDkuWqT6UZDWFO2RW
ICDXBm7fYlFi607FZupEFQF6niCjO7ieS6UtQA8AznVgCuJXqBagkXm/a3DwNtq2
gy3vENTxfHAA7bQcF9Zl/bAJ+jXXAQbzXplEpvPkZS+FtoORCPy26CRD+bHjt9r0
EbmtDDu9Pxtkpc6onW1XU4v+MeAUguSKSg/8Ciu/o/I9G+6JV+ZZyvNtmCR95gLL
a05lvNQ2BrV7dh9+azF2mTDBsO8jPFxI6yqbZxccMTkfy9OIrtsurOoxsLPg442o
lyUfjYWNRyEKzo5YN6hrk+q6KFEFJUkmJPu3ApGYIbVFDDPs+iQVQKPw5WxpBssZ
EnaPNT4sEfcz8xUXDp2R1zNY1tirieOEGJXEroA/ssGF6cbCr4gYH7HrUO7ZLSpE
0ivr5njHZyjl//xCxbiJD+E2qBrBhwW3mJxFq3L3jo8R1Ijut7TY4w33QhlsfoGH
7mpxFaoHznsT+GuH2CRxdimOTGpv8dCl+0qhvZhpqvAoZqaQGuTfBjeP//J/RdbP
bNND+ROnv7zZReamM9JGrQXtuT51cEI7rwViv8Y43heazqRN/bM6LZQUIM3kWB57
IMUZCiDJOKd1BD71fsU4dTM0BiyczpYpr1O9cUjGgn6h5Khkwdi+4s1ij0oQo+Hc
XDSkeCIOg31DV0rmHUTRUeUHdPoXFEwWS1lAPJw4nwsZ5e/BuCF20Sw2lfTUyFxf
o+C1H7Ams0/QnUe9RbGeICEA3ElZeZ6hetFVggdMm1vXsWyo4+hP5YzmbW0eapRA
S/5FNbjs3Ie9hliikjitL6ip7F7/0x8PcRu2mRnjYrdTpsNnK8h3vzgsySaSI7/O
IG8Tn3MVI7yg2LjOwU0EaHpt/AEQAMAQRKtjJbseOA4djkpN3I26rT0Z7z3bpvCZ
KDTB1J09zuzBf9FLP/mZTt63Y10+cH8eDqK2Jx/Jn4TxQMAlMU+5YMkDOuzdj7sB
yBIkiinYOFG7tcQHu5jSWYxNo26rjJ+82omVMjwP0NmYHyYVpPGaN08UjV6Hwsq4
VxZf8pKHVcQtk4tAuBsO8drJ4R2kGX3AFxmZ5DMH7Q2oxBy0O4kG2DQsSl7kF7my
SwNwPw1Eppx2UCHtPa1r6DIL3vaUJQhrEW/z2HMS4I/HsqfrKc//hdEuWWIx3PcL
oFGqQHNfPiwLOiZqQTu3VLCwazrNfQNZpZugWwo+YK3kuN2UMp4CTybFW4o7lnyb
hXN88+Qj1tpdf30ItHDIs2P8i9eODT6Ssxn98nmhIyZSrxlgvaTDV/fJqDsVG46B
SdHS8h73yxlROGEEvE6g/ip7hSbFHiql8TrnQnRH2UzH+PJbmdTU16cKxR0VZ56w
V0OXhH/iSJdNV/jKAt/HiPz+Jn6I1C35eUIJtlcMIHGue4JAxmbrGJ++GZrgG7DP
UNz85VZo+TNzmDpG5gHV8TG6birttsqWfHyyu4ccYqdv5dOBBsrKB00r45alHMXJ
dZ7mf1M6OQDqY/pS5MYzZSj+iDAs43gsvWuQTeU1lYDbIN69t/LmgdShTrj52dTQ
nFTBAn81ABEBAAHCwXwEGAEKACYWIQSjY6SZKRy7yUDdYuQfEAJ68AL4sAUCaHpt
/AIbDAUJA8JnAAAKCRAfEAJ68AL4sLtxD/9EGdh2RiWB3WDeCy+6VE2fE1a1j2qG
b1I9MzaagGIjNfNLQa0ZRd4C8F2PxMq44g9pJT14Ti/TydW8UnavcO2eg5AP+mrO
P4bF8I+mtx1YtnyDPOBPtaxFXc1h1qF70KDyzQJl9C3ni/NrbvI8TTyh7JjFEqfy
g5PU+m2TBwoK+cQoAVb6NEA9bAzKsayqVg596E4A3VEn8LkiXshe96MGXwENCZbU
JhU1+C5M+q2XUi4BwfnbccgW3f67HyPEYt1dyYuQD18RM2I61yvUfCS9UMjZuBv3
QKERDap46x6fg7nfq7NZqBB4Ktb0pp//NJJdP8eP7zs+tbuLEDvLF3+RhiBUrR2d
Wx7qZLM1JRqHd85ttvB1xK7f/38TE7J2STpIpHlBgWroqWUYbTw3hiIfN9pNSike
M8hKjZ+w58HrXrx8gxN0tq60c9tAsxy7wpZmvufn06T9AaqPGnArfh3mAzk4G9jG
15JcGO5YKrE1M9y0pqyBgdku+zp87D8TEuWBa3GPHMVqkwz5Tm/ovpa6ms2KiuNK
9qVYb8JaUg5AxOnkxJSjnomRCVfTf6yccexdmE4EEkUNhFj/6Y+UA4WCxhAS4Gra
LDARUWnKPkw2YY4m7cWPDHzXF+pN3KHLej+u1O+0y1q9OmpQ0yogo1fnzmeIHvJY
iYmSNsSq9FUzTw==
=CCuY
-----END PGP PUBLIC KEY BLOCK-----
# <<< END GENERATED NODE RELEASE KEYRING <<<
NODE_RELEASE_KEYRING_EOF
}

main() {
  require_root
  ensure_prereqs
  # PRIMARY succeeds ONLY if the install ran clean AND produced the requested
  # major; a wrong major is treated as a reason to use the fallback.
  if install_via_nodesource && node_major_ok; then
    node_report
    log "done (NodeSource apt)"
    return 0
  fi
  log "PRIMARY unavailable or wrong major — NodeSource path did not yield Node ${NODE_MAJOR}.x."
  if [ "${NODE_DISABLE_FALLBACK:-0}" = "1" ]; then
    die "NodeSource install failed/mismatched and NODE_DISABLE_FALLBACK=1 (no fallback attempted)"
  fi
  install_via_tarball
  node_major_ok || die "fallback installed a Node that is not major ${NODE_MAJOR}.x"
  node_report
  log "done (nodejs.org tarball fallback)"
}

main "$@"
