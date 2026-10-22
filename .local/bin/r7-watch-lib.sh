# r7-watch-lib.sh -- SOURCED by the r7 seat bell units (r7-mon-journal, r7-mon-inner-stall, r7-mon-host). Copy of rb-watch-lib.sh, host=ryzen7, R7- prefix.
# Shape (rb d-20261021-185321-rb-c116): watchers survive ssh failure, write a heartbeat, run as systemd-user units, each consumer runs its own selftest first (this lib has no entry point).
#   r7_hb NAME            heartbeat: epoch -> $R7_HB_DIR/NAME (tmp + mv); the seat tick reads it
#   r7_hb_ticker NAME     background heartbeat file every 20 s + one "R7-HB" log line every 120 s while the calling script lives
#   r7_ssh_fail RC NAME   one "SSH-FAIL <ts> rc=<n>" line (NEVER a bell, never seat-event.sh), heartbeat, sleep $R7_RETRY_SLEEP (default 60), return
#   r7_wp_arm UNIT TEXT CMD / r7_gate / r7_wp_line   watcher-premise.sh PREMISE + EXPIRES (called on EVERY loop iteration)
#   r7_bell NAME RUN WHAT [VALUES...]   the ONE bell path: dedup (name,run,what) 30 min, global wake budget 6 per rolling hour, log + seat-event.sh
#   r7_level NAME RUN WHAT ACTIVE REFIRE_S [VALUES...]   edge-triggered level condition: fires on the 0->1 edge, re-fires after clear or REFIRE_S
# Test overrides: R7_BELLS_DIR (bells root, ALWAYS a mktemp -d in tests), R7_HB_DIR, R7_SEAT_EVENT (path), R7_BELL_DRY=1 (never call seat-event),
#   WATCH_RETRY_SLEEP, R7_HOST, WP_STATE.
R7_BELLS_DIR=${R7_BELLS_DIR:-$HOME/.cache/r7-seat/bells}
R7_HB_DIR=${R7_HB_DIR:-$R7_BELLS_DIR/heartbeat}
R7_STATE_DIR=${R7_STATE_DIR:-$R7_BELLS_DIR/state}
R7_RETRY_SLEEP=${WATCH_RETRY_SLEEP:-60}
R7_SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o BatchMode=yes"
R7_EXPIRES=${R7_EXPIRES:-2026-11-21T23:59:59}
R7_PREMISE_TEXT="r7 seat is tick-driven; bells wake it"
R7_HOST=${R7_HOST:-ryzen7}
R7_SEAT_EVENT=${R7_SEAT_EVENT:-$HOME/.local/bin/seat-event.sh}
R7_WAKE_MAX=${R7_WAKE_MAX:-6}          # seat-event.sh wakes per rolling hour across ALL r7 bells
R7_DEDUP_S=${R7_DEDUP_S:-1800}         # same (name,run,what) at most once per 30 min
WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
export WP_OWNER=${WP_OWNER:-r7} WP_GATE_TTL=${WP_GATE_TTL:-300}

r7_ts() { date '+%-I:%M:%S%p'; }

r7_hb() {
  local n=${1:-${R7_HB_NAME:-}} t
  [ -n "$n" ] || return 0
  mkdir -p "$R7_HB_DIR" 2>/dev/null || return 0
  t=$R7_HB_DIR/.$n.$$
  { printf '%s\n' "$(date +%s)" > "$t" && mv -f "$t" "$R7_HB_DIR/$n"; } 2>/dev/null || rm -f "$t" 2>/dev/null
  return 0
}

r7_hb_ticker() {
  local n=$1 p=$$
  ( i=0; while kill -0 "$p" 2>/dev/null; do r7_hb "$n"; [ $((i % 6)) = 0 ] && echo "R7-HB $n $(r7_ts)"; i=$((i+1)); sleep 20; done ) &
  R7_TICKER_PID=$!
}

r7_ssh_fail() {
  echo "SSH-FAIL $(r7_ts) rc=${1:-?}"
  r7_hb "${2:-}"
  sleep "$R7_RETRY_SLEEP"
}

r7_wp_arm() {
  declare -F wp_arm >/dev/null || { echo "WP-MISSING $1: $WP_LIB not sourced, writes disarmed"; return 1; }
  wp_arm "$1" "$3" "$R7_EXPIRES" "$2" || echo "WP-MISCONFIGURED $1: wp_arm rejected its arguments, writes disarmed"
}
r7_gate() { declare -F wp_gate >/dev/null || return 1; wp_gate; }
r7_wp_line() {
  local rc=0; r7_gate 2>&1 || rc=$?
  echo "PREMISE $WP_NAME verdict=${WP_VERDICT:-?} armed=${WP_ARMED:-0} defect=${WP_DEFECT:--} expires=$R7_EXPIRES"
  return $rc
}

