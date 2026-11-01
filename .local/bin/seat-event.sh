#!/usr/bin/env bash
# seat-event.sh <seat> "<line>": a watcher's bell to an operator seat (10-22, "the operator should closely monitor the build engine").
#   1. appends `<ISO time> | <source> | <stamped line>` to $EVENTS_DIR/<seat>-events.log (0600). source = $EVENT_SOURCE, else $WM_SEAT, else the caller's comm.
#   2. debounce: an identical <line> already appended within 600 s (EVENT_DEBOUNCE_S) is dropped (counted as dropped_dup), exit 0.
#   3. wake: seat lock FREE (flock -n test, released at once) -> `systemd-run --user --collect --unit seat-event-<seat>-<epoch ns>-<pid>
#      seat-tick.sh <seat> --event` (an EVENT turn now); lock HELD (a turn is running) -> touch $EVENTS_DIR/<seat>.wake, and that turn
#      chains one more EVENT turn when it ends (seat-tick.sh step g). Either way the seat's next prompt carries the new lines (events_new=<k>).
#   Counters: $EVENTS_DIR/<seat>-events.json {appended, dropped_dup, woke_tick, woke_deferred, inbox_only, stamped, typed_label_replaced, last_event, last_wake}.
#   TIME STAMP (row d335): the line is stored as `<source> <H:MM AM/PM>[ re ...]: <body>`; a typed leading label (`rb 6:1x AM:`) is replaced by the real
#   clock, never kept (rules + idempotency note in .local/lib/seat-time-stamp.sh). The debounce compares label-stripped bodies, so a repeat a minute later is still a dup.
#   Exit: 0 ok / dropped, 2 empty line, 64 unknown seat or usage, 1 systemd-run failed (the .wake file is touched as the fallback).
#   INBOX-ONLY seats (10-23): a seats.tsv row whose role column is `inbox` (sid `-`, tick_min 0, timeout 0, goal_pattern `-`, old_pid `-`) is a known seat
#   for append + debounce + counters, but is NEVER woken: no systemd-run, no .wake file, counter inbox_only++ instead of woke_*. The aide (Joe's interactive
#   session on carbon, not a unit) is one: a wake would run `claude -p --resume` against the live session, which the guard refuses. The aide reads its
#   log through the UserPromptSubmit/SessionStart hook .claude/hooks/aide-inbox.sh. The row to add by hand (seats.tsv is a hand file; tab-separated):
#       aide<TAB>inbox<TAB>-<TAB>0<TAB>0<TAB>-<TAB>-          printed by `seat-event.sh --inbox-row aide`, so: seat-event.sh --inbox-row aide >> ~/.claude/state/seats.tsv
#   Lanes SELF-REGISTER: aide:<lane> with lane matching $AIDE_LANE_RE (.local/lib/aide-lane.sh, shared with aide-launch.sh) needs no row; an explicit row still wins; aide:main and bare aide need the row as before.
#   LANES (aide-lanes 10-27): a lane of the aide is the seat `aide:<lane>` (`seat-event.sh --inbox-row aide:build`), appended to $EVENTS_DIR/aide-<lane>-events.log
#   and read by aide-inbox.sh under WM_AIDE_LANE=<lane>; `seat-event.sh aide` keeps writing aide-events.log only.
#   SEAT_EVENT_NOWAKE=1: append (and debounce) only, never wake (seat-tick-failed.sh for ctl: a failing ctl tick must not spawn another ctl tick).
# Env: EVENTS_DIR (default FLEET_DASH_DIR or ~/.cache/fleet-dash) EVENT_SOURCE EVENT_DEBOUNCE_S SEATS_TABLE SEAT_EVENT_TICK_BIN SEAT_EVENT_DRY=1 (print the spawn command, run nothing)
# This script never runs claude and never touches a unit it did not create; the only thing it starts is the transient seat-event-* unit.
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
SEATS="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
DEBOUNCE="${EVENT_DEBOUNCE_S:-600}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
for _l in "${SEAT_STAMP_LIB:-}" "$(dirname "$SELF")/../lib/seat-time-stamp.sh" "$HOME/.local/lib/seat-time-stamp.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
for _l in "${AIDE_LANE_LIB:-}" "$(dirname "$SELF")/../lib/aide-lane.sh" "$HOME/.local/lib/aide-lane.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type aide_lane_valid >/dev/null 2>&1 || { echo "seat-event: aide-lane.sh lib not found (AIDE_LANE_LIB, ../lib, ~/.local/lib)" >&2; exit 1; }
type seat_stamp_apply >/dev/null 2>&1 || { echo "seat-event: seat-time-stamp.sh lib not found (SEAT_STAMP_LIB, ../lib, ~/.local/lib)" >&2; exit 1; }

