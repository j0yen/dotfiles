#!/usr/bin/env bash
# seat-ask.sh <seat> "<text>": fast path to an operator seat. Starts one ASK turn as a transient user unit;
# seat-tick.sh's flock serializes it behind a running tick and waits up to 20 s (seat-ask-inject.sh hands the queue to the running turn); an ask that still cannot lock (or arrives during quota-wait) is QUEUED in
# <seat>-asks.pending and exits 0, so the unit's exit 0 means accepted-or-queued, never dropped. Prints the unit name (stdout).
# SEAT_ASK_DRY=1 (or CTL_ASK_DRY=1) prints the command only. A guard refusal (unit exit 4) or missing goal line (6) within 5 s prints `ASK REFUSED <seat>: <last line>` on stderr and exits that code.
# TIME STAMP (row d335): the text is prefixed by the helper with `<source> <H:MM AM/PM>: ` (source = $EVENT_SOURCE, else $WM_SEAT, else the caller's comm); a typed
# leading label (`rb 6:1x AM:`, `r7 2:19 AM re ctl 2:1x regrade:`) is replaced by the real clock, the `re ...` part kept (rules in .local/lib/seat-time-stamp.sh).
# Counters stamped / typed_label_replaced go to $EVENTS_DIR/<seat>-events.json (EVENTS_DIR, else FLEET_DASH_DIR, else ~/.cache/fleet-dash). `seat-ask.sh --selftest` runs the dry-run checks.
# SEAT_ASK_TICK_BIN overrides the seat-tick.sh path (selftest fake only). Seats come from ~/.claude/state/seats.tsv (SEATS_TABLE overrides).
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
for _l in "${SEAT_STAMP_LIB:-}" "$(dirname "$SELF")/../lib/seat-time-stamp.sh" "$HOME/.local/lib/seat-time-stamp.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type seat_stamp_apply >/dev/null 2>&1 || { echo "seat-ask: seat-time-stamp.sh lib not found (SEAT_STAMP_LIB, ../lib, ~/.local/lib)" >&2; exit 1; }

selftest() {
  local T fail=0 out rc; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=selftest SEAT_TICK_SELFTEST=1 SEAT_STAMP_NOW="9:07 PM" SEAT_ASK_DRY=1 SEAT_ASK_TICK_BIN="$T/fake-tick"
  printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$SEATS_TABLE"
  local J="$EVENTS_DIR/tst-events.json" pre="systemd-run --user --collect --unit seat-ask-tst-"
  ask() { out="$("$SELF" tst "$@" 2>&1)"; rc=$?; got="${out##*$T/fake-tick tst --ask }"; }
  local got
  ask "rb 6:1x AM: typed label body"
  [ "$rc" = 0 ] && [[ "$out" == "$pre"*" -p WorkingDirectory=$HOME $T/fake-tick tst --ask selftest 9:07 PM: typed label body" ]]; chk "typed 'rb 6:1x AM:' replaced by the real stamp, source selftest ($got)" $?
  ask "r7 2:19 AM re ctl 2:1x regrade: second body"
  [ "$got" = "selftest 9:07 PM re ctl 2:1x regrade: second body" ]; chk "'r7 2:19 AM re ctl 2:1x regrade: body' keeps the re part after the real stamp ($got)" $?
  ask "no label here"
  [ "$got" = "selftest 9:07 PM: no label here" ]; chk "no label: just stamped ($got)" $?
  ask "see rb 6:1x AM: in the middle"
  [ "$got" = "selftest 9:07 PM: see rb 6:1x AM: in the middle" ]; chk "a label in the MIDDLE of the text is untouched ($got)" $?
  ask "aide 6:41 AM: already stamped looking"
  [ "$got" = "selftest 9:07 PM: already stamped looking" ]; chk "a leading stamp-looking label is always replaced (not idempotent by design)" $?
  ask rb 6:1x AM: words as separate args
  [ "$got" = "selftest 9:07 PM: words as separate args" ]; chk "argv words are joined first, then the label is replaced ($got)" $?
  [ "$(jq -r '.stamped' "$J")" = 6 ] && [ "$(jq -r '.typed_label_replaced' "$J")" = 4 ] && [ "$(stat -c %a "$J")" = 600 ]; chk "counters: stamped=6 typed_label_replaced=4, json 0600 ($(jq -c '[.stamped,.typed_label_replaced]' "$J"))" $?
  EVENT_SOURCE= WM_SEAT=wmseat "$SELF" tst "plain" 2>&1 | grep -q ' tst --ask wmseat 9:07 PM: plain$'; chk "source falls back to WM_SEAT when EVENT_SOURCE is empty" $?
  local d1 d2; d1="$(LC_ALL=C date '+%-I:%M %p')"; out="$(SEAT_TICK_SELFTEST= "$SELF" tst "real clock body" 2>&1)"; d2="$(LC_ALL=C date '+%-I:%M %p')"
  { [[ "$out" == *" tst --ask selftest $d1: real clock body" ]] || [[ "$out" == *" tst --ask selftest $d2: real clock body" ]]; }; chk "SEAT_STAMP_NOW ignored outside selftest: real clock" $?
  "$SELF" nosuchseat "x" >/dev/null 2>&1; [ $? = 64 ]; chk "unknown seat: exit 64" $?
  "$SELF" tst >/dev/null 2>&1; [ $? = 64 ]; chk "missing text: exit 64" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -ge 2 ] || { echo 'usage: seat-ask.sh <seat> "<text>"' >&2; exit 64; }
