#!/usr/bin/env bash
# settings.json registers agent-spawn-spec-lint.sh exactly once, as its own
# PreToolUse group with matcher "Agent" and timeout 10 (like output-cap.sh
# for Bash), and the hook file exists and is executable.
# shellcheck disable=SC2319  # check NAME $? deliberately reads the preceding test
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
S="$here/.claude/settings.json"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
jq -e . "$S" >/dev/null; check "settings-parses" $?
jq -e '[.hooks[][].hooks[].command | select(test("agent-spawn-spec-lint[.]sh"))] | length == 1' "$S" >/dev/null; check "registered-once-overall" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[] | select(.command == "/home/jsy/.claude/hooks/agent-spawn-spec-lint.sh" and .type == "command" and .timeout == 10)] | length == 1' "$S" >/dev/null; check "pretooluse-agent-group-timeout-10" $?
jq -e '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | map(.hooks | length) == [1]' "$S" >/dev/null; check "own-group-single-hook" $?
[ -x "$here/.claude/hooks/agent-spawn-spec-lint.sh" ]; check "hook-executable" $?
echo "agent-spawn-spec-lint-registered.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
