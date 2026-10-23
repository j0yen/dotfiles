#!/usr/bin/env bash
# verifier-cap-watch.sh: every 2 min on carbon (verifier-cap-watch.timer): ring a bell when MORE than the fleet cap (2) of (aide|rb|r7)-verifier-*.service units are
# active at once. aide-verifier.sh (vcap) holds the cap under ONE fixed lock ($HOME/.local/state/verifier-cap/launch.lock); a count above it can only come from a
# launcher that bypasses the lock (r7's interim gate, a hand systemd-run), so this watches production state, not the launcher.
#   BELL   one line to rb and to ctl via seat-event.sh (source verifier-cap-watch), only when the over-cap count CHANGES: a second tick at the same count is silent,
#          a drop back to <= 2 re-arms it, so the next violation rings again. Read-only otherwise: it never stops, starts or touches a unit.
#   STATE  $VERIFIER_CAP_WATCH_STATE (default ~/.local/state/verifier-cap/watch.last) = the over-cap count last belled (0 = none).
# PREMISE: a launcher that bypasses the fixed verifier-cap lock shows up as more than 2 active *-verifier-* units
# EXPIRES: 2026-11-06T00:00:00-07:00 (past it the watcher logs `disarmed` once and exits 0; re-arm = a reviewed edit of this line or the unit's Environment=)
#   The unit's Environment=VERIFIER_CAP_WATCH_PREMISE / VERIFIER_CAP_WATCH_EXPIRES override the two lines above (the unit is the place a reviewer re-arms).
# Env (injectable): VERIFIER_CAP_WATCH_SYSTEMCTL VERIFIER_CAP_WATCH_BELL VERIFIER_CAP_WATCH_STATE VERIFIER_CAP_WATCH_CAP (selftest only) VERIFIER_CAP_WATCH_EXPIRES VERIFIER_CAP_WATCH_PREMISE
# Exit: 0 always (a tick must never fail the timer) except usage 64. --selftest: fakes in a throwaway dir, touches no unit, state or seat.
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PREMISE="${VERIFIER_CAP_WATCH_PREMISE:-a launcher that bypasses the fixed verifier-cap lock shows up as more than 2 active *-verifier-* units}"
EXPIRES="${VERIFIER_CAP_WATCH_EXPIRES:-2026-11-06T00:00:00-07:00}"
CAP=2
SYSTEMCTL="${VERIFIER_CAP_WATCH_SYSTEMCTL:-systemctl}"
BELL="${VERIFIER_CAP_WATCH_BELL:-seat-event.sh}"
STATE="${VERIFIER_CAP_WATCH_STATE:-$HOME/.local/state/verifier-cap/watch.last}"
[ "${VERIFIER_CAP_WATCH_SELFTEST:-}" != 1 ] || CAP="${VERIFIER_CAP_WATCH_CAP:-$CAP}"

wlog() { echo "$(date -Iseconds) verifier-cap-watch: $*"; }
active_units() {
  "$SYSTEMCTL" --user list-units '*-verifier-*' --state=active,activating,deactivating,reloading --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -E '^(aide|rb|r7)-verifier-.*\.service$'
}

tick() {
  local exp_s now_s units n last=0
  exp_s="$(date -d "$EXPIRES" +%s 2>/dev/null)" || { wlog "disarmed: EXPIRES '$EXPIRES' unparseable"; return 0; }
  now_s="$(date +%s)"
  if [ "$now_s" -ge "$exp_s" ]; then wlog "disarmed: past EXPIRES $EXPIRES (premise: $PREMISE)"; return 0; fi
  units="$(active_units | tr '\n' ' ')"; n="$(printf '%s' "$units" | wc -w)"
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  [ -r "$STATE" ] && last="$(head -n1 "$STATE" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ "$n" -le "$CAP" ]; then
    [ "$last" = 0 ] || { echo 0 >"$STATE"; wlog "back within the cap: $n active"; }
    return 0
  fi
  if [ "$n" = "$last" ]; then wlog "over the cap ($n > $CAP), unchanged since the last bell"; return 0; fi
  local line="verifier-cap-watch: $n verifier units active, cap is $CAP (${units% }): a launcher is bypassing the fixed lock ~/.local/state/verifier-cap/launch.lock; every verifier launch must go through aide-verifier.sh launch --queue"
  EVENT_SOURCE=verifier-cap-watch "$BELL" rb "$line" >/dev/null 2>&1
  EVENT_SOURCE=verifier-cap-watch "$BELL" ctl "$line" >/dev/null 2>&1
  echo "$n" >"$STATE"
  wlog "BELL rb+ctl: $n > $CAP (${units% })"
}

