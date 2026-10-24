#!/usr/bin/env bash
# seat-ask.sh <seat> "<text>": fast path to an operator seat. Starts one ASK turn as a transient user unit;
# seat-tick.sh's flock serializes it behind a running tick and waits up to 1800 s; an ask that still cannot lock (or arrives during quota-wait) is QUEUED in
# <seat>-asks.pending and exits 0, so the unit's exit 0 means accepted-or-queued, never dropped. Prints the unit name (stdout).
# SEAT_ASK_DRY=1 (or CTL_ASK_DRY=1) prints the command only. A guard refusal (unit exit 4) or missing goal line (6) within 5 s prints `ASK REFUSED <seat>: <last line>` on stderr and exits that code.
# TIME STAMP (row d335): the text is prefixed by the helper with `<source> <H:MM AM/PM>: ` (source = $EVENT_SOURCE, else $WM_SEAT, else the caller's comm); a typed
# leading label (`rb 6:1x AM:`, `r7 2:19 AM re ctl 2:1x regrade:`) is replaced by the real clock, the `re ...` part kept (rules in .local/lib/seat-time-stamp.sh).
# Counters stamped / typed_label_replaced go to $EVENTS_DIR/<seat>-events.json (EVENTS_DIR, else FLEET_DASH_DIR, else ~/.cache/fleet-dash). `seat-ask.sh --selftest` runs the dry-run checks.
# SEAT_ASK_TICK_BIN overrides the seat-tick.sh path (selftest fake only). Seats come from ~/.claude/state/seats.tsv (SEATS_TABLE overrides).
# QUEUE VISIBILITY (sqa v0.2, 10-24: ctl's 12:48/12:52 AM asks reached rb ~30 min late and rb acted on the stale picture): the text the seat reads is prefixed
# `[seat-ask from <src> sent <H:MM AM/PM>; queue=<N> ahead] ` (N = active seat-ask-<seat>-* units when this ask was queued; the running turn counts), so the receiver sees
# how stale the ask may be and re-reads state before acting; after queuing, ONE extra line goes to stderr: `seat-ask: <seat> queue=<N> oldest=<M>m` (N incl. this ask, M = age of
# the oldest active ask unit; `?` when systemctl cannot say). stdout (the unit name) and the exit codes are unchanged. fleet-dash carbon.seat_ask alarms on the same units.
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
for _l in "${SEAT_STAMP_LIB:-}" "$(dirname "$SELF")/../lib/seat-time-stamp.sh" "$HOME/.local/lib/seat-time-stamp.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type seat_stamp_apply >/dev/null 2>&1 || { echo "seat-ask: seat-time-stamp.sh lib not found (SEAT_STAMP_LIB, ../lib, ~/.local/lib)" >&2; exit 1; }

# ask_queue <seat>: sets AQ_N (active ask units for the seat) and AQ_OLD (minutes since the oldest became active); both `?` when systemd cannot say. Read-only; unit names only.
ask_queue() {
  local out rc names ts
  AQ_N="?"; AQ_OLD="?"
  out="$(systemctl --user list-units "seat-ask-$1-*" --all --no-legend --plain 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] || return 0
  names="$(printf '%s\n' "$out" | awk '($3=="active"||$3=="activating"){print $1}')"
  AQ_N="$(printf '%s' "$names" | grep -c .)"
  [ "$AQ_N" -gt 0 ] || { AQ_OLD=0; return 0; }
  # shellcheck disable=SC2086
  ts="$(systemctl --user show --timestamp=unix -p ActiveEnterTimestamp $names 2>/dev/null | sed -n 's/^ActiveEnterTimestamp=@//p' | sort -n | head -n1)"
  [[ "$ts" =~ ^[0-9]+$ ]] && AQ_OLD=$(( ($(date +%s) - ts) / 60 ))
  return 0
}

selftest() {
  local T fail=0 out rc; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=selftest SEAT_TICK_SELFTEST=1 SEAT_STAMP_NOW="9:07 PM" SEAT_ASK_DRY=1 SEAT_ASK_TICK_BIN="$T/fake-tick"
  printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$SEATS_TABLE"
  # stub systemctl / systemd-run / journalctl on a temp PATH: the units the queue count reads live in $STUB_UNITS (`<name> <state> <active-enter epoch>`), systemd-run appends the new unit
  mkdir -p "$T/bin"; export STUB_UNITS="$T/units" STUB_LOG="$T/sr.log"; : >"$STUB_UNITS"
  cat >"$T/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
case "$2" in
  list-units) [ -n "${STUB_BUS_DOWN:-}" ] && { echo "Failed to connect to bus" >&2; exit 1; }
    while read -r n st ep; do [[ "$n" == $3 ]] && echo "$n.service loaded $st running desc"; done <"$STUB_UNITS"; exit 0 ;;
  show) shift 5; for n in "$@"; do n="${n%.service}"; ep="$(awk -v n="$n" '$1==n{print $3}' "$STUB_UNITS")"; echo "ActiveEnterTimestamp=@$ep"; echo; done; exit 0 ;;
  *) exit 3 ;;
esac
EOS
  cat >"$T/bin/systemd-run" <<'EOS'
