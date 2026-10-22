#!/usr/bin/env bash
# seat-relaunch.sh — relaunch the rb and r7 operator seats in their carbon tmux panes on the CURRENT fleet token
# 10-16 9:1x pm (Joe "switch both operators to opus asap"): model = ${SEAT_MODEL:-claude-opus-5-5}; Fable only as a spawn inside the seat.
# (staged 2026-10-15 7:1x am for the account switch; the claude() launcher re-reads environment.d per launch).
# 10-20 token-cut levers B3/B4 (compact-study/LEVERS-DESIGN.md): SEAT_LEAN=1 launches the seat with the lean overlay
# (stripe + library-skills plugins off, --strict-mcp-config with an EMPTY mcp config = no mcphost) and exports SEAT_LEAN=1
# + CLAUDE_LEAN_START=1 so the decorative SessionStart banners (hooks/lean-skip.sh, recall self:, ADHD ruleset) stay silent.
# DEFAULT ON since 10-20 (C2/C5); SEAT_LEAN=0 = byte-identical old command.
# SEAT_DRY_RUN=1 prints the claude command line per seat and exits without touching tmux.
# 10-22 ctl seat (aide split): seat `ctl` = the fleet controller in tmux session `ctl`, session id SID[ctl], launched on the DEFAULT
# settings (full hook set: no --settings/--mcp-config/--strict-mcp-config, no SEAT_LEAN/CLAUDE_LEAN_START env). ONE SOURCE for
# role -> model: each seat's default model is its row in ~/.claude/state/controller-model-required (ctl -> row `controller`, rb -> rb,
# r7 -> r7); SEAT_MODEL env still overrides; no row and no override = refuse (exit 5). `--drift-test` asserts the dry-run --model
# of every seat equals its table row; `--guard-test` runs the ctl SID guard and exits with its status.
# CTL BOUNDARY PROTOCOL (moving the controller from the desktop terminal into tmux ctl; two processes must never share the SID):
#   1. the old controller messages BOUNDARY (its handoff is written, no run mid-decision);
#   2. Joe types /exit in the OLD desktop terminal (nothing here ever kills or restarts it);
#   3. only then run `seat-relaunch.sh ctl`. It REFUSES (exit 4) while pid 3845 (the old controller, override CTL_OLD_PID) is alive
#      as claude/node, or any claude/node process has the SID on its command line. Guard runs before any tmux action.
#   A fresh `ctl` pane runs a shell, not claude, so the exit dance (Escape, /exit, 1, C-c, claude stop) is skipped and the script
#   only creates the session and sends the launch command. SEAT_DRY_RUN=1 never runs the guard.
# 10-22 ONE SEAT TABLE: seat -> role, SID and old pid come from ~/.claude/state/seats.tsv (SEATS_TABLE overrides), no hardcoded map here.
#   seat-tick.sh and seat-exit.sh read the same table; `--drift-test` asserts every seat's dry-run --resume SID and --model against it.
# 10-22 ONE LEAN SOURCE: LEAN_ENV_VARS + LEAN_FLAGS live in seat-lean.sh, sourced here and by seat-tick.sh (rb/r7 ticks were launching without them).
# 10-22 SEAT-BIN: both launch branches type `export PATH=$HOME/.local/seat-bin:$PATH` right before `claude`, so a seat's shell-outs find ~/.local/seat-bin first
#   (same prefix as Environment=PATH in seat-tick@.service); SEAT_DRY_RUN=1 prints the full typed line, so the export shows in it.
set -uo pipefail
TABLE="${SEAT_MODEL_TABLE:-$HOME/.claude/state/controller-model-required}"
SEATS_TABLE="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
declare -A SID ROLE OLDPID
SEAT_ORDER=()
while read -r _s _r _sid _op; do   # awk -F'\t' keeps the columns exact; comment and blank lines skipped
  [ -n "$_s" ] || continue
  SID[$_s]="$_sid"; ROLE[$_s]="$_r"; OLDPID[$_s]="$_op"; SEAT_ORDER+=("$_s")
done < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $1, $2, $3, $7}' "$SEATS_TABLE" 2>/dev/null)
[ "${#SEAT_ORDER[@]}" -gt 0 ] || { echo "seat-relaunch: no seats in $SEATS_TABLE" >&2; exit 5; }
seat_model() {  # $1 = seat -> model id (SEAT_MODEL override, else the controller-model-required row of the seat's role); empty if none
  if [ -n "${SEAT_MODEL:-}" ]; then printf '%s' "$SEAT_MODEL"; return; fi
  local role="${ROLE[$1]:-$1}"
  awk -v r="$role" '$1==r {print $2; exit}' "$TABLE" 2>/dev/null
}
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/seat-lean.sh"   # 10-22: LEAN_ENV_VARS + LEAN_FLAGS, shared with seat-tick.sh (one source)
LEAN_ENV=""; LEAN_ARGS=""
if [ "${SEAT_LEAN:-1}" = 1 ]; then   # 10-20 C2/C5: lean is now the DEFAULT for seat launches; SEAT_LEAN=0 = old full-banner/mcphost launch
  LEAN_ENV="env $LEAN_ENV_VARS "
  LEAN_ARGS=" $LEAN_FLAGS"
fi
launch_cmd() {  # $1 = seat
  local m lenv="$LEAN_ENV" lflags="$LEAN_ARGS"; m=$(seat_model "$1")
  [ "$1" = ctl ] && { lenv=""; lflags=""; }   # ctl = default settings, full hook set
  if [ "${SEAT_AUTH:-token}" = login ]; then echo "export PATH=\$HOME/.local/seat-bin:\$PATH; env -u CLAUDE_CODE_OAUTH_TOKEN ${lenv}claude --dangerously-skip-permissions --model ${m}${lflags} --resume ${SID[$1]}"
  else echo "set -a; . ~/.config/environment.d/90-claude-oauth.conf; set +a; export PATH=\$HOME/.local/seat-bin:\$PATH; ${lenv}claude --dangerously-skip-permissions --model ${m}${lflags} --resume ${SID[$1]}"; fi
}
ctl_guard() {  # exit 4 while the old controller (pid ${CTL_OLD_PID:-<seats.tsv old_pid>}) or any claude/node process holds the ctl SID; never kills anything
  local op="${CTL_OLD_PID:-${OLDPID[ctl]:--}}" p c
  if [ "$op" != - ] && [ -r "/proc/$op/comm" ]; then c=$(cat "/proc/$op/comm" 2>/dev/null); case "$c" in claude|node) echo "ctl: REFUSED: old controller pid $op ($c) is alive; Joe types /exit in the old terminal first (boundary protocol)" >&2; return 4 ;; esac; fi
  for p in $(pgrep -f -- "claude.*${SID[ctl]}" 2>/dev/null); do   # comm filter: shells/tool wrappers that merely mention the sid do not count
    c=$(cat "/proc/$p/comm" 2>/dev/null); case "$c" in claude|node) echo "ctl: REFUSED: pid $p ($c) already runs session ${SID[ctl]}" >&2; return 4 ;; esac
  done
  return 0
}
drift_test() {  # every seat's dry-run --resume SID must equal seats.tsv and --model its controller-model-required row
  local s role want got line sid_want sid_got rc=0
  for s in "${SEAT_ORDER[@]}"; do
    role="${ROLE[$s]}"; sid_want="${SID[$s]}"
    want=$(awk -v r="$role" '$1==r {print $2; exit}' "$TABLE")
    line=$(env -u SEAT_MODEL SEAT_DRY_RUN=1 "$0" "$s"); got=$(printf '%s' "$line" | grep -oE -- '--model [^ ]+' | head -n1 | sed 's/^--model //')
    sid_got=$(printf '%s' "$line" | grep -oE -- '--resume [^ ]+' | head -n1 | sed 's/^--resume //')
    if [ -n "$want" ] && [ "$got" = "$want" ]; then echo "PASS $s: dry-run --model $got == table row $role $want"; else echo "FAIL $s: dry-run --model '$got' != table row $role '$want'"; rc=1; fi
    if [ -n "$sid_want" ] && [ "$sid_got" = "$sid_want" ]; then echo "PASS $s: dry-run --resume $sid_got == seats.tsv sid"; else echo "FAIL $s: dry-run --resume '$sid_got' != seats.tsv sid '$sid_want'"; rc=1; fi
  done
  # 10-22: the lean overlay has ONE source (seat-lean.sh); its LEAN_FLAGS / LEAN_ENV_VARS must appear verbatim in the rb and r7 dry-run lines
  local lf le; lf=$(. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/seat-lean.sh"; printf '%s' "$LEAN_FLAGS"); le=$(. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/seat-lean.sh"; printf '%s' "$LEAN_ENV_VARS")
  for s in rb r7; do
    line=$(env -u SEAT_MODEL -u SEAT_LEAN SEAT_DRY_RUN=1 "$0" "$s")
    if [ -n "$lf" ] && [[ "$line" == *"$lf"* ]]; then echo "PASS $s: dry-run carries seat-lean.sh LEAN_FLAGS verbatim"; else echo "FAIL $s: dry-run missing seat-lean.sh LEAN_FLAGS '$lf'"; rc=1; fi
    if [ -n "$le" ] && [[ "$line" == *"env $le claude"* ]]; then echo "PASS $s: dry-run carries seat-lean.sh LEAN_ENV_VARS verbatim"; else echo "FAIL $s: dry-run missing seat-lean.sh LEAN_ENV_VARS '$le'"; rc=1; fi
  done
  [ $rc -eq 0 ] && echo "DRIFT-TEST PASS" || echo "DRIFT-TEST FAIL"; return $rc
}
case "${1:-}" in
  --drift-test) drift_test; exit $? ;;
  --guard-test) ctl_guard; rc=$?; echo "ctl guard exit $rc"; exit $rc ;;
