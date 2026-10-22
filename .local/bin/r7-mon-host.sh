#!/bin/bash
# r7-mon-host: every 30 s, probe ryzen7 host health (read-only) -> R7-BELL lines. d-20261021-185321-rb-c116 shape: --selftest first, ssh loss never exits
# (SSH-FAIL line, 30 s, retry), heartbeat, wp_gate EVERY iteration.
# PREMISE: r7 seat is tick-driven; bells wake it. Reads ryzen7 only (ssh bash -s: cgroup memory.events, journalctl -k, /proc/pressure, df, systemctl show; NO writes).
#   Local writes: bells/ only + the guarded seat-event.sh call (off when the premise is gone/expired). EXPIRES 2026-11-21.
# <what> keys -> SEAT ACTION (a bell with no action is dropped). Level conditions fire on the edge, once per episode, re-fire after the condition clears or after 6 h:
#   oom-kill         oom_kill increment in a wm-build*.service memory.events   find the run behind the unit, redrive --from <stage>, check the MemGate cap for that role
#   oom-kernel       journalctl -k "out of memory" in the last 2 min            same; also read `journalctl -k` for the victim, then shed load (pause the youngest run)
#   psi-mem          memory some avg10 > 40 for 3 consecutive samples (90 s)    pressure shed: pause the youngest inner or lower max_runs by decision row; watch swap
#   psi-io           io some avg10 > 60 for 3 consecutive samples (90 s)        find the IO hog (cold target on HDD? cargo hand job?), pause it
#   df-inode         df -i /tmp >= 90 %                                          check df -i (leaked synthorg-nested-pytest-tmp-* dirs), run r7-tmp-inode-guard
#   df-root          df -h / >= 90 %                                             reap worktrees/targets/receipt-cache per playbook, cordon admission if > 95 %
#   daemon-down      wm-build.service not active                                 `systemctl --user status`, restart per playbook; runs without a driver are reaped
#   daemon-restart   wm-build.service ActiveEnterTimestamp changed              daemon restarted: read the tail of its journal, check limits-drift / config-restart-required
#   freeze-suspect   ssh to ryzen7 failed >= 8 consecutive times at 30 s (4 min) AND a failing ping of its tailscale IP (`tailscale ip -4 ryzen7` on carbon; the IP is never printed)
#                                                                                 host frozen/off: tell Joe/rb, do NOT touch runs until ssh is back; then read journal for the gap
# A 2-min ssh 255 flap on hotspot reassignment is normal (CLAUDE.md network note): 8 x 30 s outlasts it. SSH-FAIL lines NEVER call seat-event.sh.
# Test overrides: R7_HOST, R7_BELLS_DIR (use mktemp -d), R7_BELL_DRY=1, R7_SEAT_EVENT, WP_STATE, R7_LOOP_S, FREEZE_N.
SCRIPT=r7-mon-host.sh
NAME=host
HERE="$(dirname "$(readlink -f "$0")")"
. "$HERE/r7-watch-lib.sh"
. "$WP_LIB" 2>/dev/null || true
PROBE="$HERE/r7-host-probe.sh"
R7_LOOP_S=${R7_LOOP_S:-30}
R7_RETRY_SLEEP=${R7_LOOP_S}
FREEZE_N=${FREEZE_N:-8}
declare -A PREV_OOM
PREV_SVC_TS=""; PSI_MEM_N=0; PSI_IO_N=0; SSH_FAILS=0; HAVE_BASE=0

run_probe() { ssh $R7_SSH_OPTS "$R7_HOST" 'bash -s' < "$PROBE" 2>&1; }
gt() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
ge() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

ts_probe() {   # 0 = ryzen7 answers a ping on its tailscale IP; 1 = no. The IP stays inside this function.
  local ip; ip=$(tailscale ip -4 "$R7_HOST" 2>/dev/null | head -n1)
  [ -n "$ip" ] || return 1
  ping -c1 -W5 "$ip" >/dev/null 2>&1
}

