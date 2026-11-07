#!/usr/bin/env bash
# ctl-silence-recover.sh: deterministic consumer of the executor's silence (recovery plan d-20261107-072411-hermes-666e step 2).
# Reads host facts only (unread inbox bytes, transcript write age, pane command), never the wake lease and never a model.
#   unread work + transcript quiet >= SR_STALE_MIN:
#     pane alive & claude running  -> poke the pane; incident stays OPEN until the cursor advances or the transcript is written after the poke
#     pane gone / shell only       -> hold-gate; allowed -> SR_LAUNCH_CMD (default ctl-launch.sh --resume <sid>); refused or launch rc!=0 -> incident
#                                     blocked (owned, persistent, notify); the queue and cursor are never touched
#   an open incident is re-checked each run: consumed -> closed with outcome; still open past SR_ESC_MIN -> escalate (notify) every SR_ESC_MIN
# Incident = one file $SR_DIR/incident.json created O_EXCL (atomic per incident; replay and duplicate runs see it and do not re-poke early).
# Env (tests inject): SR_DIR SR_EVENTS_DIR SR_TRANSCRIPT SR_PANE SR_TMUX_BIN SR_HOLD_BIN SR_LAUNCH_CMD SR_NOTIFY_BIN SR_NOW SR_STALE_MIN SR_ESC_MIN SR_SID
set -uo pipefail
D="${SR_DIR:-$HOME/.cache/aide/silence}"; EV="${SR_EVENTS_DIR:-$HOME/.cache/fleet-dash}"; AW="${AIDE_WAKE_DIR:-$HOME/.cache/aide}"
TM="${SR_TMUX_BIN:-tmux}"; HG="${SR_HOLD_BIN:-$HOME/.local/bin/hold-gate.sh}"; NT="${SR_NOTIFY_BIN:-$HOME/.local/bin/seat-event.sh}"
STALE=$(( ${SR_STALE_MIN:-30} * 60 )); ESC=$(( ${SR_ESC_MIN:-15} * 60 ))
now() { printf '%s' "${SR_NOW:-$(date +%s)}"; }
num() { [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] && printf '%s' "$1" || printf 0; }
mkdir -p "$D"; T="$(now)"; INC="$D/incident.json"
log() { printf '%s %s\n' "$T" "$*" >> "$D/silence.log"; }
notify() { [ -x "$NT" ] && "$NT" hermes "ctl-silence-recover: $*" >/dev/null 2>&1; log "notify: $*"; }
sid="${SR_SID:-$(head -c 60 "$AW/sid" 2>/dev/null | tr -d '\n')}"
pane="${SR_PANE:-$(head -c 100 "$AW/pane" 2>/dev/null | tr -d '\n')}"
tr_f="${SR_TRANSCRIPT:-$HOME/.claude/projects/-home-jsy/$sid.jsonl}"
log_f="$EV/aide-events.log"; cur_f="$EV/aide-events.cursor"
size=$(num "$(stat -c %s "$log_f" 2>/dev/null)"); off=$(num "$(head -c 20 "$cur_f" 2>/dev/null)"); [ "$off" -gt "$size" ] && off=0
unread=$(( size - off )); tw=$(num "$(stat -c %Y "$tr_f" 2>/dev/null)"); quiet=$(( T - tw ))
wr() { printf '%s\n' "$1" > "$INC.tmp" && mv -f "$INC.tmp" "$INC"; }
field() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$INC" "$1" 2>/dev/null; }
if [ -s "$INC" ]; then   # open incident: consumed?
  base=$(num "$(field base_off)"); poked=$(num "$(field poked_at)"); last=$(num "$(field last_esc)")
  if [ "$off" -gt "$base" ] || { [ "$poked" -gt 0 ] && [ "$tw" -gt "$poked" ]; }; then
    log "incident closed: consumed (cursor $base->$off transcript_write=$tw poked=$poked)"; mv -f "$INC" "$D/closed-$T.json"; echo consumed; exit 0
  fi
  if [ $(( T - last )) -ge "$ESC" ]; then
    st="$(field state)"; notify "incident $st unconsumed $(( (T - $(num "$(field opened)")) / 60 )) min, unread=$unread bytes, owner=hermes next=read $INC"
    wr "$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));d["last_esc"]=int(sys.argv[2]);print(json.dumps(d))' "$INC" "$T")"
  fi
  echo "open:$(field state)"; exit 0
fi
{ [ "$unread" -gt 0 ] && [ "$quiet" -ge "$STALE" ]; } || { echo idle-ok; exit 0; }
alive=no
if [[ "$pane" =~ ^[A-Za-z0-9_.:@%-]+$ ]] && cmd="$("$TM" display-message -p -t "$pane" '#{pane_dead} #{pane_current_command}' 2>/dev/null)"; then
  [[ "$cmd" =~ ^0\ .*(${SR_ALIVE_RE:-claude|node}) ]] && alive=yes
fi
state=""; poked=0
if [ "$alive" = yes ]; then
  "$TM" send-keys -t "$pane" "silence-recover: unread inbox work, work the owed list" Enter 2>/dev/null && { state=poked; poked="$T"; }
  [ -n "$state" ] || state=poke-failed
else
  if "$HG" ctl-recover >"$D/gate.out" 2>&1; then
    lc="${SR_LAUNCH_CMD:-$HOME/.local/bin/ctl-launch.sh --resume $sid}"
    if (set -o pipefail; bash -c "$lc" >"$D/launch.out" 2>&1); then state=relaunched; poked="$T"; else state=launch-failed; fi
  else state=blocked-by-hold; fi
fi
set -o noclobber
if wr_ok=$(printf '{"opened":%s,"state":"%s","base_off":%s,"poked_at":%s,"last_esc":%s,"sid":"%s","pane":"%s","unread":%s}\n' "$T" "$state" "$off" "$poked" "$T" "$sid" "$pane" "$unread" > "$INC" 2>&1); then
  log "incident opened: $state unread=$unread quiet=${quiet}s"
  case "$state" in blocked-by-hold|launch-failed|poke-failed) notify "$state: executor silent $((quiet/60)) min, unread=$unread; owner=hermes next=$(head -c 160 "$D/gate.out" "$D/launch.out" 2>/dev/null | tr '\n' ' ')";; esac
  echo "$state"
else echo duplicate-run; fi
exit 0
