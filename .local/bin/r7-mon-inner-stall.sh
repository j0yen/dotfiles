#!/bin/bash
# r7-mon-inner-stall: every 60 s, probe ryzen7 (read-only) for stalled inner units and stale run stages -> R7-BELL lines.
# d-20261021-185321-rb-c116 shape: --selftest first, ssh loss never exits (SSH-FAIL line, 60 s, retry), heartbeat, wp_gate EVERY iteration.
# PREMISE: r7 seat is tick-driven; bells wake it. Reads ryzen7 only (python3 -I stdin probe: state.db mode=ro, systemctl list/show, stat of session JSONLs; NO writes, NO wm-build CLI).
#   Local writes: bells/ only + the guarded seat-event.sh call (turned off when the premise is gone/expired). EXPIRES 2026-11-21.
# <what> keys -> SEAT ACTION (a bell with no action is dropped). Level conditions fire on the edge, once per episode; re-fire after the condition clears or after the refire time:
#   inner-stall       a `claude -p` process is in the unit's cgroup AND coder JSONL (and unit) idle > 15 min   redrive --from inner for that run; report the minutes lost.  refire 2 h
#                     (no claude in the cgroup = coder finished: NEVER inner-stall; the JSONL is stale by design after the coder exits)
#   inner-post-coder-long  no claude, pybuilder/pytest in the cgroup (phase post-coder) for > 5400 s timeout + 10 min   the `timeout 5400s pybuilder refresh` should have killed it: check the unit's process tree + uv/pytest hang, redrive --from inner.  refire 2 h
#   inner-no-session  inner unit active > 15 min, zero JSONLs, phase not post-coder   coder never started: check the unit journal + wt path, redrive --from inner.   refire 2 h
#   stage-stale       no progress > 4 h (steps/land/run start)  read the carried state: paused(..)/daemon-hold(..) = NOT a stall (release the right way); unit-active/no-unit = investigate.  refire 6 h
# Test overrides: R7_HOST, WATCH_RETRY_SLEEP, R7_BELLS_DIR (use mktemp -d), R7_BELL_DRY=1, R7_SEAT_EVENT, WP_STATE.
SCRIPT=r7-mon-inner-stall.sh
NAME=inner-stall
HERE="$(dirname "$(readlink -f "$0")")"
. "$HERE/r7-watch-lib.sh"
. "$WP_LIB" 2>/dev/null || true
PROBE="$HERE/r7-inner-probe.py"
R7_LOOP_S=${R7_LOOP_S:-60}

run_probe() { ssh $R7_SSH_OPTS "$R7_HOST" "python3 -I - $*" < "$PROBE" 2>&1; }

consume() {   # stdin: probe output; stdout: bells via r7_level. Returns 0 when PROBE-END was seen.
  local tag what run act vals end=1 refire
  set -f
  while IFS=$'\t' read -r tag what run act vals; do
    case "$tag" in
      PROBE) case "$what" in stage-stale) refire=21600;; *) refire=7200;; esac
             r7_level "$NAME" "$run" "$what" "$act" "$refire" "$vals" ;;
      PROBE-END) end=0 ;;
    esac
  done
  return $end
}

