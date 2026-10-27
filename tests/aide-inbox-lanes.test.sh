#!/usr/bin/env bash
# Falsifier for the weakest link (aide lanes, leaf 3) + the positive lane case (Fable regrade 10-27):
#  negative: aide-inbox.sh under WM_SEAT=aide WM_AIDE_LANE=build must leave the MAIN cursor untouched and print no main line;
#  positive: the same run must print the one line in aide-build-events.log and advance aide-build-events.cursor to its EOF;
#  controls: WM_AIDE_LANE=main and unset must still print every main line and advance the main cursor to EOF.
# Temp EVENTS_DIR only; exit 1 on any failure.  Usage: falsifier.sh [hook-path]
set -u
HOOK="${1:-$(dirname "$0")/../.claude/hooks/aide-inbox.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
D="$T/ev"; mkdir -p "$D"
L="$D/aide-events.log"; C="$D/aide-events.cursor"; BL="$D/aide-build-events.log"; BC="$D/aide-build-events.cursor"
printf '2026-10-27T02:00:00-07:00 | rb | main line one\n2026-10-27T02:01:00-07:00 | r7 | main line two\n' >"$L"
printf '2026-10-27T02:02:00-07:00 | plain-carbon | build line addressed\n' >"$BL"
printf '0\n' >"$C"
before="$(sha256sum "$C" | cut -c1-16)"
run() { env -u TMUX -u AIDE_INBOX_HOSTNAME -u PROBE_GATE_HOSTNAME EVENTS_DIR="$D" HOME="$T" WM_SEAT=aide WM_AIDE_LANE="$1" \
        bash "$HOOK" SessionStart </dev/null 2>&1; }
fail=0
out="$(run build)"; rc=$?
after="$(sha256sum "$C" | cut -c1-16)"
echo "hook=$(readlink -f "$HOOK")"
echo "rc=$rc cursor_before=$before cursor_after=$after cursor_value=$(cat "$C")"
echo "printed_main_lines=$(printf '%s\n' "$out" | grep -c 'main line')"
if [ "$before" = "$after" ] && ! printf '%s\n' "$out" | grep -q 'main line'; then
  echo "NEGATIVE: PASS — build lane left the main cursor untouched and printed no main line"
else
  echo "NEGATIVE: FAIL — build lane consumed the MAIN cursor (no lane branch): the weak link is real"; fail=1
fi
bl_printed="$(printf '%s\n' "$out" | grep -c 'build line addressed')"; bc_val="$(cat "$BC" 2>/dev/null || echo absent)"
hdr_ok=0; printf '%s\n' "$out" | grep -qF '=== AIDE INBOX (lane build): 1 new line(s)' && hdr_ok=1
if [ "$bl_printed" = 1 ] && [ "$hdr_ok" = 1 ] && [ "$bc_val" = "$(stat -c %s "$BL")" ]; then
  echo "POSITIVE: PASS — lane line printed once, aide-build-events.cursor=$bc_val (EOF)"
else
  echo "POSITIVE: FAIL — lane line printed $bl_printed time(s), lane header ok=$hdr_ok, aide-build-events.cursor=$bc_val (want $(stat -c %s "$BL"))"; fail=1
fi
printf '0\n' >"$C"
out2="$(run main)"; m="$(printf '%s\n' "$out2" | grep -c 'main line')"
echo "control_lane_main_printed=$m cursor=$(cat "$C")"; { [ "$m" = 2 ] && [ "$(cat "$C")" = "$(stat -c %s "$L")" ]; } || fail=1
printf '0\n' >"$C"
out3="$(env -u TMUX -u AIDE_INBOX_HOSTNAME -u PROBE_GATE_HOSTNAME -u WM_AIDE_LANE EVENTS_DIR="$D" HOME="$T" WM_SEAT=aide bash "$HOOK" SessionStart </dev/null 2>&1)"; u="$(printf '%s\n' "$out3" | grep -c 'main line')"
echo "control_lane_unset_printed=$u cursor=$(cat "$C")"; { [ "$u" = 2 ] && [ "$(cat "$C")" = "$(stat -c %s "$L")" ]; } || fail=1
[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $fail
