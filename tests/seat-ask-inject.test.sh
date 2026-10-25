#!/usr/bin/env bash
# seat-ask-inject (five-whys 10-24: rb waited on a ctl CONFIRM that sat queued behind rb's own turn). Runs the hook selftest under a throwaway HOME,
# asserts the hook is registered once under PostToolUse and once under Stop (matcher ""), and that seat-tick's ask lock wait default is 20 s, not 1800 s.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
S="$here/.claude/settings.json"; H="$here/.claude/hooks/seat-ask-inject.sh"

bash -n "$H" && ok "bash -n seat-ask-inject.sh" || bad "bash -n seat-ask-inject.sh"
[ -x "$H" ] && ok "seat-ask-inject.sh executable" || bad "seat-ask-inject.sh not executable"
out="$(env -u WM_SEAT HOME="$tmp" bash "$H" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -qE '^selftest: [0-9]+ PASS 0 FAIL$' && [ "$(printf '%s\n' "$out" | grep -c '^PASS')" -ge 18 ] \
  && ok "seat-ask-inject.sh --selftest ($(printf '%s\n' "$out" | grep -c '^PASS') checks)" || { bad "seat-ask-inject.sh --selftest"; printf '%s\n' "$out" | grep '^FAIL'; }

jq -e . "$S" >/dev/null && ok "settings.json parses" || { bad "settings.json parses"; exit 1; }
for ev in PostToolUse Stop; do
  n="$(jq -r --arg ev "$ev" '[.hooks[$ev][] | select(.matcher=="") | .hooks[] | select(.type=="command" and .command=="/home/jsy/.claude/hooks/seat-ask-inject.sh")] | length' "$S")"
  [ "$n" = 1 ] && ok "seat-ask-inject.sh registered once under $ev (matcher \"\")" || bad "seat-ask-inject.sh under $ev: $n (want 1)"
done
n="$(jq -r '[.hooks[][].hooks[].command | select(test("seat-ask-inject[.]sh"))] | length' "$S")"
[ "$n" = 2 ] && ok "seat-ask-inject.sh appears exactly twice overall" || bad "seat-ask-inject.sh appears $n times overall (want 2)"
grep -q 'ASK_LOCK_WAIT="${SEAT_ASK_LOCK_WAIT:-20}"' "$here/.local/bin/seat-tick.sh" && ok "seat-tick ask lock wait default 20 s" || bad "seat-tick ask lock wait default is not 20 s"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