#!/usr/bin/env bash
[ "${STUB_SR_RC:-0}" = 0 ] || exit "$STUB_SR_RC"
while [ $# -gt 0 ]; do [ "$1" = --unit ] && { echo "$2 active $(date +%s)" >>"$STUB_UNITS"; break; }; shift; done; exit 0
EOS
  printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/journalctl"; chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
  local nowe; nowe="$(date +%s)"
  printf 'seat-ask-tst-100-1 active %s\nseat-ask-tst-200-2 active %s\nseat-ask-tst-300-3 failed %s\nseat-ask-other-100-9 active %s\n' "$((nowe - 720))" "$((nowe - 60))" "$((nowe - 9000))" "$((nowe - 9000))" >"$STUB_UNITS"
  local J="$EVENTS_DIR/tst-events.json" pre="systemd-run --user --collect --unit seat-ask-tst-"
  ask() { out="$("$SELF" tst "$@" 2>&1)"; rc=$?; got="${out##*$T/fake-tick tst --ask }"; got="${got#\[seat-ask from * ahead\] }"; }
  local got
  ask "rb 6:1x AM: typed label body"
  [ "$rc" = 0 ] && [[ "$out" == "$pre"*" -p WorkingDirectory=$HOME $T/fake-tick tst --ask [seat-ask from selftest sent 9:07 PM; queue="*" ahead] selftest 9:07 PM: typed label body" ]]; chk "typed 'rb 6:1x AM:' replaced by the real stamp, source selftest ($got)" $?
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
  EVENT_SOURCE= WM_SEAT=wmseat "$SELF" tst "plain" 2>&1 | grep -Eq ' tst --ask \[seat-ask from wmseat sent 9:07 PM; queue=[0-9?]+ ahead\] wmseat 9:07 PM: plain$'; chk "source falls back to WM_SEAT when EVENT_SOURCE is empty" $?
  local d1 d2; d1="$(LC_ALL=C date '+%-I:%M %p')"; out="$(SEAT_TICK_SELFTEST= "$SELF" tst "real clock body" 2>&1)"; d2="$(LC_ALL=C date '+%-I:%M %p')"
  { [[ "$out" == *" ahead] selftest $d1: real clock body" ]] || [[ "$out" == *" ahead] selftest $d2: real clock body" ]]; }; chk "SEAT_STAMP_NOW ignored outside selftest: real clock" $?
  out="$("$SELF" tst "queue body" 2>&1)"
  [[ "$out" == *" tst --ask [seat-ask from selftest sent 9:07 PM; queue=2 ahead] selftest 9:07 PM: queue body" ]]; cr=$?; chk "t6: the delivered text carries the stamp prefix [seat-ask from selftest sent 9:07 PM; queue=2 ahead] ($(printf '%s' "$out" | grep -o '\[seat-ask[^]]*\]'))" $cr
  local so se; so="$T/so"; se="$T/se"
  SEAT_ASK_DRY= "$SELF" tst "t5 body" >"$so" 2>"$se"; rc=$?
  [ "$rc" = 0 ] && [ "$(wc -l <"$so")" = 1 ] && [[ "$(cat "$so")" =~ ^seat-ask-tst-[0-9]+-[0-9]+$ ]] && [ "$(cat "$se")" = "seat-ask: tst queue=3 oldest=12m" ]; cr=$?; chk "t5: queued: stdout = the unit name only, exit 0, stderr 'seat-ask: tst queue=3 oldest=12m' (2 active + this one; the failed unit and another seat's unit not counted) ($(cat "$se"))" $cr
  STUB_SR_RC=1 SEAT_ASK_DRY= "$SELF" tst "t5 fail" >"$so" 2>"$se"; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$so" ] && [ "$(cat "$se")" = "seat-ask: systemd-run failed" ]; chk "t5: systemd-run failure: exit 1 and message unchanged, no queue line" $?
  STUB_BUS_DOWN=1 SEAT_ASK_DRY= "$SELF" tst "t5 bus" >"$so" 2>"$se"; rc=$?
  [ "$rc" = 0 ] && grep -qx 'seat-ask: tst queue=? oldest=?' "$se"; chk "t5: user bus unreadable: queue=? oldest=? (exit 0, ask still sent)" $?
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
# queue prefix (Fable 1): who sent it, when, and how many ask units were already ahead
src="$(seat_stamp_source)"; sent="${SEAT_STAMPED#"$src "}"; [[ "$sent" =~ ^([0-9]{1,2}:[0-9]{2}\ [AaPp][Mm]) ]] && sent="${BASH_REMATCH[1]}" || sent="?"
ask_queue "$seat"
text="[seat-ask from $src sent $sent; queue=$AQ_N ahead] $text"
unit="seat-ask-$seat-$(date +%s)-$$"
cmd=(systemd-run --user --collect --unit "$unit" -p "WorkingDirectory=$HOME" "${SEAT_ASK_TICK_BIN:-$HOME/.local/bin/seat-tick.sh}" "$seat" --ask "$text")
if [ "${SEAT_ASK_DRY:-${CTL_ASK_DRY:-}}" = 1 ]; then echo "${cmd[*]}"; exit 0; fi
"${cmd[@]}" >/dev/null 2>&1 || { echo "seat-ask: systemd-run failed" >&2; exit 1; }
ask_queue "$seat"; qdepth="seat-ask: $seat queue=$AQ_N oldest=$([[ "$AQ_OLD" =~ ^[0-9]+$ ]] && echo "${AQ_OLD}m" || echo "?")"   # taken now, while the new unit is surely active; printed after the refusal check
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
echo "$qdepth" >&2
echo "$unit"
