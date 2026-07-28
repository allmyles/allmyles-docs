#!/usr/bin/env bash
# install-node.sh — hardened, provider-resilient Node.js installer for consumer
# Docker image builds. Shipped by claude-kit (INF-246).
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
#      nodejs.org binary tarball (arch-aware, integrity-verified against the
#      signed SHASUMS256.txt served alongside it, or a pinned
#      NODE_FALLBACK_SHA256), independent of NodeSource entirely.
#
# USAGE (Debian/Ubuntu-based Dockerfile; run as root at build time):
#   COPY .claude/scripts/install-node.sh /tmp/install-node.sh
#   RUN /tmp/install-node.sh            # defaults to Node major 22
#   RUN /tmp/install-node.sh 20         # or pin another major positionally
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
#                              SHASUMS256.txt (strict supply-chain pin).
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
  # fallback tarball. Installing them up front keeps the fallback usable even
  # if the NodeSource tier partially ran.
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
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg || return 1
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
  # SHASUMS256.txt published next to the tarball (served over TLS by nodejs.org).
  local expected
  if [ -n "$NODE_FALLBACK_SHA256" ]; then
    expected="$NODE_FALLBACK_SHA256"
  else
    # Unpinned: integrity rests on the TLS-served SHASUMS256.txt, which is NOT
    # yet GPG-signature-verified (INF-248). For zero-trust supply-chain builds,
    # set NODE_FALLBACK_SHA256 to pin the exact hash.
    log "WARNING: fallback checksum from TLS-served SHASUMS256.txt (not GPG-verified — INF-248). Set NODE_FALLBACK_SHA256 to pin."
    expected="$(curl -fsSL "https://nodejs.org/dist/v${ver}/SHASUMS256.txt" \
      | awk -v f="$tarball" '$2==f {print $1}')" \
      || die "fallback: could not fetch SHASUMS256.txt"
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