evaluate() {   # stdin: one probe pass. State in PREV_*; called in the main shell (here-string), never in a pipeline
  local k a b act
  while read -r k a b; do
    case "$k" in
      OOM) if [ "$HAVE_BASE" = 1 ] && [ -n "${PREV_OOM[$a]:-}" ] && [ "${b:-0}" -gt "${PREV_OOM[$a]}" ] 2>/dev/null; then r7_bell "$NAME" "$a" oom-kill "oom_kill=${PREV_OOM[$a]}->$b"; fi
           PREV_OOM[$a]=${b:-0} ;;
      KOOM) [ "${a:-0}" -gt 0 ] 2>/dev/null && r7_bell "$NAME" - oom-kernel "kernel_oom_lines_2min=$a" ;;
      PSIMEM) if gt "$a" 40; then PSI_MEM_N=$((PSI_MEM_N+1)); else PSI_MEM_N=0; fi
              act=0; [ "$PSI_MEM_N" -ge 3 ] && act=1; r7_level "$NAME" - psi-mem "$act" 21600 "mem_some_avg10=$a(>40 x$PSI_MEM_N)" ;;
      PSIIO) if gt "$a" 60; then PSI_IO_N=$((PSI_IO_N+1)); else PSI_IO_N=0; fi
             act=0; [ "$PSI_IO_N" -ge 3 ] && act=1; r7_level "$NAME" - psi-io "$act" 21600 "io_some_avg10=$a(>60 x$PSI_IO_N)" ;;
      DFI) act=0; ge "$a" 90 && act=1; r7_level "$NAME" - df-inode "$act" 21600 "tmp_inode_use=${a}%" ;;
      DFH) act=0; ge "$a" 90 && act=1; r7_level "$NAME" - df-root "$act" 21600 "root_use=${a}%" ;;
      SVC) act=0; [ "$a" != active ] && act=1; r7_level "$NAME" wm-build.service daemon-down "$act" 21600 "state=$a"
           if [ "$a" = active ] && [ -n "$PREV_SVC_TS" ] && [ "$PREV_SVC_TS" != "$b" ]; then r7_bell "$NAME" wm-build.service daemon-restart "enter_ts_mono_us=$PREV_SVC_TS->$b"; fi
           [ "$a" = active ] && PREV_SVC_TS=$b ;;
      END) HAVE_BASE=1 ;;
    esac
  done
}

selftest() {
  local out rc T got missing="" k
  for b in ssh flock md5sum ping tailscale; do command -v "$b" >/dev/null 2>&1 || { echo "SELFTEST FAIL $SCRIPT missing local binary: $b"; return 1; }; done
  out=$(run_probe); rc=$?
  for k in OOM KOOM PSIMEM PSIIO DFI DFH SVC END; do printf '%s\n' "$out" | grep -q "^$k " || printf '%s\n' "$out" | grep -qx "$k" || missing="$missing $k"; done
  [ -z "$missing" ] || { echo "SELFTEST FAIL $SCRIPT rc=$rc probe lacks:$missing :: $(printf '%s' "$out" | head -n3 | tr '\n' ' ' | cut -c1-200)"; return 1; }
  out2=$(ssh $R7_SSH_OPTS "$R7_HOST" 'journalctl -k -n1 -q --no-pager >/dev/null 2>&1 && echo kjournal-readable; test -r /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/wm-build.service/memory.events && echo memory.events-exists' 2>&1)
  case "$out2" in *kjournal-readable*memory.events-exists*) ;; *) echo "SELFTEST FAIL $SCRIPT remote observability: $(printf '%s' "$out2" | tr '\n' ' ' | cut -c1-160)"; return 1;; esac
  tailscale ip -4 "$R7_HOST" >/dev/null 2>&1 || { echo "SELFTEST FAIL $SCRIPT cannot resolve ryzen7 tailscale IP (freeze corroboration impossible)"; return 1; }
  # logic, tempdir root only: sustained PSI (2 samples quiet, 3rd bells once), oom increment, restart, no bell on a baseline pass
  T=$(mktemp -d) || return 1
  got=$(
    R7_BELLS_DIR=$T R7_STATE_DIR=$T/state R7_BELL_DRY=1; PSI_MEM_N=0; HAVE_BASE=0; PREV_SVC_TS=""; PREV_OOM=()
    P1=$'OOM wm-build.service 0\nKOOM 0\nPSIMEM 55.0\nPSIIO 1\nDFI 5\nDFH 50\nSVC active 100\nEND'
    P2=$'OOM wm-build.service 1\nKOOM 0\nPSIMEM 55.0\nPSIIO 1\nDFI 5\nDFH 50\nSVC active 100\nEND'
    P3=$'OOM wm-build.service 1\nKOOM 0\nPSIMEM 55.0\nPSIIO 1\nDFI 95\nDFH 50\nSVC active 200\nEND'
    evaluate <<<"$P1"; evaluate <<<"$P2"; evaluate <<<"$P3"; evaluate <<<"$P3")
  # P1 baseline silent; P2: oom-kill (1); P3: psi-mem (3rd sample) + df-inode + daemon-restart (3); P3 again: psi/df edge already fired -> 0 => 4 bells
  n=$(printf '%s\n' "$got" | grep -c '^R7-BELL ')
  rm -rf "$T"
  [ "$n" = 4 ] || { echo "SELFTEST FAIL $SCRIPT logic gave $n bells (want 4: oom-kill, psi-mem, df-inode, daemon-restart): $(printf '%s' "$got" | cut -c1-300 | tr '\n' '|')"; return 1; }
  r7_selftest_event_err $NAME || return 1
  echo "SELFTEST PASS $SCRIPT probe keys complete, journalctl -k readable, wm-build.service memory.events exists, tailscale IP resolves, logic 4 bells (oom-kill psi-mem df-inode daemon-restart); stub seat-event rc=64 -> 1 EVENT-ERR line, EVENT_SOURCE=r7-mon-$NAME"
}

