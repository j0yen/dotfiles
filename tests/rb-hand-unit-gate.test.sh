#!/usr/bin/env bash
# rb-hand-unit-gate.test.sh - rb-hand-unit-gate.sh --selftest + its registration as a PreToolUse Bash hook in .claude/settings.json
# (A1304: rb's units start through rb-suite-unit.sh, a hand `systemd-run --unit rb-*` from the rb seat is denied).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$here/../.claude/hooks/rb-hand-unit-gate.sh" --selftest || exit 1
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | any(. == "/home/jsy/.claude/hooks/rb-hand-unit-gate.sh")' \
  "$here/../.claude/settings.json" >/dev/null && echo "PASS: registered as a PreToolUse Bash hook" || { echo "FAIL: not registered in .claude/settings.json"; exit 1; }
