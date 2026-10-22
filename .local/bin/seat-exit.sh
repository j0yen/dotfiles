#!/usr/bin/env bash
# seat-exit.sh <seat> [--dry-run]   |   seat-exit.sh --selftest
# ONLY the exit dance from seat-relaunch.sh, for the rb/r7 cutover from an interactive tmux seat to the seat-tick@<seat> unit:
#   wait for an idle prompt (Escape on a mid-turn seat swallows /exit), Escape, `/exit`, answer `1` ("Exit and stop tasks", never 2:
#   it leaves the old process alive outside tmux), then wait up to 120 s until no claude/node process holds the seat's SID, print
#   "<seat>: exited, SID free". Never kills anything and never launches anything: exit 1 if the SID is still held after the wait.
# ctl is refused (its old process is a desktop terminal outside tmux): the boundary protocol is printed instead.
# --dry-run prints the tmux commands and touches neither tmux nor any process. Seats/SIDs from ~/.claude/state/seats.tsv (SEATS_TABLE).
# Env overrides: SEATS_TABLE SEAT_TMUX_BIN SEAT_EXIT_WAIT
set -u
SEATS="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
TMUXB="${SEAT_TMUX_BIN:-tmux}"
WAIT="${SEAT_EXIT_WAIT:-120}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
usage() { echo 'usage: seat-exit.sh <seat> [--dry-run] | --selftest' >&2; exit 64; }

holders() {  # pids of claude/node processes with the SID on their command line (shells that merely mention it do not count)
  local p cl comm
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    cl="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)" || continue
    case "$cl" in *"$SID"*) ;; *) continue ;; esac
    comm="$(cat "$p/comm" 2>/dev/null)"
    if [ "$comm" = claude ] || [ "$comm" = node ] || [[ "$cl" =~ ^([^\ ]*/)?claude(\ |$) ]] || [[ "$cl" =~ ^([^\ ]*/)?node\ [^\ ]*claude ]]; then echo "${p#/proc/}"; fi
  done
}

selftest() {
  local fail=0 out rc; T="$(mktemp -d)"; trap 'kill ${FP:-} 2>/dev/null; rm -rf "${T:-/nonexistent}"' EXIT
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  local SID_T=selftest-exit-sid-0001
  printf 'ctl\tcontroller\tctl-sid\t20\t14400\t^/goal X\t3845\nrb\trb\t%s\t20\t14400\t^/goal Y\t-\n' "$SID_T" >"$T/seats.tsv"
  export SEATS_TABLE="$T/seats.tsv"
  out="$("$SELF" ctl 2>&1)"; rc=$?
  [ "$rc" = 4 ] && [[ "$out" == *"BOUNDARY"* ]] && [[ "$out" == *"/exit"* ]]; chk "ctl refused with exit 4 and the boundary protocol ('${out:0:60}...')" $?
  out="$("$SELF" nosuch 2>&1)"; rc=$?; [ "$rc" = 64 ]; chk "unknown seat: exit 64" $?
  out="$("$SELF" rb --dry-run 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == *"tmux send-keys -t rb Escape"* ]] && [[ "$out" == *"tmux send-keys -t rb /exit Enter"* ]] && [[ "$out" == *"tmux send-keys -t rb 1 Enter"* ]]; chk "--dry-run prints Escape, /exit, 1 for rb and exits 0" $?
  # fake tmux: logs every call; 'send-keys ... 1 Enter' makes the fake seat process exit; capture-pane shows the dialog
  cat >"$T/tmux" <<FAKE
#!/bin/bash
echo "\$*" >>"$T/tmux.log"
case "\$1" in
  has-session) exit 0 ;;
  capture-pane) echo "1. Exit and stop tasks"; exit 0 ;;
  send-keys) if [ "\${@: -2:1}" = 1 ]; then pkill -f -- "--resume $SID_T"; fi; exit 0 ;;