selftest() {
  local out rc T n
  for b in ssh python3 flock md5sum; do command -v "$b" >/dev/null 2>&1 || { echo "SELFTEST FAIL $SCRIPT missing local binary: $b"; return 1; }; done
  out=$(run_probe --selftest); rc=$?
  case "$out" in "SELFTEST db=ro"*) ;; *) echo "SELFTEST FAIL $SCRIPT remote rc=$rc: $(printf '%s' "${out:-no output}" | tr '\n' ' ' | cut -c1-220)"; return 1;; esac
  # one full probe pass must parse and end with PROBE-END
  out=$(run_probe); rc=$?
  printf '%s\n' "$out" | tail -n1 | grep -q '^PROBE-END$' || { echo "SELFTEST FAIL $SCRIPT probe pass did not end with PROBE-END rc=$rc: $(printf '%s' "$out" | tail -n2 | tr '\n' ' ' | cut -c1-200)"; return 1; }
  n=$(printf '%s\n' "$out" | grep -c '^PROBE	')
  # cgroup phase cases (synthetic listings built inside the probe, no real path read): post-coder with a stale JSONL = 0 bells
  local c want g cases=0
  T=$(mktemp -d) || return 1
  for c in post-coder:0 post-coder-short:0 coder-fresh:0 coder-stalled:1 post-coder-long:1; do
    want=${c#*:}; c=${c%%:*}
    g=$(run_probe --synthetic "$c" | R7_BELLS_DIR=$T R7_STATE_DIR=$T/state R7_BELL_DRY=1 consume | grep '^R7-BELL ')
    if [ "$(printf '%s' "$g" | grep -c .)" != "$want" ]; then rm -rf "$T"; echo "SELFTEST FAIL $SCRIPT cgroup case $c gave $(printf '%s' "$g" | grep -c .) bells (want $want): $(printf '%s' "$g" | cut -c1-160)"; return 1; fi
    case "$c" in coder-stalled) printf '%s' "$g" | grep -q ' inner-stall ' || { rm -rf "$T"; echo "SELFTEST FAIL $SCRIPT coder-stalled bell is not inner-stall"; return 1; };;
                 post-coder-long) printf '%s' "$g" | grep -q ' inner-post-coder-long ' || { rm -rf "$T"; echo "SELFTEST FAIL $SCRIPT post-coder-long bell is not inner-post-coder-long"; return 1; };; esac
    cases=$((cases+1))
  done
  rm -rf "$T"
  # edge logic, tempdir root only: active x2 -> 1 bell; clear; (re-fire inside the 30 min dedup stays quiet)
  T=$(mktemp -d) || return 1
  local got
  got=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state R7_BELL_DRY=1
    printf 'PROBE\tstage-stale\t1/x\t1\tstage=inner\nPROBE\tstage-stale\t1/x\t1\tstage=inner\nPROBE\tinner-stall\t2/y\t0\tx\nPROBE-END\n' | consume | grep -c '^R7-BELL ')
  rm -rf "$T"
  [ "$got" = 1 ] || { echo "SELFTEST FAIL $SCRIPT edge logic gave $got bells for 2 active + 1 clear lines (want 1)"; return 1; }
  r7_selftest_event_err $NAME || return 1
  echo "SELFTEST PASS $SCRIPT $(printf '%s' "$(run_probe --selftest)" | cut -c1-200); full pass = $n PROBE lines; cgroup phase cases $cases/5 (post-coder+stale JSONL -> 0 bells, claude+stale -> inner-stall, post-coder >100m -> inner-post-coder-long); edge logic 2 active -> 1 bell; stub seat-event rc=64 -> 1 EVENT-ERR line, EVENT_SOURCE=r7-mon-$NAME"
}

r7_wp_arm r7-mon-inner-stall "$R7_PREMISE_TEXT" "ssh $R7_SSH_OPTS $R7_HOST 'test -s \$HOME/.local/state/wm-build/state.db'"
if [ "${1:-}" = --selftest ]; then selftest; rc=$?; r7_wp_line || rc=1; exit $rc; fi
R7_HB_NAME=$NAME; export R7_HB_NAME
r7_hb "$NAME"
r7_hb_ticker "$NAME"
trap 'kill $R7_TICKER_PID 2>/dev/null' EXIT
until line=$(selftest); do
  echo "$line"; r7_ssh_fail "$(printf '%s' "$line" | sed -n 's/.* rc=\([0-9]*\).*/\1/p')" "$NAME"
done
echo "$line"
r7_wp_line
while true; do
  r7_hb "$NAME"
  if r7_gate >/dev/null 2>&1; then DRY=${R7_BELL_DRY_USER:-}; else DRY=1; echo "WP-DISARMED r7-mon-inner-stall $(r7_ts) premise gone or expired; seat-event.sh calls off"; fi
  out=$(run_probe); rc=$?
  if printf '%s\n' "$out" | tail -n1 | grep -q '^PROBE-END$'; then
    printf '%s\n' "$out" | R7_BELL_DRY=${DRY:-${R7_BELL_DRY:-}} consume
  else
    r7_ssh_fail "$rc" "$NAME"; continue
  fi
  sleep "$R7_LOOP_S"
done
