#!/usr/bin/env bash
# aide inbox (10-23): seat-event.sh inbox-only seats + the aide-inbox.sh hook. Runs both selftests under a throwaway HOME and asserts
# the hook is registered once under UserPromptSubmit and once under SessionStart, and that the seats.tsv row helper prints the documented row.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
S="$here/.claude/settings.json"

for f in .local/bin/seat-event.sh .claude/hooks/aide-inbox.sh; do
  bash -n "$here/$f" && ok "bash -n $f" || bad "bash -n $f"
  [ -x "$here/$f" ] && ok "$f executable" || bad "$f not executable"
done

out="$(env -u WM_SEAT -u TMUX HOME="$tmp" bash "$here/.local/bin/seat-event.sh" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -qx 'SELFTEST PASS' && ! printf '%s\n' "$out" | grep -q '^FAIL' \
  && ok "seat-event.sh --selftest ($(printf '%s\n' "$out" | grep -c '^PASS') checks)" || { bad "seat-event.sh --selftest"; printf '%s\n' "$out" | grep '^FAIL'; }
out="$(env -u WM_SEAT -u TMUX HOME="$tmp" bash "$here/.claude/hooks/aide-inbox.sh" --selftest 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | tail -n1 | grep -qx 'SELFTEST PASS' && ! printf '%s\n' "$out" | grep -q '^FAIL' \
  && ok "aide-inbox.sh --selftest ($(printf '%s\n' "$out" | grep -c '^PASS') checks)" || { bad "aide-inbox.sh --selftest"; printf '%s\n' "$out" | grep '^FAIL'; }

jq -e . "$S" >/dev/null && ok "settings.json parses" || { bad "settings.json parses"; exit 1; }
for ev in UserPromptSubmit SessionStart; do
  n="$(jq -r --arg ev "$ev" '[.hooks[$ev][].hooks[] | select(.type=="command" and (.command | test("/\\.claude/hooks/aide-inbox\\.sh " + $ev + "$")))] | length' "$S")"
  [ "$n" = 1 ] && ok "aide-inbox.sh registered once under $ev" || bad "aide-inbox.sh under $ev: $n (want 1)"
done
n="$(jq -r '[.hooks[][].hooks[].command | select(test("aide-inbox[.]sh"))] | length' "$S")"
[ "$n" = 2 ] && ok "aide-inbox.sh appears exactly twice overall" || bad "aide-inbox.sh appears $n times overall (want 2)"
t="$(jq -r '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("aide-inbox[.]sh"))][0].timeout' "$S")"
[ "$t" = 5 ] && ok "UserPromptSubmit entry has a 5 s timeout" || bad "timeout $t"

[ "$(bash "$here/.local/bin/seat-event.sh" --inbox-row aide)" = "$(printf 'aide\tinbox\t-\t0\t0\t-\t-')" ] && ok "--inbox-row aide prints the documented row" || bad "--inbox-row aide"
grep -q "aide<TAB>inbox<TAB>-<TAB>0<TAB>0<TAB>-<TAB>-" "$here/.local/bin/seat-event.sh" && ok "row documented in the seat-event.sh header" || bad "row not documented in header"
grep -q 'PROBE_GATE_HOSTNAME' "$here/.claude/hooks/aide-inbox.sh" && grep -q 'WM_SEAT' "$here/.claude/hooks/aide-inbox.sh" && grep -q 'TMUX' "$here/.claude/hooks/aide-inbox.sh" && ok "hook uses the probe-gate § 1b aide predicate" || bad "aide predicate missing"
exit $fail
