#!/usr/bin/env bash
# seat-exit.sh <seat> [--dry-run]   |   seat-exit.sh --selftest
# ONLY the exit dance from seat-relaunch.sh, for the rb/r7 cutover from an interactive tmux seat to the seat-tick@<seat> unit.
#   A pane state machine (capture every SEAT_EXIT_POLL s, max SEAT_EXIT_DANCE_MAX s) acts on the first matching state:
#   bug-report modal -> 0 | unsent-draft prompt -> Escape | Feedback drafts list -> Escape | exit dialog -> 1 Enter (never 2: it leaves
#   the old process alive outside tmux) | `❯ /exit` lingering -> Enter | mid-turn -> wait (Escape once after 90 s) | idle prompt with
#   stray input -> C-u /exit Enter | idle empty prompt -> /exit Enter. Then wait up to 120 s until no claude/node process holds the
#   seat's SID, print "<seat>: exited, SID free". Never kills anything and never launches anything: exit 1 if the SID is still held.
# ctl is refused (its old process is a desktop terminal outside tmux): the boundary protocol is printed instead.
# --dry-run prints the tmux commands and touches neither tmux nor any process. Seats/SIDs from ~/.claude/state/seats.tsv (SEATS_TABLE).
# Env overrides: SEATS_TABLE SEAT_TMUX_BIN SEAT_EXIT_WAIT SEAT_EXIT_POLL SEAT_EXIT_KEYGAP SEAT_EXIT_MIDTURN SEAT_EXIT_DANCE_MAX
set -u
SEATS="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
TMUXB="${SEAT_TMUX_BIN:-tmux}"
WAIT="${SEAT_EXIT_WAIT:-120}"
POLL="${SEAT_EXIT_POLL:-3}"          # seconds between pane captures (also the "still shows ❯ /exit after 3 s" check)
GAP="${SEAT_EXIT_KEYGAP:-1}"         # seconds between a typed text and its Enter
MIDTURN="${SEAT_EXIT_MIDTURN:-90}"   # seconds to wait out a mid-turn seat before one Escape
DANCE="${SEAT_EXIT_DANCE_MAX:-150}"  # cap on the state machine
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

pane() { "$TMUXB" capture-pane -p -t "$SEAT" -S -25 2>/dev/null | sed 's/\xc2\xa0/ /g'; }   # NBSP after the ❯ prompt -> plain space
sendk() { "$TMUXB" send-keys -t "$SEAT" "$@"; }
note() { echo "seat-exit: $SEAT state=$1 → $2" >&2; }
has() { grep -qF -e "$1" <<<"$PANE"; }
prompt_input() {  # text typed after the LAST ❯ line of $PANE (box bars stripped); prints "P:<text>", nothing when no ❯ line
  awk '/❯/ { l=$0; sub(/^.*❯/, "", l); gsub(/│/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); r="P:" l } END { if (r != "") print r }' <<<"$PANE"
}

# The exit dance. Returns 0 when it is done acting (dialog answered, process gone, or time cap); the caller then waits for the SID.
dance() {
  local start now st last="" mid0="" esc_done=0 pi
  start=$(date +%s)
  while :; do
    [ -n "$(holders)" ] || return 0
    now=$(date +%s)
    [ $((now - start)) -lt "$DANCE" ] || { echo "seat-exit: $SEAT dance hit the ${DANCE}s cap" >&2; return 0; }
    PANE="$(pane)"
    if has '0 to dismiss'; then st=modal-dismiss; note $st 0; sendk 0
    elif has 'Esc to discard and exit'; then st=draft-discard; note $st Escape; sendk Escape
    elif has 'Feedback drafts' && has 'Esc to close'; then st=drafts-list; note $st Escape; sendk Escape
    elif has 'Exit and stop tasks'; then   # option 1 is pre-selected; never 2
      note exit-dialog "1 Enter"; sendk 1; sleep "$GAP"; sendk Enter; sleep 2; return 0
    elif grep -qE '❯ /exit( |│)*$' <<<"$PANE"; then st=exit-lingering; note $st Enter; sendk Enter
    elif has 'esc to interrupt'; then   # 4:22 pm 10-16 trap: Escape on a MID-TURN seat swallows the typed /exit
      st=mid-turn; [ -n "$mid0" ] || mid0=$now
      if [ $((now - mid0)) -ge "$MIDTURN" ] && [ "$esc_done" = 0 ]; then esc_done=1; note $st Escape; sendk Escape
      elif [ "$st" != "$last" ]; then note $st wait; fi
    else
      pi="$(prompt_input)"
      if [ -z "$pi" ]; then st=unknown; [ "$st" = "$last" ] || note $st wait
      elif [ "$pi" != "P:" ]; then st=idle-stray-input; note $st "C-u /exit Enter"; sendk C-u; sleep "$GAP"; sendk "/exit"; sleep "$GAP"; sendk Enter
      else st=idle; note $st "/exit Enter"; sendk "/exit"; sleep "$GAP"; sendk Enter
      fi
    fi
    last=$st; sleep "$POLL"
  done
}

