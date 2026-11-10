#!/usr/bin/env bash
# ctl-event-wait.sh: deterministic host-side wait for the carbon executor seat (ctl). Joe-approved routing change
# (fable-routine-routing-20261106.task.md, Hermes 11-06 4:50 PM): a Fable turn runs only on an actionable event; routine
# unchanged status is a structured snapshot file, never a model turn. Replaces the in-session 10-min CronCreate sweep.
#   wait [--max-sec N] [--poll S]  block until ONE event, print one JSON line, exit 0 (event "timeout" when --max-sec passes)
#   status                          print the current snapshot JSON (what `wait` writes every poll) and exit
#   --selftest                      run the fixture tests in a temp HOME (no real log, no notifications)
# Events (each emitted at most once; state in $EW_DIR):
#   inbox     a new aide-events.log line from hermes-*, joe-*, fivewhys-*, rb, r7, controller or plain (own ctl/aide receipts are not events)
#   due       an open-asks.tsv row owned by aide|ctl whose due has passed and was not reported before
#   verifier  a new or updated ~/.local/state/aide-verifier/*/result.json
#   taskfile  a new or changed task file in ~/wintermute-operations/feedback/ (names with status/monitor/receipt are informational)
#   obligation a followup-loop bell carrying a typed `OBLIGATION-KEY id= rev= fp=` field (a suggestion-only obligation; W4), held in $EW/obl.pending until emitted
#   hold      HOLD.json appeared, changed or was removed
#   alarm     a new status.json alarm (text with digits stripped) not seen before
# Liveness lease: every 20 min `aide-wake.sh arm 35`, so a dead waiter lets aide-wake.timer's idle check poke the pane.
# Env: EW_DIR (state, default ~/.cache/aide/event-wait) EVENTS_DIR OPEN_ASKS HOLD_FILE AV_DIR FEEDBACK_DIR STATUS_JSON AIDE_WAKE_BIN EW_NOW (epoch, tests)
set -u
export LC_ALL=C
EW="${EW_DIR:-$HOME/.cache/aide/event-wait}"
EV="${EVENTS_DIR:-$HOME/.cache/fleet-dash}"; LOG="$EV/aide-events.log"
OA="${OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"
HOLD="${HOLD_FILE:-$HOME/wintermute-operations/quota-conservation/HOLD.json}"
AV="${AV_DIR:-$HOME/.local/state/aide-verifier}"
FB="${FEEDBACK_DIR:-$HOME/wintermute-operations/feedback}"
SJ="${STATUS_JSON:-$HOME/.cache/fleet-dash/status.json}"
WAKE="${AIDE_WAKE_BIN:-$HOME/.local/bin/aide-wake.sh}"
ACT='^[^|]*\| *(hermes[^ |]*|joe[^ |]*|fivewhys[^ |]*|rb|r7|controller|plain) *\|'
OBL='\| *followup-loop *\|.* OBLIGATION-KEY id=[A-Za-z0-9._-]+ rev=[0-9]+ fp=[0-9a-f]{12}( |$)'
now() { printf '%s' "${EW_NOW:-$(date +%s)}"; }
num() { [[ "${1:-}" =~ ^[0-9]{1,12}$ ]] && printf '%s' "$1" || printf 0; }
jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'; }
emit() { # kind detail(json)
  echo "$info_total" > "$EW/info.total"; snapshot "$polls" "$info_total" "$(hold_sig)" "$(wc -l < "$EW/due-now.tmp" 2>/dev/null || echo 0)" "$$"
  printf '{"event":"%s","ts":"%s","detail":%s}\n' "$1" "$(date -Iseconds)" "$2"; }