# one token, no whitespace
_r7_tok() { local s=${1:--}; s=${s//[[:space:]]/_}; printf '%s' "${s:--}"; }

r7_bell() {
  local name=$1 run=$(_r7_tok "${2:--}") what=$(_r7_tok "${3:-?}"); shift 3 2>/dev/null; local vals="$*"
  local sd=$R7_STATE_DIR now line key dd wk n erc
  mkdir -p "$sd/dd" 2>/dev/null; now=$(date +%s)
  key=$(printf '%s|%s|%s' "$name" "$run" "$what" | md5sum | cut -c1-24)
  dd=$sd/dd/$key; wk=$sd/wakes
  (
    flock -w 10 9 || exit 3
    if [ -f "$dd" ] && [ $((now - $(stat -c %Y "$dd" 2>/dev/null || echo 0))) -lt "$R7_DEDUP_S" ]; then exit 2; fi
    : > "$dd"
    line="$name $(r7_ts) $run $what${vals:+ $vals}"
    line=$(printf '%s' "$line" | tr '\n\r' '  ' | cut -c1-400)
    touch "$wk"
    awk -v c=$((now - 3600)) '$1+0 >= c' "$wk" > "$wk.tmp" 2>/dev/null; mv -f "$wk.tmp" "$wk" 2>/dev/null
    n=$(wc -l < "$wk")
    if [ "$n" -ge "$R7_WAKE_MAX" ]; then echo "R7-BELL-OVERFLOW $line"; exit 0; fi
    echo "$now" >> "$wk"
    echo "R7-BELL $line"
    if [ -z "${R7_BELL_DRY:-}" ]; then
      if [ -x "$R7_SEAT_EVENT" ]; then   # contract: 0 ok/dup-dropped, 2 empty line, 64 usage/unknown seat, 1 systemd-run failed (124 = our timeout)
        EVENT_SOURCE=r7-mon-$name timeout 30 "$R7_SEAT_EVENT" r7 "R7-BELL $line" >/dev/null 2>&1
        erc=$?; [ "$erc" = 0 ] || echo "R7-BELL-EVENT-ERR $name $(r7_ts) rc=$erc"
      fi
    fi
    exit 0
  ) 9>"$sd/lock"
  return 0
}

# selftest helper (all 3 units): a stub seat-event that exits 64 -> exactly one R7-BELL-EVENT-ERR line, the stub saw EVENT_SOURCE=r7-mon-<name> and seat "r7", no crash.
# Stub lives in a mktemp -d dir (also first on PATH); the real seat-event.sh is never called. Prints SELFTEST FAIL ... and returns 1 on failure.
r7_selftest_event_err() {
  local name=${1:?} T out n
  T=$(mktemp -d) || return 1
  printf '#!/bin/bash\nprintf "%%s|%%s" "${EVENT_SOURCE:-}" "$1" > "%s/seen"\nexit 64\n' "$T" > "$T/seat-event.sh"; chmod +x "$T/seat-event.sh"
  out=$( PATH="$T:$PATH" R7_BELLS_DIR=$T R7_STATE_DIR=$T/state R7_SEAT_EVENT=$T/seat-event.sh R7_BELL_DRY= r7_bell "$name" 1/x selftest-event-err 2>&1 )
  n=$(printf '%s\n' "$out" | grep -c "^R7-BELL-EVENT-ERR $name .* rc=64$")
  if [ "$n" != 1 ] || [ "$(cat "$T/seen" 2>/dev/null)" != "r7-mon-$name|r7" ]; then
    echo "SELFTEST FAIL stub seat-event rc=64 gave $n EVENT-ERR lines, stub saw '$(cat "$T/seen" 2>/dev/null)' (want 1 and r7-mon-$name|r7): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; rm -rf "$T"; return 1
  fi
  rm -rf "$T"
}

# edge-triggered level condition. ACTIVE 1/0. State file under $R7_STATE_DIR/lv: exists while the condition is active.
r7_level() {
  local name=$1 run=$(_r7_tok "${2:--}") what=$(_r7_tok "$3") active=$4 refire=$5; shift 5; local vals="$*"
  local f=$R7_STATE_DIR/lv/$(printf '%s|%s|%s' "$name" "$run" "$what" | md5sum | cut -c1-24) now; now=$(date +%s)
  mkdir -p "$R7_STATE_DIR/lv" 2>/dev/null
  if [ "$active" = 1 ]; then
    if [ ! -f "$f" ] || [ $((now - $(stat -c %Y "$f" 2>/dev/null || echo 0))) -ge "$refire" ]; then
      : > "$f"; r7_bell "$name" "$run" "$what" $vals
    fi
  else
    rm -f "$f" 2>/dev/null
  fi
  return 0
}
