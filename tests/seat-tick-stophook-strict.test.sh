#!/usr/bin/env bash
# tests/seat-tick-stophook-strict.test.sh -- seat-tick's stop_hook_lines counts only REAL Stop-hook bounces.
#
# Bug (10-24 6:50 PM): the loose `grep -c 'Stop hook'` counted any JSONL line mentioning Stop hooks (assistant text, tool results), so the controller session
# (no goal set) raised `ALARM ctl stop-hook bounces=4`. Measured strict/loose on live sessions: rb 106/255, r7 43/189, ctl 0/40.
# A real bounce is a user message whose text/content STARTS with `Stop hook feedback:`.
# Run: bash tests/seat-tick-stophook-strict.test.sh      (no claude, no systemctl, no real state; a mktemp dir only)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$root/.local/bin/seat-tick.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

bash -n "$SELF"; chk "bash -n seat-tick.sh" $?
grep -qF "grep -cE '\"(text|content)\":\"Stop hook feedback:'" "$SELF"; chk "stop_hook_lines uses the strict pattern" $?
! grep -qF "grep -c 'Stop hook'" <(grep '^stop_hook_lines()' "$SELF"); chk "stop_hook_lines no longer uses the loose pattern" $?
! grep -q 'a /goal judge is live' "$SELF"; chk "the ALARM text does not assert a /goal is live" $?

T="$(mktemp -d "${TMPDIR:-/tmp}/stophook-strict.XXXXXX")"; trap 'rm -rf "$T"' EXIT
JSONL_DIR="$T"
eval "$(grep '^stop_hook_lines()' "$SELF")"   # the function under test, verbatim from the script
{
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\\ngoal not met 1"}]}}\n'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"the Stop hook alarm fired again"}]}}'
  echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"grep -c Stop hook -> 40"}]}}'
  printf '{"type":"user","message":{"role":"user","content":"Stop hook feedback: goal not met 2"}}\n'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"a Stop hook blocked the turn"}]}}'
} >"$T/sid1.jsonl"
n="$(stop_hook_lines sid1)"; [ "$n" = 2 ]; chk "2 real feedback lines + 3 mention lines -> 2 (got '$n')" $?
n="$(stop_hook_lines nosuch)"; [ "$n" = 0 ]; chk "missing file -> 0 (got '$n')" $?

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