known_seat() { awk -F'\t' -v s="$1" '!/^[[:space:]]*(#|$)/ && $1==s {f=1} END{exit !f}' "$SEATS" 2>/dev/null; }
inbox_seat() { awk -F'\t' -v s="$1" '!/^[[:space:]]*(#|$)/ && $1==s && $2=="inbox" {f=1} END{exit !f}' "$SEATS" 2>/dev/null || { ! known_seat "$1" && self_lane "$1"; }; }
# aide:<lane> (lane != main, valid per aide-lane.sh) self-registers as an inbox seat: same as the --inbox-row aide:<lane> row, no seats.tsv edit. An explicit row wins (awk ran first).
self_lane() { [[ "$1" == aide:* ]] && [ "$1" != aide:main ] && aide_lane_valid "${1#aide:}"; }

# bump <key> [<set key> <value>]: counters in <seat>-events.json, tmp+mv, caller holds the events lock
bump() {
  local key="$1" tmp prog; tmp="$(mktemp "$DIR/.$SEAT-events.XXXXXX")" || return 1
  prog='({appended:0,dropped_dup:0,woke_tick:0,woke_deferred:0,inbox_only:0,stamped:0,typed_label_replaced:0,last_event:null,last_wake:null} + (. // {}))
      | .[$k] += 1 | (if $k=="appended" then .last_event=$iso elif ($k=="woke_tick" or $k=="woke_deferred") then .last_wake=$iso else . end)'
  jq --arg k "$key" --arg iso "$(date -Iseconds)" "$prog" "$JSON" >"$tmp" 2>/dev/null \
    || echo '{}' | jq --arg k "$key" --arg iso "$(date -Iseconds)" "$prog" >"$tmp"   # no/garbled json yet: same program on {} (the first append sets last_event)
  chmod 600 "$tmp"; mv -f "$tmp" "$JSON"
}