selftest() {
  local fail=0 out rc alive; T="$(mktemp -d)"; export FT="$T"; trap 'kill ${FP:-} 2>/dev/null; rm -rf "${T:-/nonexistent}"' EXIT
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  local SID_T=selftest-exit-sid-0001
  printf 'ctl\tcontroller\tctl-sid\t20\t14400\t^/goal X\t3845\nrb\trb\t%s\t20\t14400\t^/goal Y\t-\n' "$SID_T" >"$T/seats.tsv"
  export SEATS_TABLE="$T/seats.tsv"
  out="$("$SELF" ctl 2>&1)"; rc=$?
  [ "$rc" = 4 ] && [[ "$out" == *"BOUNDARY"* ]] && [[ "$out" == *"/exit"* ]] && _r=0 || _r=1; chk "ctl refused with exit 4 and the boundary protocol ('${out:0:60}...')" "$_r"
  out="$("$SELF" nosuch 2>&1)"; rc=$?; [ "$rc" = 64 ] && _r=0 || _r=1; chk "unknown seat: exit 64" "$_r"
  out="$("$SELF" rb --dry-run 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _r=0 || _r=1; chk "--dry-run exits 0" "$_r"
  for s in "send-keys -t rb 0" "send-keys -t rb Escape" "send-keys -t rb C-u" "send-keys -t rb /exit" "send-keys -t rb 1" "send-keys -t rb Enter"; do
    [[ "$out" == *"tmux $s"* ]] && _r=0 || _r=1; chk "--dry-run lists 'tmux $s'" "$_r"
  done
  # fake tmux: capture-pane replays $FT/panes (snapshots split by a line '----'), one per call, repeating the last; send-keys is logged
  # one call per line in $FT/keys; an Enter right after a '1' frees the fake seat process unless $FT/nokill exists
  cat >"$T/tmux" <<'FAKE'
#!/bin/bash
case "$1" in
  has-session) exit 0 ;;
  capture-pane)
    n=$(cat "$FT/idx"); echo $((n + 1)) >"$FT/idx"
    awk -v n="$n" 'BEGIN { k = 0; last = 0 } /^----$/ { k++; next } { a[k] = a[k] $0 "\n"; last = k } END { if (n > last) n = last; printf "%s", a[n] }' "$FT/panes"; exit 0 ;;
  send-keys)
    shift 3; echo "$*" >>"$FT/keys"
    if [ "$*" = Enter ] && [ "$(cat "$FT/prev")" = 1 ] && [ ! -e "$FT/nokill" ]; then kill "$(cat "$FT/fp")" 2>/dev/null; fi
    echo "$*" >"$FT/prev"; exit 0 ;;
esac
FAKE
  chmod +x "$T/tmux"
  export SEAT_EXIT_POLL=0.2 SEAT_EXIT_KEYGAP=0.05
  # runcase <name> <expected keys joined by |> <expected rc> [ENV=val ...]   (pane snapshots on stdin)
  runcase() {
    local name="$1" want="$2" wrc="$3" got; shift 3
    cat >"$T/panes"; : >"$T/keys"; echo 0 >"$T/idx"; : >"$T/prev"
    bash -c "exec -a 'claude --resume $SID_T' python3 -c 'import time; time.sleep(60)'" & FP=$!
    echo "$FP" >"$T/fp"; sleep 0.4
    out="$(env "$@" SEAT_TMUX_BIN="$T/tmux" "$SELF" rb 2>"$T/err")"; rc=$?
    kill -0 "$FP" 2>/dev/null && alive=1 || alive=0
    got="$(paste -sd'|' "$T/keys")"
    [ "$rc" = "$wrc" ] && [ "$got" = "$want" ] && _r=0 || _r=1; chk "$name: keys [$got] rc $rc (want [$want] rc $wrc)" "$_r"
    kill "$FP" 2>/dev/null; wait "$FP" 2>/dev/null; FP=""
  }
  local NB=$'\xc2\xa0' IDLE DIALOG
  IDLE=$'────────\n❯ \n────────\n  ? for shortcuts'
  DIALOG=$'Exit Claude Code?\n❯ 1. Exit and stop tasks\n  2. Move to background and exit\n  3. Stay\nEnter to confirm · Esc to cancel'
  runcase "(a) clean idle (NBSP prompt) -> /exit, dialog, 1 Enter" '/exit|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"────────
❯${NB}
────────
----
$DIALOG"
  runcase "(b) modal first -> 0, then idle -> /exit" '0|/exit|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"╭ Bug report drafted: seat stalls ╮
  1 to review · 2 to send · 0 to dismiss
----
$IDLE
----
$DIALOG"
  runcase "(c) stray input -> C-u first" 'C-u|/exit|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"❯ 04:46:42 PM R7-ALARM STALE rb 12m
----
$DIALOG"
  runcase "(d) unsent-draft prompt -> Escape -> dialog" '/exit|Enter|Escape|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"$IDLE
----
You have 1 unsent feedback draft
Enter to review & send · Esc to discard and exit
----
$DIALOG"
  runcase "(e) drafts list open -> Escape -> draft prompt -> Escape -> dialog" 'Escape|Escape|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"Feedback drafts