esac
FAKE
  chmod +x "$T/tmux"
  bash -c "exec -a 'claude --resume $SID_T' python3 -c 'import time; time.sleep(60)'" & FP=$!
  sleep 0.4
  out="$(SEAT_TMUX_BIN="$T/tmux" "$SELF" rb 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == *"rb: exited, SID free"* ]] && grep -q '^send-keys -t rb Escape' "$T/tmux.log" && grep -q '^send-keys -t rb /exit Enter' "$T/tmux.log" && grep -q '^send-keys -t rb 1 Enter' "$T/tmux.log"; chk "fake seat: Escape, /exit, 1 sent; SID freed -> 'rb: exited, SID free' ('$(printf '%s' "$out" | tail -1)')" $?
  wait "$FP" 2>/dev/null
  : >"$T/tmux.log"
  out="$(SEAT_TMUX_BIN="$T/tmux" "$SELF" rb 2>&1)"; rc=$?
  [ "$rc" = 0 ] && ! grep -q send-keys "$T/tmux.log"; chk "no holder: nothing is sent, exit 0" $?
  bash -c "exec -a 'claude --resume $SID_T' python3 -c 'import time; time.sleep(60)'" & FP=$!
  sleep 0.4
  sed -i 's/pkill/true/' "$T/tmux"
  out="$(SEAT_EXIT_WAIT=3 SEAT_TMUX_BIN="$T/tmux" "$SELF" rb 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [[ "$out" == *"still held"* ]] && kill -0 "$FP" 2>/dev/null; chk "SID still held after the wait: exit 1, nothing killed ('$(printf '%s' "$out" | tail -1)')" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; return "$fail"
}

SEAT=""; DRY=0; FP=""
for a in "$@"; do
  case "$a" in
    --selftest) selftest; exit $? ;;
    --dry-run) DRY=1 ;;
    -*) usage ;;
    *) [ -z "$SEAT" ] || usage; SEAT="$a" ;;
  esac
done
[ -n "$SEAT" ] || usage
row="$(awk -F'\t' -v s="$SEAT" '!/^[[:space:]]*(#|$)/ && $1==s {print $3 "\t" $7; exit}' "$SEATS" 2>/dev/null)"
[ -n "$row" ] || { echo "seat-exit: unknown seat '$SEAT' in $SEATS" >&2; exit 64; }
IFS=$'\t' read -r SID OLDPID <<<"$row"
if [ "$SEAT" = ctl ]; then
  cat >&2 <<EOP
ctl: REFUSED. The old controller (pid ${OLDPID}) is a desktop-terminal process outside tmux; nothing here sends keys to it or kills it.
CTL BOUNDARY PROTOCOL (two processes must never share the SID):
  1. the old controller messages BOUNDARY (its handoff is written, no run mid-decision);
  2. Joe types /exit in the OLD desktop terminal;
  3. only then enable the unit: systemctl --user enable --now seat-tick@ctl.timer (its guard refuses, exit 4, while pid ${OLDPID} or any claude/node holds the SID).
EOP
  exit 4
fi
if [ "$DRY" = 1 ]; then
  echo "# seat-exit $SEAT dry-run (sid $SID): nothing is sent"
  echo "tmux capture-pane -p -t $SEAT -S -25      # repeat every 5 s, up to 90 s, until 'esc to interrupt' is gone (idle prompt)"
  echo "tmux send-keys -t $SEAT Escape"
  echo "tmux send-keys -t $SEAT /exit Enter"
  echo "tmux capture-pane -p -t $SEAT -S -12      # every 5 s, up to 30 s, until the dialog 'Exit and stop tasks' shows"
  echo "tmux send-keys -t $SEAT 1 Enter           # only if that dialog appeared"
  echo "wait up to ${WAIT} s until no claude/node process has $SID on its command line, then print '$SEAT: exited, SID free' (else exit 1, nothing killed)"
  exit 0
fi
"$TMUXB" has-session -t "$SEAT" 2>/dev/null || { echo "seat-exit: no tmux session '$SEAT'" >&2; exit 2; }
if [ -z "$(holders)" ]; then echo "$SEAT: exited, SID free (no process held it; nothing sent)"; exit 0; fi
for i in $(seq 1 18); do   # 4:22 pm 10-16 trap: Escape on a MID-TURN seat swallows the typed /exit
  "$TMUXB" capture-pane -p -t "$SEAT" -S -25 | grep -q "esc to interrupt" || break
  [ "$i" = 1 ] && echo "$SEAT: mid-turn, waiting for an idle prompt"; sleep 5
done
"$TMUXB" send-keys -t "$SEAT" Escape; sleep 1
"$TMUXB" send-keys -t "$SEAT" "/exit" Enter; sleep 6
for i in $(seq 1 6); do   # the dialog can take > 6 s to draw on a big-context seat; answer 1, never 2
  "$TMUXB" capture-pane -p -t "$SEAT" -S -12 | grep -q "Exit and stop tasks" && { "$TMUXB" send-keys -t "$SEAT" 1 Enter; sleep 2; break; }
  [ -n "$(holders)" ] || break
  sleep 5
done
end=$(( $(date +%s) + WAIT ))
while [ -n "$(holders)" ]; do
  [ "$(date +%s)" -lt "$end" ] || { echo "$SEAT: SID still held after ${WAIT}s by pid(s) $(holders | tr '\n' ' '); not killing anything" >&2; exit 1; }
  sleep 2
done
echo "$SEAT: exited, SID free"