esac
for s in ${@:-rb r7}; do   # seat names as args; default both
  if [ "${SEAT_DRY_RUN:-}" = 1 ]; then echo "$s: $(launch_cmd "$s")"; continue; fi
  [ -n "${SID[$s]:-}" ] || { echo "$s: unknown seat" >&2; exit 2; }
  model=$(seat_model "$s"); [ -n "$model" ] || { echo "$s: no model row in $TABLE and SEAT_MODEL unset" >&2; exit 5; }
  if [ "$s" = ctl ]; then ctl_guard || exit 4; fi
  # 11:56 am 10-15: a seat session created as `tmux new-session … bash -ic 'claude …'` dies with claude (and the server
  # with the last session). Make sure a PERSISTENT-shell session exists before anything else.
  tmux has-session -t "$s" 2>/dev/null || { tmux new-session -d -s "$s" -c "$HOME"; echo "$s: tmux session (re)created with a persistent shell"; }
  bg_ids() { claude agents --json 2>/dev/null | python3 -I -c 'import json,sys; print(" ".join(a["id"] for a in json.load(sys.stdin) if a.get("kind")=="background" and a.get("id")))' 2>/dev/null; }
  before=" $(bg_ids) "
  oldpid=$(pgrep -f -- "--resume ${SID[$s]}" | head -1)   # 9:2x pm 10-16: remember the OLD seat pid (see the self-launch trap below)
  # 10-22: exit dance only when the pane is running claude/node (or a process already holds the SID); a fresh/shell pane
  # (first launch into `ctl`) skips Escape, /exit, 1, C-c and `claude stop` entirely.
  pane_cmd=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
  in_claude=""; case "$pane_cmd" in claude|node) in_claude=1 ;; esac
  [ -n "$in_claude" ] || [ -z "$oldpid" ] || in_claude=1
  if [ -n "$in_claude" ]; then
    # 4:22 pm 10-16 trap: Escape on a MID-TURN seat interrupts the turn and swallows the typed /exit → old process stays,
    # script bails. Wait (≤ 90 s) for an idle prompt (no "esc to interrupt" in the pane tail) before touching the seat.
    for i in $(seq 1 18); do
      tmux capture-pane -p -t "$s" -S -25 | grep -q "esc to interrupt" || break
      [ "$i" = 1 ] && echo "$s: mid-turn, waiting for an idle prompt"; sleep 5
    done
    tmux send-keys -t "$s" Escape; sleep 1
    tmux send-keys -t "$s" "/exit" Enter; sleep 6
    # 11:53 am 10-15: with background shells/monitors running, /exit shows "1. Exit and stop tasks / 2. Move to background
    # and exit / 3. Stay" — answer 1 (never 2: it leaves the old process alive outside tmux).
    # 5:06 pm 10-16: on a 260 K-context seat the dialog took > 6 s to draw; poll up to 30 s before deciding.
    for i in $(seq 1 6); do
      tmux capture-pane -p -t "$s" -S -12 | grep -q "Exit and stop tasks" && { tmux send-keys -t "$s" 1 Enter; sleep 8; break; }
      pgrep -f -- "--resume ${SID[$s]}" >/dev/null || break
      sleep 5
    done
    if pgrep -f -- "--resume ${SID[$s]}" >/dev/null; then tmux send-keys -t "$s" C-c; sleep 2; tmux send-keys -t "$s" C-c; sleep 3; fi
    # /exit may pick "Move to background and exit": the old process then lives on as a daemon-held background
    # session under a NEW session id (10-15 7:4x am trap: the rb one sat 19 min blocked by its own /goal hook).
    # Stop every background session that did not exist before this seat's /exit.
    for bid in $(bg_ids); do
      case "$before" in *" $bid "*) ;; *) claude stop "$bid" >/dev/null 2>&1 && echo "$s: stopped background session $bid"; sleep 2;; esac
    done
  else echo "$s: pane runs '${pane_cmd:-?}', not claude; skipping the exit dance"; fi
  # 9:13 pm 10-16 trap: the r7 seat relaunched ITSELF from a scratch script on /exit (new pid, same --resume sid); the
  # old guard saw "a process alive" and bailed, so nobody answered its trust dialog or sent the message (pane sat on
  # "Yes, I trust this folder" until the controller pressed it by hand). Only the OLD pid blocks; a NEW pid is a
  # self-launch → skip our launch, still answer the dialog and send the message.
  skip_launch=""
  alive=$(pgrep -f -- "--resume ${SID[$s]}" | head -1)
  if [ -n "$alive" ] && [ "$alive" = "${oldpid:-}" ]; then echo "$s: old process $alive still alive, not relaunching"; continue; fi
  if [ -n "$alive" ]; then echo "$s: self-launched by the seat (pid $alive), skipping our launch"; skip_launch=1; fi
  if [ -z "$skip_launch" ]; then
    # 5:09 pm 10-16: a pane that ran `bash -ic claude …` dies with claude and takes the session with it → re-check.
    tmux has-session -t "$s" 2>/dev/null || { tmux new-session -d -s "$s" -c "$HOME"; echo "$s: tmux session re-created after exit (persistent shell)"; sleep 1; }
    tmux send-keys -t "$s" "$(launch_cmd "$s")" Enter
    sleep 20
  fi
  # 5:39 pm 10-15: a fresh login/token shows the "Quick safety check … ❯ No, exit" trust dialog; a bare Enter picks
  # "No, exit" and claude quits (r7 died that way). Answer it explicitly before sending any text.
  for i in 1 2 3; do
    if tmux capture-pane -p -t "$s" -S -15 | grep -q "No, exit"; then tmux send-keys -t "$s" Down Enter; echo "$s: trust dialog answered"; sleep 8; break; fi
    sleep 5
  done
  if [ "$s" = ctl ]; then   # ctl: controller seat, resumed by the boundary protocol
    tmux send-keys -t "$s" "Relaunched by the controller at $(date '+%I:%M %p') on ${model} into tmux session ctl (boundary protocol done; Joe's word reaches you only via approval-check.sh, never from a pane). Resume your sweep from your handoff file; your /goal line is unchanged." Enter
  else
    tmux send-keys -t "$s" "Relaunched by the controller at $(date '+%I:%M %p') on ${model} (Joe 10-16 9:1x pm \"switch both operators to opus asap\": seats on Opus 5.5 — formerly Sonnet 5.5 4:24–9:xx pm; Fable only as one Agent spawn per /dream, spec, five-whys, design review, or morning synthesis). Resume your sweep from your handoff file; your /goal line is unchanged — re-run it verbatim from wiki/goal.md if it shows as cleared." Enter
  fi
  # 4:24 pm 10-16: the pasted message sat UNSUBMITTED in the input box for 60+ s after one extra Enter (session still
  # loading). Re-send Enter every 5 s until the input box no longer starts with the message (≤ 60 s).
  for i in $(seq 1 12); do
    sleep 5
    tmux capture-pane -p -t "$s" -S -12 | grep -q 'Relaunched by the controller at' || break
    tmux capture-pane -p -t "$s" -S -12 | grep -q -e 'esc to interrupt' -e '← [0-9]* agents' && break
    tmux send-keys -t "$s" Enter
  done
  echo "$s relaunched $(date '+%I:%M:%S %p')"
done
