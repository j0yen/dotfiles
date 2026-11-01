#!/usr/bin/env bash
# tests/row-gate-guard.test.sh — .claude/hooks/row-gate-guard.sh denies a row gate whose exit status is not the row tool's
# own (a pipe after rb-row.sh / r7-row.sh / ctl-row.sh / wm-decide record, a `;` or newline after the row assignment,
# a `[ -n "$R" ]` gate) and is registered as a PreToolUse Bash hook. Runs the hook's own --selftest and a few direct
# invocations (stdout and stderr captured separately) under a throwaway HOME; no real command is executed.
# Run: bash tests/row-gate-guard.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/row-gate-guard.sh"
tmp=$(mktemp -d); trap 'rm -rf -- "${tmp:?}"' EXIT
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

out=$(HOME="$tmp" XDG_CONFIG_HOME="$tmp" bash "$hook" --selftest 2>&1); rc=$?
printf '%s\n' "$out" | grep -v '^PASS'
[ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; chk "selftest rc 0, no FAIL (rc=$rc)" $?
n=$(printf '%s\n' "$out" | grep -c '^PASS'); [ "$n" -ge 40 ]; chk "selftest ran >= 40 passing cases (n=$n)" $?

command -v jq >/dev/null; chk "jq present" $?
[ -x "$hook" ]; chk "hook is executable" $?

# direct invocations: rc, stdout and stderr asserted separately
run_() { HOME="$tmp" XDG_CONFIG_HOME="$tmp" bash "$hook" <<<"$1" >"$tmp/o" 2>"$tmp/e"; rc=$?; }
cmdjson() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
want="row-gate-guard: gate on the row tool's own exit: R=\$(rb-row.sh ...) && <action> (no pipe, no ;, no [ -n ])"

run_ "$(cmdjson 'R=$(rb-row.sh --kind x 2>&1 | tail -1) && echo go')"
[ "$rc" -eq 2 ] && [ ! -s "$tmp/o" ] && [ "$(sed -n 1p "$tmp/e")" = "$want" ]; chk "piped row denied: rc 2, stdout empty, refusal on stderr (rc=$rc)" $?
run_ "$(cmdjson 'R=$(rb-row.sh --kind x); go')"
[ "$rc" -eq 2 ] && [ ! -s "$tmp/o" ] && grep -q '^row-gate-guard: rule B: ' "$tmp/e"; chk "row; action denied: rc 2, rule B on stderr (rc=$rc)" $?
run_ "$(cmdjson 'R=$(rb-row.sh --kind x --what "a | b") && go')"
[ "$rc" -eq 0 ] && [ ! -s "$tmp/o" ] && [ ! -s "$tmp/e" ]; chk "quoted | allowed: rc 0, no output (rc=$rc)" $?
run_ "$(cmdjson 'R=$(rb-row.sh --kind x | tail -1')"
[ "$rc" -eq 0 ] && [ ! -s "$tmp/o" ]; chk "parse-error branch allows: rc 0 (rc=$rc)" $?
run_ '{"tool_name":"Bash","tool_input":{"command":5}}'
[ "$rc" -eq 0 ] && [ ! -s "$tmp/o" ]; chk "non-string command allows: rc 0 (rc=$rc)" $?

jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]?.command | select(endswith("/.claude/hooks/row-gate-guard.sh"))] | length == 1' \
    "$here/.claude/settings.json" >/dev/null; chk "settings.json registers row-gate-guard.sh once under PreToolUse matcher Bash" $?
exit $fail