freeze_check() {   # ssh down for FREEZE_N consecutive 30 s probes AND the tailscale IP does not answer -> one edge bell (never SSH-FAIL -> seat-event)
  [ "$SSH_FAILS" -ge "$FREEZE_N" ] || return 0
  if ts_probe; then echo "SSH-FAIL-STREAK $(r7_ts) n=$SSH_FAILS tailscale ping OK (ssh-only problem, no FREEZE bell)"
  else r7_level "$NAME" - freeze-suspect 1 21600 "FREEZE? ssh down ${SSH_FAILS}x30s, tailscale ping failed"; fi
}

r7_wp_arm r7-mon-host "$R7_PREMISE_TEXT" "ssh $R7_SSH_OPTS $R7_HOST 'test -r /proc/pressure/memory'"
if [ "${1:-}" = --selftest ]; then selftest; rc=$?; r7_wp_line || rc=1; exit $rc; fi
R7_HB_NAME=$NAME; export R7_HB_NAME
r7_hb "$NAME"
r7_hb_ticker "$NAME"
trap 'kill $R7_TICKER_PID 2>/dev/null' EXIT
until line=$(selftest); do
  echo "$line"
  if ssh $R7_SSH_OPTS "$R7_HOST" true >/dev/null 2>&1; then SSH_FAILS=0; else SSH_FAILS=$((SSH_FAILS+1)); freeze_check; fi
  r7_ssh_fail "$(printf '%s' "$line" | sed -n 's/.* rc=\([0-9]*\).*/\1/p')" "$NAME"
done
echo "$line"
r7_wp_line
while true; do
  r7_hb "$NAME"
  if r7_gate >/dev/null 2>&1; then :; else R7_BELL_DRY=1; echo "WP-DISARMED r7-mon-host $(r7_ts) premise gone or expired; seat-event.sh calls off"; fi
  out=$(run_probe); rc=$?
  if printf '%s\n' "$out" | tail -n1 | grep -qx END; then
    [ "$SSH_FAILS" -ge "$FREEZE_N" ] && echo "SSH-RECOVERED $(r7_ts) after ${SSH_FAILS} failures"
    SSH_FAILS=0; r7_level "$NAME" - freeze-suspect 0 21600
    evaluate <<<"$out"
  elif [ "$rc" = 255 ]; then
    SSH_FAILS=$((SSH_FAILS+1)); freeze_check
    r7_ssh_fail "$rc" "$NAME"; continue
  else
    echo "PROBE-FAIL $(r7_ts) rc=$rc $(printf '%s' "$out" | tail -n1 | cut -c1-120)"
  fi
  sleep "$R7_LOOP_S"
done