selftest() {
  local T fail=0 out rc r1 r2; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=selftest SEAT_TICK_SELFTEST=1 SEAT_STAMP_NOW="9:07 PM"
  printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$SEATS_TABLE"
  local L="$EVENTS_DIR/tst-events.log" J="$EVENTS_DIR/tst-events.json"
  printf '#!/bin/bash\necho "$*" >> "%s/spawned"\n' "$T" >"$T/fake-tick"; chmod +x "$T/fake-tick"
  export SEAT_EVENT_TICK_BIN="$T/fake-tick"

  # 1. append (+ free lock -> dry spawn command)
  out="$(SEAT_EVENT_DRY=1 "$SELF" tst "ALARM landrisk: 1025 CI red" 2>&1)"; rc=$?
  [ "$rc" = 0 ]; chk "append: exit 0" $?
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+ \| selftest \| selftest 9:07 PM: ALARM landrisk: 1025 CI red$' "$L"; chk "append: '<ISO> | <source> | <source> <time>: <line>' ($(tail -n1 "$L" | cut -c1-80))" $?
  [ "$(stat -c %a "$L")" = 600 ] && [ "$(stat -c %a "$J")" = 600 ]; chk "log and json mode 0600" $?
  [[ "$out" == "systemd-run --user --collect --unit seat-event-tst-"*" -p WorkingDirectory=$HOME $T/fake-tick tst --event" ]]; chk "free lock: spawn command (dry): '${out:0:150}'" $?
  [ ! -e "$T/spawned" ] && [ ! -e "$EVENTS_DIR/tst.wake" ]; chk "dry run started nothing and touched no .wake" $?
  [ "$(jq -r '.appended' "$J")" = 1 ] && [ "$(jq -r '.woke_tick' "$J")" = 1 ]; chk "json: appended=1 woke_tick=1" $?
  [ "$(jq -r '.last_event' "$J")" != null ] && [ "$(jq -r '.last_wake' "$J")" != null ]; chk "json: the FIRST-ever append sets last_event and last_wake (not null): $(jq -c '[.last_event,.last_wake]' "$J")" $?

  # 2. debounce: identical line within 600 s -> nothing appended, dropped_dup counted, no wake
  out="$(SEAT_EVENT_DRY=1 "$SELF" tst "ALARM landrisk: 1025 CI red" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(wc -l <"$L")" = 1 ] && [ -z "$out" ] && [ "$(jq -r '.dropped_dup' "$J")" = 1 ]; chk "dup within 600 s: exit 0, log still 1 line, no wake output, dropped_dup=1" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "ALARM landrisk: 1025 CI red!" >/dev/null 2>&1
  [ "$(wc -l <"$L")" = 2 ]; chk "a different line is appended" $?
  old="$(date -d '11 minutes ago' -Iseconds)"; printf '%s | selftest | old line\n' "$old" >>"$L"
  SEAT_EVENT_DRY=1 "$SELF" tst "old line" >/dev/null 2>&1
  [ "$(wc -l <"$L")" = 4 ] && [ "$(jq -r '.dropped_dup' "$J")" = 1 ]; chk "identical line older than 600 s is appended again" $?
  SEAT_EVENT_DRY=1 EVENT_DEBOUNCE_S=0 "$SELF" tst "ALARM landrisk: 1025 CI red" >/dev/null 2>&1
  [ "$(wc -l <"$L")" = 5 ]; chk "EVENT_DEBOUNCE_S=0 disables the debounce" $?

  # 3. lock HELD -> .wake touched, nothing spawned
  ( exec 8>>"$EVENTS_DIR/tst.lock"; flock 8; sleep 4 ) & local ph=$!
  sleep 0.5
  out="$(SEAT_EVENT_DRY=1 "$SELF" tst "held-lock event" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -e "$EVENTS_DIR/tst.wake" ] && [ -z "$out" ] && grep -q ': held-lock event$' "$L" && [ "$(jq -r '.woke_deferred' "$J")" = 1 ]; chk "lock held: exit 0, line appended, .wake touched, no spawn command, woke_deferred=1" $?
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null; rm -f "$EVENTS_DIR/tst.wake"

  # 4. a real transient unit with the fake tick (nothing touches a seat)
  "$SELF" tst "real spawn" >/dev/null 2>&1; rc=$?
  for _ in $(seq 1 40); do [ -s "$T/spawned" ] && break; sleep 0.25; done
  [ "$rc" = 0 ] && [ "$(cat "$T/spawned" 2>/dev/null)" = "tst --event" ]; chk "free lock, no dry: transient unit ran 'fake-tick tst --event' (rc=$rc: $(cat "$T/spawned" 2>/dev/null))" $?

  # 4b. two bells in the same second both start a unit (10-22: the name was seat-event-<seat>-<epoch s>, the second systemd-run failed "unit name taken")
  mkdir -p "$T/fakebin" "$T/units"
  printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = --unit ] && u="$2"; shift; done\n[ -e "%s/units/$u" ] && exit 1\n: >"%s/units/$u"\n' "$T" "$T" >"$T/fakebin/systemd-run"; chmod +x "$T/fakebin/systemd-run"
  PATH="$T/fakebin:$PATH" "$SELF" tst "bell one" >/dev/null 2>&1; r1=$?; PATH="$T/fakebin:$PATH" "$SELF" tst "bell two" >/dev/null 2>&1; r2=$?
  [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(ls "$T/units" | wc -l)" = 2 ] && [ "$(ls "$T/units" | sort -u | wc -l)" = 2 ]; chk "two back-to-back bells: both rc 0, two distinct unit names ($(ls "$T/units" | tr '\n' ' '))" $?
  rm -rf "$T/fakebin" "$T/units"

  # 5. refusals
  "$SELF" nosuchseat "x" >/dev/null 2>&1; [ $? = 64 ]; chk "unknown seat: exit 64" $?
  "$SELF" tst "" >/dev/null 2>&1; [ $? = 2 ]; chk "empty line: exit 2" $?
  "$SELF" tst "   " >/dev/null 2>&1; [ $? = 2 ]; chk "blank line: exit 2" $?
  "$SELF" >/dev/null 2>&1; [ $? = 64 ]; chk "no args: exit 64" $?
  before="$(wc -l <"$L")"; "$SELF" nosuchseat "x" >/dev/null 2>&1; [ ! -e "$EVENTS_DIR/nosuchseat-events.log" ] && [ "$(wc -l <"$L")" = "$before" ]; chk "refusals wrote nothing" $?

  # 5b. NOWAKE: appended, no spawn command, no .wake
  out="$(SEAT_EVENT_NOWAKE=1 SEAT_EVENT_DRY=1 "$SELF" tst "nowake line" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$EVENTS_DIR/tst.wake" ] && grep -q ': nowake line$' "$L"; chk "SEAT_EVENT_NOWAKE=1: line appended, no spawn, no .wake" $?

  # 6. newline in the line is flattened to one log line; source falls back to the caller's comm
  SEAT_EVENT_DRY=1 EVENT_SOURCE= "$SELF" tst $'two\nlines' >/dev/null 2>&1
  tail -n1 "$L" | grep -Eq '\| [^|]+ \| two lines$'; chk "newline flattened, empty EVENT_SOURCE -> caller comm ($(tail -n1 "$L" | cut -c1-70))" $?
  # 7. TIME STAMP (row d335): the helper stamps the real clock; a typed leading label is replaced, never stored (fake clock 9:07 PM, source selftest)
  local n0 s0 t0; n0="$(wc -l <"$L")"; s0="$(jq -r '.stamped' "$J")"; t0="$(jq -r '.typed_label_replaced' "$J")"
  last_line() { tail -n1 "$L" | sed -E 's/^[^|]+ \| [^|]+ \| //'; }
  SEAT_EVENT_DRY=1 "$SELF" tst "rb 6:1x AM: typed label body" >/dev/null 2>&1
  [ "$(last_line)" = "selftest 9:07 PM: typed label body" ]; chk "typed 'rb 6:1x AM:' replaced by the real stamp, source selftest ($(last_line))" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "r7 2:19 AM re ctl 2:1x regrade: second body" >/dev/null 2>&1
  [ "$(last_line)" = "selftest 9:07 PM re ctl 2:1x regrade: second body" ]; chk "'r7 2:19 AM re ctl 2:1x regrade: body' keeps the re part after the real stamp ($(last_line))" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "no label here" >/dev/null 2>&1
  [ "$(last_line)" = "selftest 9:07 PM: no label here" ]; chk "no label: just stamped ($(last_line))" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "see rb 6:1x AM: in the middle" >/dev/null 2>&1
  [ "$(last_line)" = "selftest 9:07 PM: see rb 6:1x AM: in the middle" ]; chk "a label in the MIDDLE of the text is untouched ($(last_line))" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "aide 6:41 AM: already stamped looking" >/dev/null 2>&1
  [ "$(last_line)" = "selftest 9:07 PM: already stamped looking" ]; chk "a leading stamp-looking label is always replaced (not idempotent by design)" $?
  ! tail -n 5 "$L" | grep -v 'in the middle' | grep -Eq '6:1x|2:19|6:41' ; chk "typed clocks (6:1x, 2:19, 6:41) never reach the stored log lines" $?
  [ "$(wc -l <"$L")" = $((n0 + 5)) ] && [ "$(jq -r '.stamped' "$J")" = $((s0 + 5)) ] && [ "$(jq -r '.typed_label_replaced' "$J")" = $((t0 + 3)) ]; chk "counters: +5 stamped, +3 typed_label_replaced ($(jq -c '[.stamped,.typed_label_replaced]' "$J"))" $?
  SEAT_EVENT_DRY=1 "$SELF" tst "rb 6:2x AM: typed label body" >/dev/null 2>&1; SEAT_STAMP_NOW="9:08 PM" SEAT_EVENT_DRY=1 "$SELF" tst "typed label body" >/dev/null 2>&1
  [ "$(wc -l <"$L")" = $((n0 + 5)) ] && [ "$(jq -r '.dropped_dup' "$J")" = 3 ]; chk "debounce compares label-stripped bodies: a repeat with another typed/real clock is a dup (dropped_dup=$(jq -r '.dropped_dup' "$J"))" $?
  # the real clock (no SEAT_STAMP_NOW): matches `date` within the minute; SEAT_STAMP_NOW is IGNORED without SEAT_TICK_SELFTEST=1
  local d1 d2; d1="$(LC_ALL=C date '+%-I:%M %p')"; SEAT_TICK_SELFTEST= SEAT_EVENT_DRY=1 "$SELF" tst "real clock body" >/dev/null 2>&1; d2="$(LC_ALL=C date '+%-I:%M %p')"
  { [ "$(last_line)" = "selftest $d1: real clock body" ] || [ "$(last_line)" = "selftest $d2: real clock body" ]; }; chk "SEAT_STAMP_NOW ignored outside selftest: real clock ($(last_line))" $?

  # 8. INBOX-ONLY seat (role=inbox): known, appended, debounced, counted, never woken (a fake systemd-run records any spawn attempt)
  printf 'ibx\tinbox\t-\t0\t0\t-\t-\n' >>"$SEATS_TABLE"
  local IL="$EVENTS_DIR/ibx-events.log" IJ="$EVENTS_DIR/ibx-events.json"
  mkdir -p "$T/fakebin2"
  printf '#!/bin/bash\necho "$*" >> "%s/sr-called"\n' "$T" >"$T/fakebin2/systemd-run"; chmod +x "$T/fakebin2/systemd-run"
  out="$(PATH="$T/fakebin2:$PATH" SEAT_EVENT_DRY=1 "$SELF" ibx "seat asks: please look at X" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && grep -Eq '^[0-9T:+-]+ \| selftest \| selftest 9:07 PM: seat asks: please look at X$' "$IL"; chk "inbox seat: exit 0, line stamped+appended, DRY prints NO spawn command ('${out:0:80}')" $?
  PATH="$T/fakebin2:$PATH" "$SELF" ibx "second inbox line" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$T/sr-called" ] && [ ! -e "$EVENTS_DIR/ibx.wake" ] && [ "$(wc -l <"$IL")" = 2 ]; chk "inbox seat, real (non-dry) run: no systemd-run called, no .wake, 2 lines" $?
  PATH="$T/fakebin2:$PATH" "$SELF" ibx "second inbox line" >/dev/null 2>&1
  [ "$(wc -l <"$IL")" = 2 ] && [ "$(jq -r '.dropped_dup' "$IJ")" = 1 ]; chk "inbox seat debounces an identical line (dropped_dup=1, still 2 lines)" $?
  [ "$(jq -r '.appended' "$IJ")" = 2 ] && [ "$(jq -r '.inbox_only' "$IJ")" = 2 ] && [ "$(jq -r '.woke_tick' "$IJ")" = 0 ] && [ "$(jq -r '.woke_deferred' "$IJ")" = 0 ] && [ "$(jq -r '.last_wake' "$IJ")" = null ] && [ "$(jq -r '.last_event' "$IJ")" != null ]; chk "inbox counters: appended=2 inbox_only=2 woke_tick=0 woke_deferred=0 last_wake=null: $(jq -c '[.appended,.inbox_only,.woke_tick,.woke_deferred,.last_wake]' "$IJ")" $?
  ( exec 8>>"$EVENTS_DIR/ibx.lock"; flock 8; sleep 2 ) & ph=$!; sleep 0.4
  PATH="$T/fakebin2:$PATH" "$SELF" ibx "while a lock is held" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$EVENTS_DIR/ibx.wake" ] && [ ! -e "$T/sr-called" ]; chk "inbox seat with its lock held: still no .wake and no spawn" $?
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null
  # a normal row still wakes (same fake systemd-run on PATH)
  PATH="$T/fakebin2:$PATH" "$SELF" tst "normal row still wakes" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q -- '--unit seat-event-tst-' "$T/sr-called" 2>/dev/null; chk "normal (role rb) row still wakes: systemd-run called for seat-event-tst-" $?
  rm -rf "$T/fakebin2"
  # --inbox-row prints the exact seats.tsv row (tabs), refuses a bad name
  [ "$("$SELF" --inbox-row aide)" = "$(printf 'aide\tinbox\t-\t0\t0\t-\t-')" ]; chk "--inbox-row aide prints the tab-separated row" $?
  "$SELF" --inbox-row 'bad name' >/dev/null 2>&1; [ $? = 64 ]; chk "--inbox-row refuses a bad seat name (64)" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