inbox_new() { # print actionable new lines since pos; advance pos; informational count to $EW/info.tmp
  local size pos new
  echo 0 > "$EW/info.tmp"; [ -f "$LOG" ] || return 1
  size="$(stat -c %s "$LOG")"; pos="$(num "$(head -c 20 "$EW/pos" 2>/dev/null)")"
  [ "$pos" -gt "$size" ] && pos=0
  [ "$size" -gt "$pos" ] || return 1
  # advance only to the last complete line; a line caught mid-write waits for the next poll
  local chunk nl
  chunk="$(tail -c +"$((pos + 1))" "$LOG" | head -c $((size - pos)); printf x)"; chunk="${chunk%x}"
  case "$chunk" in *$'\n'*) nl="${chunk%$'\n'*}"; size=$((pos + ${#nl} + 1)); chunk="$nl" ;; *) return 1 ;; esac
  new="$(printf '%s\n' "$chunk" | grep -a .)"
  printf '%s\n' "$size" > "$EW/pos"
  printf '%s\n' "$new" | grep -a -E "$OBL" >> "$EW/obl.pending"   # typed obligation bells are kept until emitted (at-least-once; the route dedupes by key)
  printf '%s\n' "$new" | grep -a -vE "$OBL" | grep -a -vcE "$ACT" > "$EW/info.tmp"
  printf '%s\n' "$new" | grep -a -E "$ACT"
}
due_new() { # ids owned by aide|ctl with a passed ISO due, minus those already reported
  local t="$(now)"
  awk -F'\t' -v t="$t" '/^# CLOSED/{exit} /^#/{next} NF>=4 && ($3=="aide"||$3=="ctl") && $4 ~ /^20[0-9][0-9]-/ {
      d=$4; gsub(/[-:T]/," ",d); split(d,a," "); e=mktime(a[1]" "a[2]" "a[3]" "a[4]" "a[5]" 00"); if (e<=t) print $1 }' "$OA" 2>/dev/null \
    | sort > "$EW/due-now.tmp"
  touch "$EW/due-seen"; comm -23 "$EW/due-now.tmp" <(sort "$EW/due-seen")
}
hold_sig() { [ -f "$HOLD" ] && sha256sum "$HOLD" | cut -c1-16 || echo absent; }
alarms_sig() { python3 -I - "$SJ" <<'PY' 2>/dev/null
import json,sys,re
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for a in d.get("alarms") or []:
    t=a.get("text") if isinstance(a,dict) else str(a)
    print(re.sub(r"[0-9.]+","#",str(t)))
PY
}
newer() { find "$@" -newer "$EW/start" 2>/dev/null | sort | head -5; }
snapshot() { # structured status every poll
  python3 -I - "$EW/status.json" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json,sys,datetime
p,polls,info,hold,ndue,pid=sys.argv[1:7]
json.dump({"ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),"polls":int(polls),
  "inbox_informational_since_start":int(info),"hold":hold,"due_pending_unreported":int(ndue),"waiter_pid":int(pid),
  "fable_turn_needed":False},open(p+".tmp","w")); import os; os.replace(p+".tmp",p)
PY
}

selftest() {
  local T; T="$(mktemp -d)"; local f=0 n=0
  chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
  mkdir -p "$T/ev" "$T/av/x" "$T/fb" "$T/ew"
  printf 'id\tasked\towner\tdue\tdone_re\tcheck\twhat\n' > "$T/oa"
  printf 't | ctl | own receipt\n' > "$T/ev/aide-events.log"
  printf '{"alarms":[{"text":"decision-unverdicted 164 oldest 7159min"}]}' > "$T/sj"
  printf '#!/bin/sh\necho "$@" >> %s/wake.log\n' "$T" > "$T/wake"; chmod +x "$T/wake"
  st() { env -i HOME="$T" PATH="$PATH" EW_DIR="$T/ew" EVENTS_DIR="$T/ev" OPEN_ASKS="$T/oa" HOLD_FILE="$T/hold" AV_DIR="$T/av" FEEDBACK_DIR="$T/fb" STATUS_JSON="$T/sj" AIDE_WAKE_BIN="$T/wake" "$@"; }
  local out
  out="$(st bash "$0" wait --max-sec 2 --poll 1)"; printf '%s' "$out" | grep -q '"event":"timeout"' && [ "$(grep -c . "$T/ev/aide-events.log")" = 1 ]; chk "own ctl receipt only: no event, timeout after max-sec ($out)" $?
  [ -f "$T/ew/status.json" ] && grep -q '"fable_turn_needed": false' "$T/ew/status.json"; chk "unchanged cycle writes structured status.json, fable_turn_needed false" $?
  printf 't | rb | rb-info FYI only\n' >> "$T/ev/aide-events.log"   # seat lines ARE actionable (a seat message)
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"inbox"' && printf '%s' "$out" | grep -q 'rb-info FYI only'; chk "seat line -> inbox event carrying the line" $?
  out="$(st bash "$0" wait --max-sec 2 --poll 1)"; printf '%s' "$out" | grep -q '"event":"timeout"'; chk "same line is not emitted twice (exactly once)" $?
  printf 't | aide | aide-self\nt | hermes-joe-approved | TASK go\n' >> "$T/ev/aide-events.log"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q 'TASK go' && ! printf '%s' "$out" | grep -q 'aide-self'; chk "hermes line is the event; the aide receipt beside it is informational" $?
  st bash "$0" status | grep -q '"inbox_informational_since_start": 1'; chk "status counts the informational line" $?
  printf 'P99\t2026-11-06T10:00\tctl\t2026-11-06T10:00\t-\t-\tdue test\n' >> "$T/oa"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"due"' && printf '%s' "$out" | grep -q P99; chk "passed due row owned by ctl -> due event" $?
  out="$(st bash "$0" wait --max-sec 2 --poll 1)"; printf '%s' "$out" | grep -q '"event":"timeout"'; chk "due row reported once only" $?
  sleep 1; echo '{"verdict":"CONFIRM"}' > "$T/av/x/result.json"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"verifier"' && printf '%s' "$out" | grep -q 'av/x/result.json'; chk "synthetic verifier result.json -> verifier event" $?
  out="$(st bash "$0" wait --max-sec 2 --poll 1)"; printf '%s' "$out" | grep -q '"event":"timeout"'; chk "verifier result reported once only" $?
  echo '{"reason":"t"}' > "$T/hold"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"hold"'; chk "HOLD.json appearing -> hold event" $?
  printf '{"alarms":[{"text":"decision-unverdicted 200 oldest 1min"},{"text":"ask-overdue 3"}]}' > "$T/sj"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"alarm"' && printf '%s' "$out" | grep -q 'ask-overdue' && ! printf '%s' "$out" | grep -q unverdicted; chk "new alarm kind -> alarm event; a count change alone is not" $?
  sleep 1; echo x > "$T/fb/new-task.md"
  out="$(st bash "$0" wait --max-sec 3 --poll 1)"; printf '%s' "$out" | grep -q '"event":"taskfile"'; chk "new task file -> taskfile event" $?
  grep -q 'arm 35' "$T/wake.log"; chk "liveness lease armed through aide-wake.sh" $?
  rm -rf "$T"; echo "ctl-event-wait selftest: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; return $f
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  status) cat "$EW/status.json" 2>/dev/null || echo '{"status":"no snapshot yet"}'; exit 0 ;;
  wait) shift ;;
  *) echo "usage: ctl-event-wait.sh wait [--max-sec N] [--poll S] | status | --selftest" >&2; exit 2 ;;
