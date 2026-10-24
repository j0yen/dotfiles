#!/usr/bin/env bash
# verifier-cap-watch.sh: every 2 min on carbon (verifier-cap-watch.timer): ring a bell when MORE than the fleet ceiling (SLOT_CEIL = 4) of (aide|rb|r7)-verifier-*.service
# units are active at once, OR when any active unit's MemoryPeak tops PEAK_MB (1024, the per-verifier admission price in aide-verifier.sh). aide-verifier.sh (vcap v0.3) holds
# the ceiling under ONE fixed lock ($HOME/.local/state/verifier-cap/launch.lock); a count above it can only come from a launcher that bypasses the lock (r7's interim gate,
# a hand systemd-run), and a peak above the price means the admission formula under-prices a verifier: this watches production state, not the launcher.
#   BELL   one line to rb and to ctl via seat-event.sh (source verifier-cap-watch). Over-ceiling: only when the over-ceiling count CHANGES (a second tick at the same count is
#          silent, a drop back to <= 4 re-arms it). Peak: only when the max observed MemoryPeak CHANGES upward and is above PEAK_MB. Read-only otherwise: it never stops,
#          starts or touches a unit.
#   STATE  $VERIFIER_CAP_WATCH_STATE (default ~/.local/state/verifier-cap/watch.last) = the over-ceiling count last belled (0 = none).
#          $VERIFIER_CAP_WATCH_PEAK (default ~/.local/state/verifier-cap/peak.json) = {"max_peak_mb":N,"unit":"...","at":"<iso>"}: the highest MemoryPeak seen on any
#          active verifier unit (it only rises; written whenever a tick sees a higher one, belled only when that new max is above PEAK_MB).
# PREMISE: a launcher that bypasses the fixed verifier-cap lock shows up as more than 4 active *-verifier-* units, and a verifier whose MemoryPeak exceeds 1024 MB shows up in the MemoryPeak of its unit
# EXPIRES: 2026-11-06T00:00:00-07:00 (past it the watcher logs `disarmed` once and exits 0; re-arm = a reviewed edit of this line or the unit's Environment=)
#   The unit's Environment=VERIFIER_CAP_WATCH_PREMISE / VERIFIER_CAP_WATCH_EXPIRES override the two lines above (the unit is the place a reviewer re-arms).
# Env (injectable): VERIFIER_CAP_WATCH_SYSTEMCTL VERIFIER_CAP_WATCH_BELL VERIFIER_CAP_WATCH_STATE VERIFIER_CAP_WATCH_PEAK VERIFIER_CAP_WATCH_CAP / VERIFIER_CAP_WATCH_PEAK_MB (selftest only)
#   VERIFIER_CAP_WATCH_EXPIRES VERIFIER_CAP_WATCH_PREMISE
# Exit: 0 always (a tick must never fail the timer) except usage 64. --selftest: fakes in a throwaway dir, touches no unit, state or seat.
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PREMISE="${VERIFIER_CAP_WATCH_PREMISE:-a launcher that bypasses the fixed verifier-cap lock shows up as more than 4 active *-verifier-* units, and a verifier whose MemoryPeak exceeds 1024 MB shows up in the MemoryPeak of its unit}"
EXPIRES="${VERIFIER_CAP_WATCH_EXPIRES:-2026-11-06T00:00:00-07:00}"
CAP=4
PEAK_MB=1024
SYSTEMCTL="${VERIFIER_CAP_WATCH_SYSTEMCTL:-systemctl}"
BELL="${VERIFIER_CAP_WATCH_BELL:-seat-event.sh}"
STATE="${VERIFIER_CAP_WATCH_STATE:-$HOME/.local/state/verifier-cap/watch.last}"
PEAKFILE="${VERIFIER_CAP_WATCH_PEAK:-$HOME/.local/state/verifier-cap/peak.json}"
if [ "${VERIFIER_CAP_WATCH_SELFTEST:-}" = 1 ]; then CAP="${VERIFIER_CAP_WATCH_CAP:-$CAP}"; PEAK_MB="${VERIFIER_CAP_WATCH_PEAK_MB:-$PEAK_MB}"; fi

wlog() { echo "$(date -Iseconds) verifier-cap-watch: $*"; }
active_units() {
  "$SYSTEMCTL" --user list-units '*-verifier-*' --state=active,activating,deactivating,reloading --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(aide|rb|r7)-verifier-.*\.service$'
}

