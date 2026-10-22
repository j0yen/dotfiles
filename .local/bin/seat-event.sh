#!/usr/bin/env bash
# seat-event.sh <seat> "<line>": a watcher's bell to an operator seat (10-22, "the operator should closely monitor the build engine").
#   1. appends `<ISO time> | <source> | <line>` to $EVENTS_DIR/<seat>-events.log (0600). source = $EVENT_SOURCE, else the caller's comm.
#   2. debounce: an identical <line> already appended within 600 s (EVENT_DEBOUNCE_S) is dropped (counted as dropped_dup), exit 0.
#   3. wake: seat lock FREE (flock -n test, released at once) -> `systemd-run --user --collect --unit seat-event-<seat>-<epoch>
#      seat-tick.sh <seat> --event` (an EVENT turn now); lock HELD (a turn is running) -> touch $EVENTS_DIR/<seat>.wake, and that turn
#      chains one more EVENT turn when it ends (seat-tick.sh step g). Either way the seat's next prompt carries the new lines (events_new=<k>).
#   Counters: $EVENTS_DIR/<seat>-events.json {appended, dropped_dup, woke_tick, woke_deferred, last_event, last_wake}.
#   Exit: 0 ok / dropped, 2 empty line, 64 unknown seat or usage, 1 systemd-run failed (the .wake file is touched as the fallback).
#   SEAT_EVENT_NOWAKE=1: append (and debounce) only, never wake (seat-tick-failed.sh for ctl: a failing ctl tick must not spawn another ctl tick).
# Env: EVENTS_DIR (default FLEET_DASH_DIR or ~/.cache/fleet-dash) EVENT_SOURCE EVENT_DEBOUNCE_S SEATS_TABLE SEAT_EVENT_TICK_BIN SEAT_EVENT_DRY=1 (print the spawn command, run nothing)
# This script never runs claude and never touches a unit it did not create; the only thing it starts is the transient seat-event-* unit.
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
SEATS="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
DEBOUNCE="${EVENT_DEBOUNCE_S:-600}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

known_seat() { awk -F'\t' -v s="$1" '!/^[[:space:]]*(#|$)/ && $1==s {f=1} END{exit !f}' "$SEATS" 2>/dev/null; }

# bump <key> [<set key> <value>]: counters in <seat>-events.json, tmp+mv, caller holds the events lock
bump() {
  local key="$1" tmp; tmp="$(mktemp "$DIR/.$SEAT-events.XXXXXX")" || return 1
  jq --arg k "$key" --arg iso "$(date -Iseconds)" \
     '({appended:0,dropped_dup:0,woke_tick:0,woke_deferred:0,last_event:null,last_wake:null} + (. // {}))
      | .[$k] += 1 | (if $k=="appended" then .last_event=$iso elif ($k=="woke_tick" or $k=="woke_deferred") then .last_wake=$iso else . end)' \
     "$JSON" >"$tmp" 2>/dev/null || echo '{}' | jq --arg k "$key" '{appended:0,dropped_dup:0,woke_tick:0,woke_deferred:0,last_event:null,last_wake:null} | .[$k]=1' >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$JSON"
}

selftest() {
  local T fail=0 out rc; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=selftest
  printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$SEATS_TABLE"
  local L="$EVENTS_DIR/tst-events.log" J="$EVENTS_DIR/tst-events.json"
  printf '#!/bin/bash\necho "$*" >> "%s/spawned"\n' "$T" >"$T/fake-tick"; chmod +x "$T/fake-tick"
  export SEAT_EVENT_TICK_BIN="$T/fake-tick"

  # 1. append (+ free lock -> dry spawn command)
  out="$(SEAT_EVENT_DRY=1 "$SELF" tst "ALARM landrisk: 1025 CI red" 2>&1)"; rc=$?
  [ "$rc" = 0 ]; chk "append: exit 0" $?
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+ \| selftest \| ALARM landrisk: 1025 CI red$' "$L"; chk "append: '<ISO> | <source> | <line>' ($(tail -n1 "$L" | cut -c1-80))" $?
  [ "$(stat -c %a "$L")" = 600 ] && [ "$(stat -c %a "$J")" = 600 ]; chk "log and json mode 0600" $?
  [[ "$out" == "systemd-run --user --collect --unit seat-event-tst-"*" -p WorkingDirectory=$HOME $T/fake-tick tst --event" ]]; chk "free lock: spawn command (dry): '${out:0:150}'" $?
  [ ! -e "$T/spawned" ] && [ ! -e "$EVENTS_DIR/tst.wake" ]; chk "dry run started nothing and touched no .wake" $?
  [ "$(jq -r '.appended' "$J")" = 1 ] && [ "$(jq -r '.woke_tick' "$J")" = 1 ]; chk "json: appended=1 woke_tick=1" $?

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
  [ "$rc" = 0 ] && [ -e "$EVENTS_DIR/tst.wake" ] && [ -z "$out" ] && grep -q '| held-lock event$' "$L" && [ "$(jq -r '.woke_deferred' "$J")" = 1 ]; chk "lock held: exit 0, line appended, .wake touched, no spawn command, woke_deferred=1" $?
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null; rm -f "$EVENTS_DIR/tst.wake"

  # 4. a real transient unit with the fake tick (nothing touches a seat)
  "$SELF" tst "real spawn" >/dev/null 2>&1; rc=$?
  for _ in $(seq 1 40); do [ -s "$T/spawned" ] && break; sleep 0.25; done
  [ "$rc" = 0 ] && [ "$(cat "$T/spawned" 2>/dev/null)" = "tst --event" ]; chk "free lock, no dry: transient unit ran 'fake-tick tst --event' (rc=$rc: $(cat "$T/spawned" 2>/dev/null))" $?

  # 5. refusals
  "$SELF" nosuchseat "x" >/dev/null 2>&1; [ $? = 64 ]; chk "unknown seat: exit 64" $?
  "$SELF" tst "" >/dev/null 2>&1; [ $? = 2 ]; chk "empty line: exit 2" $?
  "$SELF" tst "   " >/dev/null 2>&1; [ $? = 2 ]; chk "blank line: exit 2" $?
  "$SELF" >/dev/null 2>&1; [ $? = 64 ]; chk "no args: exit 64" $?
  before="$(wc -l <"$L")"; "$SELF" nosuchseat "x" >/dev/null 2>&1; [ ! -e "$EVENTS_DIR/nosuchseat-events.log" ] && [ "$(wc -l <"$L")" = "$before" ]; chk "refusals wrote nothing" $?

  # 5b. NOWAKE: appended, no spawn command, no .wake
  out="$(SEAT_EVENT_NOWAKE=1 SEAT_EVENT_DRY=1 "$SELF" tst "nowake line" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$EVENTS_DIR/tst.wake" ] && grep -q '| nowake line$' "$L"; chk "SEAT_EVENT_NOWAKE=1: line appended, no spawn, no .wake" $?

  # 6. newline in the line is flattened to one log line; source falls back to the caller's comm
  SEAT_EVENT_DRY=1 EVENT_SOURCE= "$SELF" tst $'two\nlines' >/dev/null 2>&1
  tail -n1 "$L" | grep -Eq '\| [^|]+ \| two lines$'; chk "newline flattened, empty EVENT_SOURCE -> caller comm ($(tail -n1 "$L" | cut -c1-70))" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -ge 1 ] || { echo 'usage: seat-event.sh <seat> "<line>"  |  seat-event.sh --selftest' >&2; exit 64; }