seat="$1"; shift
awk -F'\t' -v s="$seat" '!/^[[:space:]]*(#|$)/ && $1==s {f=1} END{exit !f}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" || { echo "seat-ask: unknown seat '$seat'" >&2; exit 64; }
# stamp the text (row d335) and count it; the stamped text is what the seat reads
seat_stamp_apply "$(seat_stamp_source)" "$*"; text="$SEAT_STAMPED"; typed="$SSP_TYPED"
dir="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"
if ( umask 077; mkdir -p "$dir" ) 2>/dev/null; then
  { flock 7; seat_stamp_bump "$dir/$seat-events.json" stamped; [ "$typed" = 1 ] && seat_stamp_bump "$dir/$seat-events.json" typed_label_replaced; } 7>>"$dir/$seat-events.lock" 2>/dev/null
fi
unit="seat-ask-$seat-$(date +%s)-$$"
cmd=(systemd-run --user --collect --unit "$unit" -p "WorkingDirectory=$HOME" "${SEAT_ASK_TICK_BIN:-$HOME/.local/bin/seat-tick.sh}" "$seat" --ask "$text")
if [ "${SEAT_ASK_DRY:-${CTL_ASK_DRY:-}}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
"${cmd[@]}" >/dev/null 2>&1 || { echo "seat-ask: systemd-run failed" >&2; exit 1; }
# A refused ASK must not look like success: wait up to 5 s for the transient unit to exit. --collect unloads the unit, so the exit status
# is read from the user journal ("Main process exited, code=exited, status=N"). 4 = guard refusal, 6 = no /goal line: print the unit's last
# output line, exit that code. A unit still running after 5 s (waiting on the seat lock, or mid-turn) is accepted: prints the unit name.
rc=""; gone=""
for _ in $(seq 1 20); do
  systemctl --user is-active -q "$unit.service" 2>/dev/null || gone=1   # state first, journal second: an exit between the two is still read
  jl="$(journalctl --user -u "$unit.service" -o cat --no-pager 2>/dev/null)"
  rc="$(printf '%s\n' "$jl" | sed -n 's/.*Main process exited, code=exited, status=\([0-9][0-9]*\)\/.*/\1/p' | tail -n1)"
  [ -n "$rc" ] || [ -n "$gone" ] && break
  sleep 0.25
done
case "$rc" in
  4|6)
    last="$(printf '%s\n' "$jl" | grep -v -e "^$unit\.service: " -e '^Started ' -e '^Consumed ' | tail -n1)"
    echo "ASK REFUSED $seat: ${last:-exit $rc, no output}" >&2; exit "$rc" ;;
esac
# exit 0 from seat-tick = accepted OR queued. A queued ask (quota-wait answers at once; a lock wait ends after SEAT_ASK_LOCK_WAIT, usually past this 5 s) says so in the unit's output: tell the two apart on stderr.
qline="$(printf '%s\n' "$jl" | grep "^seat-tick: $seat ask queued (" | tail -n1)"
[ -z "$qline" ] || echo "seat-ask: $seat ask QUEUED, not lost; the seat's next prompt carries it ($qline)" >&2
echo "$unit"