# peak_check <units...>: record the highest MemoryPeak (MB) seen on any active unit; bell rb + ctl when the recorded max rises above PEAK_MB
peak_check() {
  local u v mb max=0 maxu="" cur=0 line
  for u in "$@"; do
    v="$("$SYSTEMCTL" --user show -p MemoryPeak --value "$u" 2>/dev/null | head -n1)"
    [[ "$v" =~ ^[0-9]+$ ]] && [ "${#v}" -le 15 ] || continue   # "[not set]", empty and the 2^64-1 sentinel are no reading
    mb=$((v / 1048576))
    if [ "$mb" -gt "$max" ]; then max="$mb"; maxu="$u"; fi
  done
  [ "$max" -gt 0 ] || return 0
  [ -r "$PEAKFILE" ] && cur="$(jq -r '.max_peak_mb // 0' "$PEAKFILE" 2>/dev/null)"; [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
  [ "$max" -gt "$cur" ] || return 0
  mkdir -p "$(dirname "$PEAKFILE")" 2>/dev/null
  jq -n --argjson m "$max" --arg u "${maxu%.service}" --arg at "$(date -Iseconds)" '{max_peak_mb:$m,unit:$u,at:$at}' >"$PEAKFILE.tmp.$$" 2>/dev/null && mv -f -- "$PEAKFILE.tmp.$$" "$PEAKFILE"
  [ "$max" -gt "$PEAK_MB" ] || { wlog "new max MemoryPeak ${max} MB on $maxu (<= PEAK_MB $PEAK_MB): recorded, no bell"; return 0; }
  line="verifier-cap-watch: $maxu MemoryPeak ${max} MB exceeds PEAK_MB ${PEAK_MB} (the per-verifier admission price in aide-verifier.sh): the room formula under-prices a verifier; new max recorded in ~/.local/state/verifier-cap/peak.json; raise PEAK_MB by a reviewed edit"
  EVENT_SOURCE=verifier-cap-watch "$BELL" rb "$line" >/dev/null 2>&1
  EVENT_SOURCE=verifier-cap-watch "$BELL" ctl "$line" >/dev/null 2>&1
  wlog "BELL rb+ctl: peak ${max} MB > ${PEAK_MB} ($maxu)"
}

tick() {
  local exp_s now_s units n last=0
  exp_s="$(date -d "$EXPIRES" +%s 2>/dev/null)" || { wlog "disarmed: EXPIRES '$EXPIRES' unparseable"; return 0; }
  now_s="$(date +%s)"
  if [ "$now_s" -ge "$exp_s" ]; then wlog "disarmed: past EXPIRES $EXPIRES (premise: $PREMISE)"; return 0; fi
  units="$(active_units | tr '\n' ' ')"; n="$(printf '%s' "$units" | wc -w)"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  # shellcheck disable=SC2086
  peak_check $units
  [ -r "$STATE" ] && last="$(head -n1 "$STATE" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ "$n" -le "$CAP" ]; then
    [ "$last" = 0 ] || { echo 0 >"$STATE"; wlog "back within the ceiling: $n active"; }
    return 0
  fi
  if [ "$n" = "$last" ]; then wlog "over the ceiling ($n > $CAP), unchanged since the last bell"; return 0; fi
  local line="verifier-cap-watch: $n verifier units active, ceiling is $CAP (${units% }): a launcher is bypassing the fixed lock ~/.local/state/verifier-cap/launch.lock; every verifier launch must go through aide-verifier.sh launch --queue"
  EVENT_SOURCE=verifier-cap-watch "$BELL" rb "$line" >/dev/null 2>&1
  EVENT_SOURCE=verifier-cap-watch "$BELL" ctl "$line" >/dev/null 2>&1
  echo "$n" >"$STATE"
  wlog "BELL rb+ctl: $n > $CAP (${units% })"
}

selftest() {
  local T fail=0 n=0 b out; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
  mkdir -p "$T/bin" "$T/mem"
  # fake systemctl: list-units from $FAKE_DIR/active; `--user show -p MemoryPeak --value <unit>` from $FAKE_DIR/mem/<unit> (bytes), else "[not set]"
  printf '#!/bin/bash\ncase "$2" in list-units) cat "$FAKE_DIR/active" 2>/dev/null ;; show) f="$FAKE_DIR/mem/$6"; if [ -r "$f" ]; then cat "$f"; else echo "[not set]"; fi ;; esac\nexit 0\n' >"$T/bin/fake-systemctl"
  printf '#!/bin/bash\nprintf "%%s|%%s|%%s\\n" "${EVENT_SOURCE:-}" "$1" "$2" >>"$FAKE_DIR/bell.log"\n' >"$T/bin/fake-bell"
  chmod +x "$T"/bin/*
  export HOME="$T/home" FAKE_DIR="$T" VERIFIER_CAP_WATCH_SELFTEST=1 VERIFIER_CAP_WATCH_SYSTEMCTL="$T/bin/fake-systemctl" VERIFIER_CAP_WATCH_BELL="$T/bin/fake-bell" \
    VERIFIER_CAP_WATCH_STATE="$T/state/watch.last" VERIFIER_CAP_WATCH_PEAK="$T/state/peak.json" VERIFIER_CAP_WATCH_EXPIRES="2999-01-01T00:00:00+00:00"
  unset VERIFIER_CAP_WATCH_CAP VERIFIER_CAP_WATCH_PEAK_MB
  T_() { "$SELF" "$@" 2>&1; }
  bells() { [ -e "$T/bell.log" ] && wc -l <"$T/bell.log" || echo 0; }
  mb() { echo $(($1 * 1048576)); }
  local U4=$'aide-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\naide-verifier-d.service\n'
  printf '%s' "$U4" >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 0 ]; chk "4 active (= the ceiling): no bell" $?
  printf '%saide-verifier-e.service\n' "$U4" >"$T/active"
  T_ >/dev/null; b="$(bells)"
  [ "$b" = 2 ] && grep -q '^verifier-cap-watch|rb|verifier-cap-watch: 5 verifier units active, ceiling is 4 (aide-verifier-a.service rb-verifier-b.service r7-verifier-c.service aide-verifier-d.service aide-verifier-e.service)' "$T/bell.log" \
    && grep -q '^verifier-cap-watch|ctl|' "$T/bell.log"; chk "(g) 5 active: one bell to rb and one to ctl, naming the 5 units ($b lines)" $?
  T_ >/dev/null; [ "$(bells)" = 2 ]; chk "(g) a second tick with 5 still active: no new bell" $?
  printf '%s' "$U4" >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 2 ] && [ "$(cat "$T/state/watch.last")" = 0 ]; chk "(g) back to 4: no bell, state re-armed to 0" $?
  printf '%saide-verifier-e.service\n' "$U4" >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 4 ]; chk "(g) a new violation after the re-arm (5 again): rings again" $?
  printf '%saide-verifier-e.service\nrb-verifier-f.service\n' "$U4" >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 6 ]; chk "(g) the over-ceiling count changes 5 -> 6: rings once more" $?
  printf '%saide-verifier-e.service\nother-verifier-x.service\nfoo.service\n' "$U4" >"$T/active"
  rm -f "$T/state/watch.last" "$T/bell.log"; T_ >/dev/null; [ "$(bells)" = 2 ] && grep -q 'rb|verifier-cap-watch: 5 verifier units' "$T/bell.log"; chk "only (aide|rb|r7)-verifier-*.service units count (other-verifier-x and foo are ignored)" $?
  rm -f "$T/state/watch.last" "$T/bell.log"; out="$(VERIFIER_CAP_WATCH_EXPIRES="2000-01-01T00:00:00+00:00" T_)"
  [ "$(bells)" = 0 ] && [[ "$out" == *disarmed* ]]; chk "past EXPIRES: disarmed, no bell" $?
  out="$(VERIFIER_CAP_WATCH_EXPIRES="garbage" T_)"; [ "$(bells)" = 0 ] && [[ "$out" == *disarmed* ]]; chk "unparseable EXPIRES: disarmed (fails closed), no bell" $?
  # ---- (6) MemoryPeak vs PEAK_MB; peak.json holds the max observed, bell only on a change above PEAK_MB ----
  rm -f "$T/state/watch.last" "$T/bell.log" "$T/state/peak.json"; printf 'rb-verifier-a.service\naide-verifier-b.service\n' >"$T/active"
  mb 600 >"$T/mem/rb-verifier-a.service"; mb 900 >"$T/mem/aide-verifier-b.service"
  T_ >/dev/null
  [ "$(bells)" = 0 ] && [ "$(jq -r '.max_peak_mb' "$T/state/peak.json")" = 900 ] && [ "$(jq -r '.unit' "$T/state/peak.json")" = aide-verifier-b ] && jq -e '.at | test("^20")' "$T/state/peak.json" >/dev/null; chk "(6) peaks 600/900 MB (<= PEAK_MB 1024): no bell, peak.json = {max_peak_mb 900, unit aide-verifier-b, at}" $?
  mb 1500 >"$T/mem/rb-verifier-a.service"
  T_ >/dev/null; b="$(bells)"
  [ "$b" = 2 ] && grep -q '^verifier-cap-watch|rb|verifier-cap-watch: rb-verifier-a.service MemoryPeak 1500 MB exceeds PEAK_MB 1024' "$T/bell.log" && grep -q '^verifier-cap-watch|ctl|' "$T/bell.log" \
    && [ "$(jq -r '.max_peak_mb' "$T/state/peak.json")" = 1500 ] && [ "$(jq -r '.unit' "$T/state/peak.json")" = rb-verifier-a ]; chk "(6) a unit at 1500 MB > PEAK_MB 1024: one bell to rb and one to ctl, peak.json max 1500 ($b lines)" $?
  T_ >/dev/null; [ "$(bells)" = 2 ]; chk "(6) the same peak on the next tick: no new bell (bell only on change)" $?
  mb 1200 >"$T/mem/rb-verifier-a.service"
  T_ >/dev/null; [ "$(bells)" = 2 ] && [ "$(jq -r '.max_peak_mb' "$T/state/peak.json")" = 1500 ]; chk "(6) a lower reading later: no bell, the recorded max stays 1500" $?
  mb 2000 >"$T/mem/aide-verifier-b.service"
  T_ >/dev/null; [ "$(bells)" = 4 ] && [ "$(jq -r '.max_peak_mb' "$T/state/peak.json")" = 2000 ]; chk "(6) a higher peak (2000): rings again, max 2000" $?
  rm -f "$T/bell.log" "$T/state/peak.json"; : >"$T/active"; rm -f "$T/mem"/*
  printf 'rb-verifier-a.service\n' >"$T/active"; echo "[not set]" >"$T/mem/rb-verifier-a.service"
  T_ >/dev/null; [ "$(bells)" = 0 ] && [ ! -e "$T/state/peak.json" ]; chk "(6) MemoryPeak '[not set]': no bell, no peak.json" $?
  echo 18446744073709551615 >"$T/mem/rb-verifier-a.service"
  T_ >/dev/null; [ "$(bells)" = 0 ] && [ ! -e "$T/state/peak.json" ]; chk "(6) MemoryPeak = the 2^64-1 sentinel: no reading" $?
  mb 1100 >"$T/mem/rb-verifier-a.service"; out="$(VERIFIER_CAP_WATCH_PEAK_MB=1200 T_)"; [ "$(bells)" = 0 ] && [ "$(jq -r '.max_peak_mb' "$T/state/peak.json")" = 1100 ]; chk "(6) the PEAK_MB override (selftest only): 1100 <= 1200 -> recorded, no bell" $?
  rm -f "$T/bell.log" "$T/state/peak.json" "$T/state/watch.last"; mb 1100 >"$T/mem/rb-verifier-a.service"
  VERIFIER_CAP_WATCH_SELFTEST=0 VERIFIER_CAP_WATCH_PEAK_MB=2000 T_ >/dev/null; [ "$(bells)" = 2 ]; chk "(6) without VERIFIER_CAP_WATCH_SELFTEST=1 the PEAK_MB env is ignored: 1100 > 1024 still rings" $?
  grep -qE '^CAP=4$' "$SELF" && grep -qE '^PEAK_MB=1024$' "$SELF" && ! grep -qE 'SYSTEMCTL" --user (st[o]p|st[a]rt|ki[l]l|re[s]tart)' "$SELF"; chk "the ceiling is 4, PEAK_MB 1024, and the script never stops/starts/kills a unit" $?
  echo "selftest: $((n - fail))/$n passed"
  [ "$fail" = 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") tick; exit 0 ;;
  *) sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