SEAT="$1"; shift
known_seat "$SEAT" || { echo "seat-event: unknown seat '$SEAT' in $SEATS" >&2; exit 64; }
LINE="$(printf '%s' "$*" | tr '\r\n\t' '   ' | sed -E 's/^ +//; s/ +$//')"
[ -n "$LINE" ] || { echo 'seat-event: empty line' >&2; exit 2; }
DIR="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
( umask 077; mkdir -p "$DIR" ) || exit 1
LOG="$DIR/$SEAT-events.log"; JSON="$DIR/$SEAT-events.json"
SRC="${EVENT_SOURCE:-$(ps -o comm= -p "$PPID" 2>/dev/null)}"; SRC="$(printf '%s' "${SRC:-unknown}" | tr -d '|\n' | sed -E 's/^ +//; s/ +$//')"; SRC="${SRC:-unknown}"

# append + debounce + counters under one lock (events.lock is NOT the seat lock)
dup=0
{
  flock 7
  if [ -s "$LOG" ]; then
    last="$(tail -n 300 "$LOG" | awk -v l="$LINE" '{ if (match($0, /^[^|]+ \| [^|]+ \| /) && substr($0, RLENGTH + 1) == l) t = $1 } END { print t }')"
    if [ -n "$last" ] && le="$(date -d "$last" +%s 2>/dev/null)" && [ $(( $(date +%s) - le )) -lt "$DEBOUNCE" ]; then dup=1; fi
  fi
  if [ "$dup" = 1 ]; then bump dropped_dup
  else
    [ -e "$LOG" ] || ( umask 077; : >"$LOG" )
    chmod 600 "$LOG"
    printf '%s | %s | %s\n' "$(date -Iseconds)" "$SRC" "$LINE" >>"$LOG"
    bump appended
  fi
} 7>>"$DIR/$SEAT-events.lock"
[ "$dup" = 1 ] && exit 0
[ "${SEAT_EVENT_NOWAKE:-}" = 1 ] && exit 0

# wake: is a turn running? (flock -n, released at once; the lock file is the one seat-tick.sh holds for a whole turn)
if ( flock -n 9 ) 9>>"$DIR/$SEAT.lock" 2>/dev/null; then
  cmd=(systemd-run --user --collect --unit "seat-event-$SEAT-$(date +%s)" -p "WorkingDirectory=$HOME" "${SEAT_EVENT_TICK_BIN:-$HOME/.local/bin/seat-tick.sh}" "$SEAT" --event)
  { flock 7; bump woke_tick; } 7>>"$DIR/$SEAT-events.lock"
  if [ "${SEAT_EVENT_DRY:-}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
  # a same-second duplicate unit name fails: harmless, the first unit's turn reads this line (it composes its prompt after taking the lock)
  "${cmd[@]}" >/dev/null 2>&1 || { touch "$DIR/$SEAT.wake"; echo "seat-event: systemd-run failed (or unit name taken); .wake touched" >&2; exit 1; }
else
  touch "$DIR/$SEAT.wake"
  { flock 7; bump woke_deferred; } 7>>"$DIR/$SEAT-events.lock"
fi
exit 0
