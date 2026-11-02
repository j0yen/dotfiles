#!/usr/bin/env bash
# A236 L2 event table: event-act.sh classes, owner mapping, action row, seat-event.sh hook-in. Every host call is faked; nothing live is touched.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; EA="$R/.local/bin/event-act.sh"; SE="$R/.local/bin/seat-event.sh"; TBL="$R/.config/fleet/gen/event-actions.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
export HOME="$T/home" EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=tester EVENT_ACT_TABLE="$TBL"; mkdir -p "$HOME"
jq -e . "$TBL" >/dev/null && ok "table is valid JSON" || bad "table json"
printf '# t\n' >"$SEATS_TABLE"; for s in aide rb; do "$SE" --inbox-row $s >>"$SEATS_TABLE"; done
# fake seat-event records each delivery
printf '#!/bin/bash\necho "$1|$EVENT_SOURCE|${SEAT_EVENT_ACT:-}|$2" >>"%s/delivered"\n' "$T" >"$T/fake-se"; chmod +x "$T/fake-se"
export SEAT_EVENT_BIN="$T/fake-se"
L='swarm-decide FOLLOWUP-ESCALATE row d-1 owner=r7 overdue 3h'
out="$("$EA" --classify aide "$L")"; [ "$out" = "CLASS followup-owner-route OWNER r7" ] && ok "classify: FOLLOWUP-ESCALATE owner=r7 -> r7" || bad "classify: $out"
out="$("$EA" --classify aide 'FOLLOWUP-OVERDUE owner=rb-4189 x')"; [ "$out" = "CLASS followup-owner-route OWNER rb" ] && ok "gone coder id owner maps to rb" || bad "map: $out"
out="$("$EA" --classify aide 'FOLLOWUP-OVERDUE no owner here')"; [ "$out" = "CLASS followup-owner-route OWNER rb" ] && ok "no owner= falls back to rb" || bad "nofield: $out"
"$EA" aide "$L"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/delivered")" = "r7|event-act|0|$L" ] && ok "known class: exit 0, delivered once to r7, SEAT_EVENT_ACT=0, source event-act" || bad "route rc=$rc: $(cat "$T/delivered" 2>/dev/null)"
awk -F'\t' '$2=="action" && $3=="followup-owner-route" && $4=="aide" && $5=="r7" && $6=="none"' "$EVENTS_DIR/event-act-actions.tsv" | grep -q . && ok "kind=action row written, no verdict requested" || bad "action row: $(cat "$EVENTS_DIR/event-act-actions.tsv" 2>/dev/null)"
[ "$(stat -c %a "$EVENTS_DIR/event-act-actions.tsv")" = 600 ] && ok "action log mode 0600" || bad "mode"
"$EA" aide 'something unrelated happened'; [ $? = 10 ] && ok "unknown class: exit 10" || bad "unknown"
"$EA" r7 "$L"; [ $? = 10 ] && ok "line already at its owner: exit 10 (loop guard)" || bad "loop guard"
"$EA" ctl "$L"; [ $? = 10 ] && ok "from_seats filter: ctl-received line not handled" || bad "from filter"
"$EA" aide; [ $? = 64 ] && ok "usage: exit 64" || bad "usage"
EVENT_ACT_TABLE="$T/none.json" "$EA" aide "$L" 2>/dev/null; [ $? = 1 ] && ok "missing table: exit 1" || bad "missing table"
printf '#!/bin/bash\nexit 7\n' >"$T/bad-se"; chmod +x "$T/bad-se"
SEAT_EVENT_BIN="$T/bad-se" "$EA" aide "$L" 2>/dev/null; [ $? = 1 ] && ok "route failure: exit 1" || bad "route fail"
printf '#!/bin/bash\necho "$*" >>"%s/rec"\n' "$T" >"$T/rec-cmd"; chmod +x "$T/rec-cmd"
EVENT_ACT_RECORD_CMD="$T/rec-cmd" "$EA" aide "$L"; [ "$(cat "$T/rec" 2>/dev/null)" = "followup-owner-route r7 aide $L" ] && ok "EVENT_ACT_RECORD_CMD called with class owner seat line" || bad "record cmd: $(cat "$T/rec" 2>/dev/null)"
# seat-event.sh hook-in (real seat-event, fake event-act delivery target is the real script with fake SEAT_EVENT_BIN -> use real chain with inbox seats)
unset SEAT_EVENT_BIN; rm -f "$EVENTS_DIR"/*
"$SE" aide "$L" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q 'owner=r7' "$EVENTS_DIR/aide-events.log" && ok "hook-in: owner seat unknown to seats.tsv -> route fails, line falls through to aide (never lost)" || bad "fallthrough rc=$rc: $(ls "$EVENTS_DIR")"
printf 'r7\tinbox\t-\t0\t0\t-\t-\n' >>"$SEATS_TABLE"
rm -f "$EVENTS_DIR"/*
"$SE" aide "$L" >/dev/null 2>&1
grep -q 'owner=r7' "$EVENTS_DIR/r7-events.log" && [ "$(wc -l <"$EVENTS_DIR/r7-events.log")" = 1 ] && [ ! -e "$EVENTS_DIR/aide-events.log" ] && ok "hook-in with r7 inbox seat: exactly one line at r7, none at aide" || bad "hook-in r7: $(ls "$EVENTS_DIR")"
"$SE" aide "unknown thing for the aide" >/dev/null 2>&1
grep -q 'unknown thing for the aide' "$EVENTS_DIR/aide-events.log" && ok "hook-in: unknown class still appended to aide (seat turn path)" || bad "unknown not appended"
SEAT_EVENT_ACT=0 "$SE" aide "$L" >/dev/null 2>&1
grep -q 'owner=r7' "$EVENTS_DIR/aide-events.log" && ok "SEAT_EVENT_ACT=0 disables the table" || bad "disable"
"$SE" --selftest >/dev/null 2>&1 && ok "seat-event.sh --selftest still passes" || bad "seat-event selftest"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAIL"; exit "$fail"
