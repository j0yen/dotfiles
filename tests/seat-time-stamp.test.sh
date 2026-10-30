#!/usr/bin/env bash
# seat-time-stamp (controller correction row d335): seat-event.sh and seat-ask.sh stamp their own "<source> <H:MM AM/PM>" and replace any typed
# leading clock label. Runs both selftests under a throwaway HOME, then drives both scripts with a fixed fake clock (SEAT_STAMP_NOW, honoured only
# under SEAT_TICK_SELFTEST=1) and asserts the typed time never reaches the stored events.log line or the --ask argv the seat reads.
set -u
# capability probe (first executable block): no systemd user bus -> SKIP (exit 77, counted as skip= by tests/run.sh), never a pass
for _p in "systemctl --user show-environment" "systemd-run --user --quiet true"; do
  $_p >/dev/null 2>&1 || { _rc=$?; echo "SKIP $(basename "$0"): no systemd user bus (probe '$_p' rc=$_rc)"; exit 77; }
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV="$here/.local/bin/seat-event.sh"; ASK="$here/.local/bin/seat-ask.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "NOT OK - $1"; fail=1; fi; }
export HOME="$T/home"; mkdir -p "$HOME"

for s in "$EV" "$ASK"; do
  out="$("$s" --selftest 2>&1)"; rc=$?
  ok "$(basename "$s") --selftest passes ($(printf '%s\n' "$out" | grep -c '^PASS') PASS)" "$rc"
  printf '%s\n' "$out" | grep -q '^FAIL' && { printf '%s\n' "$out" | grep '^FAIL'; fail=1; }
done

# fixed-clock end to end
export EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=aide SEAT_TICK_SELFTEST=1 SEAT_STAMP_NOW="6:41 AM" SEAT_EVENT_NOWAKE=1 SEAT_ASK_DRY=1 SEAT_ASK_TICK_BIN="$T/fake-tick"
printf 'tst\trb\tsid-x\t20\t100\t^x\t-\n' >"$SEATS_TABLE"
"$EV" tst "rb 6:1x AM re ctl 6:0x: reply body one" >/dev/null 2>&1
"$EV" tst "r7 2:19 AM: reply body two" >/dev/null 2>&1
"$EV" tst "reply body three" >/dev/null 2>&1
L="$EVENTS_DIR/tst-events.log"
[ "$(wc -l <"$L")" = 3 ]; ok "three lines stored" $?
! grep -Eq '6:1x|2:19' "$L"; ok "the typed clocks (6:1x, 2:19) never appear in the stored events.log" $?
grep -q ' | aide | aide 6:41 AM re ctl 6:0x: reply body one$' "$L" && grep -q ' | aide | aide 6:41 AM: reply body two$' "$L" && grep -q ' | aide | aide 6:41 AM: reply body three$' "$L"; ok "each stored line carries the real stamp (aide 6:41 AM)" $?
[ "$(jq -r '[.stamped,.typed_label_replaced]|@csv' "$EVENTS_DIR/tst-events.json")" = "3,2" ]; ok "events.json counters stamped=3 typed_label_replaced=2" $?
a="$("$ASK" tst "rb 6:1x AM: ask body" 2>&1)"
[[ "$a" == *" tst --ask aide 6:41 AM: ask body" ]] && ! [[ "$a" == *6:1x* ]]; ok "seat-ask argv carries the real stamp and not the typed clock" $?
# aide lanes (step 3b ii): seat_stamp_source
src() { env -i PATH="$PATH" "$@" bash -c ". '$here/.local/lib/seat-time-stamp.sh'; seat_stamp_source"; }
[ "$(src WM_SEAT=aide WM_AIDE_LANE=build)" = "aide:build" ]; ok "WM_SEAT=aide WM_AIDE_LANE=build -> source aide:build" $?
[ "$(src WM_SEAT=aide WM_AIDE_LANE=main)" = "aide" ]; ok "WM_AIDE_LANE=main -> source aide" $?
[ "$(src WM_SEAT=aide)" = "aide" ]; ok "WM_AIDE_LANE unset -> source aide" $?
[ "$(src WM_SEAT=aide WM_AIDE_LANE=build EVENT_SOURCE=x)" = "x" ]; ok "EVENT_SOURCE=x wins over the lane" $?
[ "$(src WM_SEAT=rb WM_AIDE_LANE=build)" = "rb" ]; ok "non-aide seat ignores WM_AIDE_LANE" $?
[ "$fail" = 0 ] && echo "ALL OK" || echo "FAILED"
exit "$fail"