esac
MAX=0; POLL=20
while [ $# -gt 0 ]; do case "$1" in --max-sec) MAX="$(num "${2:-}")"; shift 2 ;; --poll) POLL="$(num "${2:-}")"; shift 2 ;; *) shift ;; esac; done
[ "$POLL" -gt 0 ] || POLL=20
mkdir -p "$EW"; [ -f "$EW/start" ] || touch "$EW/start"; t0="$(now)"; polls=0; info_total="$(num "$(cat "$EW/info.total" 2>/dev/null)")"; last_arm=0
[ -f "$EW/pos" ] || stat -c %s "$LOG" 2>/dev/null > "$EW/pos" || echo 0 > "$EW/pos"
[ -f "$EW/hold.sig" ] || hold_sig > "$EW/hold.sig"
[ -f "$EW/alarms.sig" ] || alarms_sig | sort -u > "$EW/alarms.sig"
echo $$ > "$EW/pid"
while :; do
  polls=$((polls+1)); t="$(now)"
  if [ -x "$WAKE" ] && [ $((t - last_arm)) -ge 1200 ]; then "$WAKE" arm 35 >/dev/null 2>&1; last_arm=$t; fi
  lines="$(inbox_new)"; info_total=$((info_total + $(num "$(cat "$EW/info.tmp" 2>/dev/null)")))
  if [ -n "$lines" ]; then emit inbox "$(printf '%s\n' "$lines" | cut -c1-400 | python3 -I -c 'import json,sys; print(json.dumps({"lines":sys.stdin.read().rstrip("\n").split("\n")}))')"; exit 0; fi
  if [ -s "$EW/obl.pending" ]; then
    # the typed key is extracted from the WHOLE bell line before any truncation, so a long bell keeps id + rev + fp whole (detail.keys); lines are cut for display only
    o="$(emit obligation "$(python3 -I -c 'import json,re,sys
rx = re.compile(r"OBLIGATION-KEY id=([A-Za-z0-9._-]+) rev=([0-9]+) fp=([0-9a-f]{12})(?: |$)")
ls = sys.stdin.read().rstrip("\n").split("\n"); keys = []
for l in ls:
    for m in rx.finditer(l):
        k = {"id": m.group(1), "rev": m.group(2), "fp": m.group(3)}
        if k not in keys: keys.append(k)
print(json.dumps({"lines": [l[:400] for l in ls], "keys": keys}))' < "$EW/obl.pending")")"
    : > "$EW/obl.pending"; printf '%s\n' "$o"; exit 0
  fi
  due="$(due_new)"
  if [ -n "$due" ]; then printf '%s\n' "$due" >> "$EW/due-seen"; emit due "$(printf '%s\n' "$due" | python3 -I -c 'import json,sys; print(json.dumps({"ids":sys.stdin.read().split()}))')"; exit 0; fi
  v="$(newer "$AV" -name result.json)"
  if [ -n "$v" ]; then touch "$EW/start"; emit verifier "$(printf '%s\n' "$v" | python3 -I -c 'import json,sys; print(json.dumps({"files":sys.stdin.read().split()}))')"; exit 0; fi
  # status/monitor receipts Hermes rewrites on a clock are informational, never an event
  tf="$(newer "$FB" -maxdepth 1 -name '*.md' ! -name '*status*' ! -name '*monitor*' ! -name '*receipt*')"
  if [ -n "$(newer "$FB" -maxdepth 1 -name '*.md' \( -name '*status*' -o -name '*monitor*' -o -name '*receipt*' \))" ]; then touch "$EW/start"; fi
  if [ -n "$tf" ]; then touch "$EW/start"; emit taskfile "$(printf '%s\n' "$tf" | python3 -I -c 'import json,sys; print(json.dumps({"files":sys.stdin.read().split()}))')"; exit 0; fi
  hs="$(hold_sig)"; if [ "$hs" != "$(cat "$EW/hold.sig")" ]; then echo "$hs" > "$EW/hold.sig"; emit hold "{\"hold\":\"$hs\"}"; exit 0; fi
  na="$(alarms_sig | sort -u | comm -13 "$EW/alarms.sig" -)"
  if [ -n "$na" ]; then alarms_sig | sort -u > "$EW/alarms.sig"; emit alarm "$(printf '%s\n' "$na" | python3 -I -c 'import json,sys; print(json.dumps({"new":sys.stdin.read().rstrip("\n").split("\n")}))')"; exit 0; fi
  ndue="$(wc -l < "$EW/due-now.tmp" 2>/dev/null || echo 0)"
  echo "$info_total" > "$EW/info.total"; snapshot "$polls" "$info_total" "$hs" "$ndue" "$$"
  if [ "$MAX" -gt 0 ] && [ $((t - t0)) -ge "$MAX" ]; then emit timeout "{\"polls\":$polls,\"informational\":$info_total}"; exit 0; fi
  sleep "$POLL"
done