Enter to review · d to discard · Esc to close
----
You have 1 unsent feedback draft
Enter to review & send · Esc to discard and exit
----
$DIALOG"
  runcase "(f) '❯ /exit' lingering -> extra Enter" '/exit|Enter|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"$IDLE
----
────────
❯ /exit
────────
  /exit  Exit the REPL
----
$DIALOG"
  runcase "(g) mid-turn for 2 captures, then idle" '/exit|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 <<<"✻ Working… (12s · esc to interrupt)
❯ 
----
✻ Working… (14s · esc to interrupt)
❯ 
----
$IDLE
----
$DIALOG"
  grep -q 'state=mid-turn → wait' "$T/err" && _r=0 || _r=1; chk "(g) logged 'state=mid-turn → wait' ('$(grep -m1 'state=mid-turn' "$T/err")')" "$_r"
  runcase "(g2) mid-turn past the limit -> one Escape, then idle" 'Escape|/exit|Enter|1|Enter' 0 SEAT_EXIT_WAIT=3 SEAT_EXIT_MIDTURN=1 <<<"✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
✻ Working… (esc to interrupt)
❯ 
----
$IDLE
----
$DIALOG"
  touch "$T/nokill"
  runcase "(h) SID never freed -> exit 1, nothing killed" '/exit|Enter|1|Enter' 1 SEAT_EXIT_WAIT=3 <<<"$IDLE
----
$DIALOG"
  [[ "$(tail -1 "$T/err")" == *"still held"* ]] && [ "$alive" = 1 ] && _r=0 || _r=1; chk "(h) 'still held' message and the holder survived ('$(tail -1 "$T/err")')" "$_r"
  rm -f "$T/nokill"
  # no holder: nothing is sent
  : >"$T/keys"; echo 0 >"$T/idx"; printf '%s\n' "$IDLE" >"$T/panes"
  out="$(SEAT_TMUX_BIN="$T/tmux" "$SELF" rb 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$T/keys" ] && _r=0 || _r=1; chk "no holder: nothing is sent, exit 0" "$_r"
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
  echo "# state machine: tmux capture-pane -p -t $SEAT -S -25 every ${POLL} s, max ${DANCE} s; the FIRST matching state acts (stderr: 'seat-exit: $SEAT state=<name> → <keys>'):"
  echo "#  1 modal-dismiss    pane has '0 to dismiss' (Bug report drafted modal)        -> tmux send-keys -t $SEAT 0"
  echo "#  2 draft-discard    pane has 'Esc to discard and exit' (unsent feedback draft) -> tmux send-keys -t $SEAT Escape"
  echo "#  3 drafts-list      pane has 'Feedback drafts' + 'Esc to close'               -> tmux send-keys -t $SEAT Escape"
  echo "#  4 exit-dialog      pane has 'Exit and stop tasks'                            -> tmux send-keys -t $SEAT 1   (then, ${GAP} s later)   tmux send-keys -t $SEAT Enter"
  echo "#  5 exit-lingering   input line still '❯ /exit' (autocomplete swallowed Enter)  -> tmux send-keys -t $SEAT Enter"
  echo "#  6 mid-turn         pane has 'esc to interrupt'                               -> wait; after ${MIDTURN} s one: tmux send-keys -t $SEAT Escape"
  echo "#  7 idle-stray-input '❯ ' prompt with text after it                            -> tmux send-keys -t $SEAT C-u ; tmux send-keys -t $SEAT /exit ; (${GAP} s) tmux send-keys -t $SEAT Enter"
  echo "#  8 idle             '❯ ' prompt, empty                                        -> tmux send-keys -t $SEAT /exit ; (${GAP} s) tmux send-keys -t $SEAT Enter"
  echo "tmux capture-pane -p -t $SEAT -S -25"
  echo "tmux send-keys -t $SEAT 0"
  echo "tmux send-keys -t $SEAT Escape"
  echo "tmux send-keys -t $SEAT C-u"
  echo "tmux send-keys -t $SEAT /exit"
  echo "tmux send-keys -t $SEAT Enter"
  echo "tmux send-keys -t $SEAT 1"
  echo "wait up to ${WAIT} s until no claude/node process has $SID on its command line, then print '$SEAT: exited, SID free' (else exit 1, nothing killed)"
  exit 0
fi
"$TMUXB" has-session -t "$SEAT" 2>/dev/null || { echo "seat-exit: no tmux session '$SEAT'" >&2; exit 2; }
if [ -z "$(holders)" ]; then echo "$SEAT: exited, SID free (no process held it; nothing sent)"; exit 0; fi
dance
end=$(( $(date +%s) + WAIT ))
while [ -n "$(holders)" ]; do
  [ "$(date +%s)" -lt "$end" ] || { echo "$SEAT: SID still held after ${WAIT}s by pid(s) $(holders | tr '\n' ' '); not killing anything" >&2; exit 1; }
  sleep 2
done
echo "$SEAT: exited, SID free"