if [ "${1:-}" = "--inbox-row" ]; then   # the seats.tsv row for an inbox-only seat; the operator appends it (we never edit the hand file)
  [[ "${2:-}" =~ ^[A-Za-z0-9_:-]+$ ]] || { echo 'usage: seat-event.sh --inbox-row <seat>' >&2; exit 64; }
  printf '%s\tinbox\t-\t0\t0\t-\t-\n' "$2"; exit 0
fi
[ $# -ge 1 ] || { echo 'usage: seat-event.sh <seat> "<line>"  |  seat-event.sh --inbox-row <seat>  |  seat-event.sh --selftest' >&2; exit 64; }
SEAT="$1"; shift
known_seat "$SEAT" || self_lane "$SEAT" || { echo "seat-event: unknown seat '$SEAT' in $SEATS" >&2; exit 64; }
LINE="$(printf '%s' "$*" | tr '\r\n\t' '   ' | sed -E 's/^ +//; s/ +$//')"
[ -n "$LINE" ] || { echo 'seat-event: empty line' >&2; exit 2; }
DIR="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
( umask 077; mkdir -p "$DIR" ) || exit 1
# aide lanes (10-27): `aide:<lane>` is a seat name; its files map `:` -> `-` (aide-build-events.log), `aide` itself is unchanged
LOG="$DIR/${SEAT//:/-}-events.log"; JSON="$DIR/${SEAT//:/-}-events.json"
SRC="$(seat_stamp_source)"
seat_stamp_apply "$SRC" "$LINE"; STAMPED="$SEAT_STAMPED"; TYPED="$SSP_TYPED"

# append + debounce + counters under one lock (events.lock is NOT the seat lock)
dup=0
{
  flock 7
  if [ -s "$LOG" ]; then
    # debounce key = "re ..." part + label-stripped body (the stored lines carry a stamp whose minute changes)
    seat_stamp_parse "$LINE"; key="$SSP_RE|$SSP_BODY"; last=""
    while IFS= read -r l; do
      [[ "$l" =~ ^([^|]+)\ \|\ [^|]+\ \|\ (.*)$ ]] || continue
      ts="${BASH_REMATCH[1]}"; seat_stamp_parse "${BASH_REMATCH[2]}"   # parse reuses BASH_REMATCH
      [ "$SSP_RE|$SSP_BODY" = "$key" ] && last="$ts" || true
    done < <(tail -n 300 "$LOG")
    last="${last%% *}"
    if [ -n "$last" ] && le="$(date -d "$last" +%s 2>/dev/null)" && [ $(( $(date +%s) - le )) -lt "$DEBOUNCE" ]; then dup=1; fi
  fi
  if [ "$dup" = 1 ]; then bump dropped_dup
  else
    [ -e "$LOG" ] || ( umask 077; : >"$LOG" )
    chmod 600 "$LOG"
    printf '%s | %s | %s\n' "$(date -Iseconds)" "$SRC" "$STAMPED" >>"$LOG"
    bump appended; bump stamped; [ "$TYPED" = 1 ] && bump typed_label_replaced
  fi
} 7>>"$DIR/$SEAT-events.lock"
[ "$dup" = 1 ] && exit 0
# inbox-only seat (role=inbox): never woken, whatever the lock state; counted instead
if inbox_seat "$SEAT"; then { flock 7; bump inbox_only; } 7>>"$DIR/$SEAT-events.lock"; exit 0; fi
[ "${SEAT_EVENT_NOWAKE:-}" = 1 ] && exit 0

# wake: is a turn running? (flock -n, released at once; the lock file is the one seat-tick.sh holds for a whole turn)
if ( flock -n 9 ) 9>>"$DIR/$SEAT.lock" 2>/dev/null; then
  cmd=(systemd-run --user --collect --unit "seat-event-$SEAT-$(date +%s%N)-$$" -p "WorkingDirectory=$HOME" "${SEAT_EVENT_TICK_BIN:-$HOME/.local/bin/seat-tick.sh}" "$SEAT" --event)
  { flock 7; bump woke_tick; } 7>>"$DIR/$SEAT-events.lock"
  if [ "${SEAT_EVENT_DRY:-}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
  # a same-second duplicate unit name fails: harmless, the first unit's turn reads this line (it composes its prompt after taking the lock)
  "${cmd[@]}" >/dev/null 2>&1 || { touch "$DIR/$SEAT.wake"; echo "seat-event: systemd-run failed (or unit name taken); .wake touched" >&2; exit 1; }
else
  touch "$DIR/$SEAT.wake"
  { flock 7; bump woke_deferred; } 7>>"$DIR/$SEAT-events.lock"
fi
exit 0
