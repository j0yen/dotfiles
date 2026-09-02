#!/bin/bash
# agentns-activation-check.sh — SessionStart hook for agentns-doctor activation.
#
# Runs `agentns-doctor activation --json`, checks for BLOCKED, and prints a
# one-line remedy banner if so. Silent on LIVE. Always exits 0.
#
# Wire in ~/.claude/settings.json under hooks.SessionStart.

set -euo pipefail

DOCTOR=$(command -v agentns-doctor 2>/dev/null || true)
if [[ -z "$DOCTOR" ]]; then
    # Binary not on PATH — skip silently
    exit 0
fi

# Run the activation check; capture JSON output
JSON=$("$DOCTOR" activation --json 2>/dev/null) || true

if [[ -z "$JSON" ]]; then
    # Doctor failed to produce output — skip silently
    exit 0
fi

# Parse blocked_layer and remedy from JSON using python3 or jq
BLOCKED_LAYER=$(printf '%s' "$JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('blocked_layer') or '')" 2>/dev/null || true)

if [[ -z "$BLOCKED_LAYER" ]]; then
    # LIVE — stay silent
    exit 0
fi

REMEDY=$(printf '%s' "$JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('remedy') or '')" 2>/dev/null || true)

# Print one-line banner
printf '\033[33m[agentns] ACTIVATION BLOCKED at %s — %s\033[0m\n' \
    "$BLOCKED_LAYER" "$REMEDY"

exit 0
