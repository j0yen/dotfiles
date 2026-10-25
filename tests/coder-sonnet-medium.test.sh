#!/usr/bin/env bash
# Coders run Sonnet at medium effort (Joe 10-24 "change coder agents to use Sonnet Medium").
# Guards both coder launchers: the Agent-tool `coder` definition and the rb seat's headless rb-run-coder.sh.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
A="$here/.claude/agents/coder.md"
fm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$A")
if printf '%s\n' "$fm" | grep -qx 'model: sonnet' && printf '%s\n' "$fm" | grep -qx 'effort: medium'; then echo "ok - coder.md frontmatter = model: sonnet + effort: medium"
else echo "NOT OK - coder.md frontmatter lacks model: sonnet / effort: medium"; fail=1; fi
R="$here/.local/bin/rb-run-coder.sh"
if grep -v '^[[:space:]]*#' "$R" | grep -E 'claude -p ' | grep -q -- '--model sonnet --effort medium'; then echo "ok - rb-run-coder.sh claude -p passes --model sonnet --effort medium"
else echo "NOT OK - rb-run-coder.sh claude -p lacks --model sonnet --effort medium"; fail=1; fi
exit $fail
