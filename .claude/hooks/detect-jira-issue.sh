#!/bin/bash
# UserPromptSubmit hook: Detects Jira issue keys in user prompts
# and instructs Claude to use the appropriate skill.
#
# This hook reads the user's prompt from stdin (JSON format)
# and checks for DASH-XXXX patterns.

# Read stdin (hook input JSON)
INPUT=$(cat)

# Extract the user's prompt text from the JSON input
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # The prompt content may be in different fields depending on hook format
    content = data.get('content', data.get('message', data.get('prompt', '')))
    if isinstance(content, list):
        # Handle array of content blocks
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                print(block.get('text', ''))
    else:
        print(content)
except:
    pass
" 2>/dev/null)

# Check if the prompt contains a Jira issue key (DASH-XXXX pattern)
if echo "$PROMPT" | grep -qiE 'DASH-[0-9]+'; then
    ISSUE_KEY=$(echo "$PROMPT" | grep -oiE 'DASH-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
    echo "JIRA ISSUE DETECTED: $ISSUE_KEY"
    echo ""
    echo "MANDATORY: You MUST use the Skill tool to invoke the /develop skill:"
    echo "  - For ALL issue types (Story, Task, Feature, Bug): invoke skill 'develop' with args '$ISSUE_KEY'"
    echo "  - The /develop skill auto-detects Bug issues and applies test-first TDD flow."
    echo ""
    echo "Do NOT work on the issue without using the skill workflow."
fi

# Always exit 0 - this is informational, not blocking
exit 0