selftest() {
  local T fail=0 n=0 b; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  chk() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
  mkdir -p "$T/bin"
  printf '#!/bin/bash\ncase "$2" in list-units) cat "$FAKE_DIR/active" 2>/dev/null ;; esac\nexit 0\n' >"$T/bin/fake-systemctl"
  printf '#!/bin/bash\nprintf "%%s|%%s|%%s\\n" "${EVENT_SOURCE:-}" "$1" "$2" >>"$FAKE_DIR/bell.log"\n' >"$T/bin/fake-bell"
  chmod +x "$T"/bin/*
  export HOME="$T/home" FAKE_DIR="$T" VERIFIER_CAP_WATCH_SELFTEST=1 VERIFIER_CAP_WATCH_SYSTEMCTL="$T/bin/fake-systemctl" VERIFIER_CAP_WATCH_BELL="$T/bin/fake-bell" \
    VERIFIER_CAP_WATCH_STATE="$T/state/watch.last" VERIFIER_CAP_WATCH_EXPIRES="2999-01-01T00:00:00+00:00"
  unset VERIFIER_CAP_WATCH_CAP
  T_() { "$SELF" "$@" 2>&1; }
  bells() { [ -e "$T/bell.log" ] && wc -l <"$T/bell.log" || echo 0; }
  printf 'aide-verifier-a.service\nrb-verifier-b.service\n' >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 0 ]; chk "2 active (= the cap): no bell" $?
  printf 'aide-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\n' >"$T/active"
  T_ >/dev/null; b="$(bells)"
  [ "$b" = 2 ] && grep -q '^verifier-cap-watch|rb|verifier-cap-watch: 3 verifier units active, cap is 2 (aide-verifier-a.service rb-verifier-b.service r7-verifier-c.service)' "$T/bell.log" \
    && grep -q '^verifier-cap-watch|ctl|' "$T/bell.log"; chk "(g) 3 active: one bell to rb and one to ctl, naming the 3 units ($b lines)" $?
  T_ >/dev/null; [ "$(bells)" = 2 ]; chk "(g) a second tick with 3 still active: no new bell" $?
  printf 'aide-verifier-a.service\nrb-verifier-b.service\n' >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 2 ] && [ "$(cat "$T/state/watch.last")" = 0 ]; chk "(g) back to 2: no bell, state re-armed to 0" $?
  printf 'aide-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\n' >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 4 ]; chk "(g) a new violation after the re-arm (3 again): rings again" $?
  printf 'aide-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\naide-verifier-d.service\n' >"$T/active"
  T_ >/dev/null; [ "$(bells)" = 6 ]; chk "(g) the over-cap count changes 3 -> 4: rings once more" $?
  printf 'aide-verifier-a.service\nrb-verifier-b.service\nr7-verifier-c.service\nother-verifier-x.service\nfoo.service\n' >"$T/active"
  rm -f "$T/state/watch.last" "$T/bell.log"; T_ >/dev/null; [ "$(bells)" = 2 ] && grep -q 'rb|verifier-cap-watch: 3 verifier units' "$T/bell.log"; chk "only (aide|rb|r7)-verifier-*.service units count (other-verifier-x and foo are ignored)" $?
  rm -f "$T/state/watch.last" "$T/bell.log"; out="$(VERIFIER_CAP_WATCH_EXPIRES="2000-01-01T00:00:00+00:00" T_)"
  [ "$(bells)" = 0 ] && [[ "$out" == *disarmed* ]]; chk "past EXPIRES: disarmed, no bell" $?
  out="$(VERIFIER_CAP_WATCH_EXPIRES="garbage" T_)"; [ "$(bells)" = 0 ] && [[ "$out" == *disarmed* ]]; chk "unparseable EXPIRES: disarmed (fails closed), no bell" $?
  grep -qE '^CAP=2$' "$SELF" && ! grep -qE 'SYSTEMCTL" --user (st[o]p|st[a]rt|ki[l]l|re[s]tart)' "$SELF"; chk "the cap is 2 and the script never stops/starts/kills a unit" $?
  echo "selftest: $((n - fail))/$n passed"
  [ "$fail" = 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") tick; exit 0 ;;
  *) sed -n '2,12p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
