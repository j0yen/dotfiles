#!/usr/bin/env bash
# watcher-premise.sh -- SOURCED lib: every write-capable watcher carries a PREMISE + EXPIRES, a decision row per write, and a --selftest.
# CLAUDE.md WATCHERS AND CHECKERS (CTRL 8:15 PM 10-20); design = Fable AGREE-WITH-EDITS E1-E13 (r7 seat, 10-20 8:3x PM).
# ONE implementation: python watchers call it through bash (E7), e.g.
#   subprocess.run(["bash","-c","source ~/.local/lib/watcher-premise.sh; wp_arm N 'cmd' ISO; wp_gate"]).
# Names, status columns, exit codes and the write-verb list: watcher-premise.spec (tests check the lib against it).
#
#   wp_arm NAME PREMISE_CMD EXPIRES_ISO [PREMISE_TEXT]   NAME = the watcher's unit basename (also the by= tag and the status file key)
#   wp_gate                                               rc 0 = writes allowed; rc 1 = disarmed. Overwrites ONE status line (E9).
#   wp_emit_write KIND TARGET WHAT EVIDENCE REVERSE       outbox append FIRST, then wm-decide record where present (E1/E4). rc 1 = BLOCK.
#   wp_by / wp_selftest / wp_decide_record
#
# Every write site is   wp_gate && wp_emit_write ... && <the write>      (or: if wp_gate && wp_emit_write ...; then <the write>; fi)
# PREMISE_CMD runs in a fresh `bash -c` (exported env only), 20 s timeout: rc 0 = HOLDS, rc 1 = GONE, anything else = UNKNOWN (E3).
# Env: WP_STATE (default ~/.local/state/watcher-premise)  WP_GATE_TTL (s, default 5)  WP_PREMISE_TIMEOUT (default 20)  WP_UNIT  WP_LOG
#      WP_OWNER (r7|rb|aide, the wm-decide --agent, default r7)  WP_DECIDE_BIN (default wm-decide)  WP_DECIDE_KIND (default guard)
#      WP_GUARD_NAME (by= name when it differs from NAME)

WP_LIB_PATH=${BASH_SOURCE[0]}
# Must equal the [status_columns] line of watcher-premise.spec (tests/lib.sh checks it).
WP_STATUS_COLS="name host premise verdict expires armed last_write checked_ts unknown_since defect reason"
: "${WP_STATE:=$HOME/.local/state/watcher-premise}"

_wp_clean() { local s=${1-}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/ }; printf '%s' "$s"; }

wp_log() { local f=${WP_LOG:-$WP_STATE/${WP_NAME:-lib}.log}; mkdir -p "$(dirname "$f")" 2>/dev/null; printf '%s wp %s %s\n' "$(date -Is)" "${WP_NAME:-?}" "$*" >> "$f" 2>/dev/null || true; }

wp_arm() {
  WP_NAME=${1-}; WP_PREMISE_CMD=${2-}; WP_EXPIRES=${3-}; WP_PREMISE_TEXT=${4:-${2-}}
  WP_HOST=${WP_HOST:-$(hostname -s 2>/dev/null || echo unknown)}
  WP_OK=1; WP_EXPIRES_EPOCH=""
  case "$WP_NAME" in ""|*[!A-Za-z0-9._-]*) WP_OK=0;; esac
  [ -n "$WP_PREMISE_CMD" ] || WP_OK=0
  if [ -n "$WP_EXPIRES" ]; then WP_EXPIRES_EPOCH=$(date -d "$WP_EXPIRES" +%s 2>/dev/null) || WP_EXPIRES_EPOCH=""; fi
  [ -n "$WP_EXPIRES_EPOCH" ] || WP_OK=0
  WP_EVAL_AT=0; WP_ARMED=0; WP_VERDICT=UNKNOWN; WP_DEFECT=misconfigured; WP_REASON=-; WP_UNKNOWN_SINCE=0; WP_LAST_WRITE=-
  if [ "$WP_OK" = 1 ]; then WP_LAST_WRITE=$(cat "$WP_STATE/$WP_NAME.lastwrite" 2>/dev/null || echo -); [ -n "$WP_LAST_WRITE" ] || WP_LAST_WRITE=-; fi
  [ "$WP_OK" = 1 ] || return 2
}

# previous status line -> P_* (change detection + the continuous-UNKNOWN clock)
_wp_prev() {
  P_VERDICT=""; P_ARMED=""; P_DEFECT=""; P_UNKNOWN_SINCE=0
  local f=$WP_STATE/$WP_NAME.tsv a=()
  [ -r "$f" ] || return 0
  IFS=$'\037' read -r -a a < <(head -n1 "$f" | tr '\t' '\037') || true
  P_VERDICT=${a[3]-}; P_ARMED=${a[5]-}; P_DEFECT=${a[9]-}; P_UNKNOWN_SINCE=${a[8]-0}
  case "$P_UNKNOWN_SINCE" in ''|*[!0-9]*) P_UNKNOWN_SINCE=0;; esac
  return 0
}

# ONE line, overwritten atomically (E9)
_wp_render() {
  mkdir -p "$WP_STATE" 2>/dev/null || return 0
  local f=$WP_STATE/$WP_NAME.tsv tmp
  tmp=$f.tmp.$$
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$WP_NAME" "$WP_HOST" "$(_wp_clean "$WP_PREMISE_TEXT")" "$WP_VERDICT" "$(_wp_clean "$WP_EXPIRES")" "$WP_ARMED" \
    "${WP_LAST_WRITE:--}" "$(date +%s)" "${WP_UNKNOWN_SINCE:-0}" "${WP_DEFECT:--}" "$(_wp_clean "${WP_REASON:--}")" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

wp_gate() {
  [ -n "${WP_NAME:-}" ] || { echo "wp_gate: wp_arm was not called -- writes disarmed" >&2; return 1; }
  local now out rc verdict armed=1 defect=- reason=- us=0
  now=$(date +%s)
  if [ "${WP_EVAL_AT:-0}" -gt 0 ] && [ $((now - WP_EVAL_AT)) -lt "${WP_GATE_TTL:-5}" ]; then [ "$WP_ARMED" = 1 ]; return; fi
  _wp_prev
  if [ "${WP_OK:-0}" != 1 ]; then
    verdict=UNKNOWN; armed=0; defect=misconfigured; reason="wp_arm arguments invalid (name, premise cmd or EXPIRES)"
  else
    out=$(timeout "${WP_PREMISE_TIMEOUT:-20}" bash -c "$WP_PREMISE_CMD" 2>&1 </dev/null); rc=$?
    case $rc in 0) verdict=HOLDS;; 1) verdict=GONE;; *) verdict=UNKNOWN;; esac
    reason=$(printf '%s' "$out" | head -n1 | cut -c1-200)
    reason="rc=$rc ${reason:--}"
    if [ "$verdict" = UNKNOWN ]; then
      if [ "$P_VERDICT" = UNKNOWN ] && [ "$P_UNKNOWN_SINCE" -gt 0 ]; then us=$P_UNKNOWN_SINCE; else us=$now; fi
    fi
    [ "$verdict" = GONE ] && armed=0
    if [ "$now" -gt "$WP_EXPIRES_EPOCH" ]; then armed=0; defect=expired; fi
    if [ "$verdict" = UNKNOWN ] && [ "$defect" = - ] && [ $((now - us)) -gt 3600 ]; then defect="unknown>60m"; fi
  fi
  WP_VERDICT=$verdict; WP_ARMED=$armed; WP_DEFECT=$defect; WP_REASON=$reason; WP_UNKNOWN_SINCE=$us; WP_EVAL_AT=$now
  _wp_render
  if [ "$P_VERDICT $P_ARMED $P_DEFECT" != "$verdict $armed $defect" ]; then
    wp_log "premise verdict=$verdict armed=$armed defect=$defect expires=$WP_EXPIRES reason=$(_wp_clean "$reason")"
    [ "$armed" = 1 ] || echo "wp_gate: $WP_NAME disarmed (verdict=$verdict defect=$defect): $(_wp_clean "$reason")" >&2
  fi
  [ "$armed" = 1 ]
}

wp_by() { printf 'joe-%s+%s' "$(date +%Y%m%d)" "${WP_GUARD_NAME:-${WP_NAME:-unknown}}"; }

_wp_unit() {
  if [ -n "${WP_UNIT:-}" ]; then printf '%s' "$WP_UNIT"; return; fi
  local u; u=$(sed -n 's|.*/\([^/]*\.\(service\|timer\|scope\)\)$|\1|p' /proc/$$/cgroup 2>/dev/null | tail -n1)
  printf '%s' "${u:--}"
}

# wm-decide record argv from one outbox line, NUL-separated (ONE builder: the writer and the carbon puller both use it)
_wp_decide_argv() { # LINE_JSON BIN OWNER DECIDE_KIND
  python3 -I -c '
import json,sys
r=json.loads(sys.argv[1]); bin_,owner,dk=sys.argv[2:5]; owner=r.get("owner") or owner
why="guard write; premise: %s [%s, expires %s]" % (r.get("premise","-"), r.get("verdict","-"), r.get("expires","-"))
argv=[bin_,"record","--agent",owner,"--via",r.get("watcher","?"),"--model","none","--kind",dk,
 "--what",r.get("what",""),"--why",why,"--evidence",r.get("evidence",""),"--reverse-text",r.get("reverse",""),
 "--target",r.get("target",""),"--tag","by="+r.get("by",""),"--tag","wp-id="+r.get("id",""),
 "--tag","wp-kind="+r.get("kind",""),"--tag","host="+r.get("host","")]
sys.stdout.buffer.write(b"\0".join(a.encode() for a in argv))' "$@"
}

wp_decide_record() { # LINE_JSON -> runs wm-decide record; rc 127 = no wm-decide, other rc = what wm-decide returned
  local line=$1 bin=${WP_DECIDE_BIN:-wm-decide} argv=()
  command -v "$bin" >/dev/null 2>&1 || return 127
  mapfile -d '' -t argv < <(_wp_decide_argv "$line" "$bin" "${WP_OWNER:-r7}" "${WP_DECIDE_KIND:-guard}")
  [ "${#argv[@]}" -gt 0 ] || return 1
  timeout "${WP_DECIDE_TIMEOUT:-20}" "${argv[@]}"
}

wp_emit_write() { # KIND TARGET WHAT EVIDENCE REVERSE
  [ "$#" -eq 5 ] || { echo "wp_emit_write: need KIND TARGET WHAT EVIDENCE REVERSE" >&2; return 1; }
  [ -n "${WP_NAME:-}" ] || return 1
  local kind=$1 target=$2 what=$3 evid=$4 rev=$5 decide=none line ob ts id out rc
  command -v "${WP_DECIDE_BIN:-wm-decide}" >/dev/null 2>&1 && decide=attempt
  line=$(python3 -I -c '
import json,sys,hashlib,time,datetime
kind,target,what,evid,rev,watcher,host,pid,unit,by,premise,verdict,expires,decide,owner=sys.argv[1:16]
cap=lambda s: s if len(s)<=3000 else s[:2990]+"...[cut]"
ns=time.time_ns()
ts=datetime.datetime.now().astimezone().isoformat(timespec="seconds")
rid=hashlib.sha256("|".join([host,watcher,pid,str(ns),what]).encode()).hexdigest()[:16]
print(json.dumps({"ev":"write","id":rid,"ts":ts,"epoch":ns//10**9,"host":host,"watcher":watcher,"pid":int(pid) if pid.isdigit() else pid,
 "unit":unit,"kind":kind,"target":cap(target),"what":cap(what),"evidence":cap(evid),"reverse":cap(rev),"by":by,"premise":cap(premise),
 "verdict":verdict,"expires":expires,"decide":decide,"owner":owner},ensure_ascii=False,separators=(",",":")))' \
    "$kind" "$target" "$what" "$evid" "$rev" "$WP_NAME" "$WP_HOST" "$$" "$(_wp_unit)" "$(wp_by)" "$(_wp_clean "$WP_PREMISE_TEXT")" "${WP_VERDICT:-UNKNOWN}" "$WP_EXPIRES" "$decide" "${WP_OWNER:-r7}" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  mkdir -p "$WP_STATE" 2>/dev/null || return 1
  ob=$WP_STATE/outbox-$(date +%Y%m%d).jsonl
  printf '%s\n' "$line" >> "$ob" 2>/dev/null || { wp_log "OUTBOX APPEND FAILED $ob -- write BLOCKED"; return 1; }
  ts=$(date +%s); WP_LAST_WRITE=$ts; printf '%s\n' "$ts" > "$WP_STATE/$WP_NAME.lastwrite" 2>/dev/null || true
  [ "${WP_EVAL_AT:-0}" -gt 0 ] && _wp_render
  if [ "$decide" = attempt ]; then
    id=${line#\{\"ev\":\"write\",\"id\":\"}; id=${id%%\"*}
    out=$(wp_decide_record "$line" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then
      printf '{"ev":"recorded","id":"%s","ts":"%s","epoch":%s,"host":"%s","watcher":"%s"}\n' "$id" "$(date -Is)" "$ts" "$WP_HOST" "$WP_NAME" >> "$ob" 2>/dev/null || true
    else
      wp_log "wm-decide record rc=$rc id=$id (write proceeds; the puller retries from the outbox): $(_wp_clean "$(printf '%s' "$out" | head -n1 | cut -c1-160)")"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------------
# Consecutive-skip streak (tsd3 F3/W3, ctl a26e): r7-untagged-pause logged `no top tag (gh failed) - skip` on every 15 s run for an unknown time and alarmed
# nothing, because a skip is not a failure. A watcher calls   watcher_skip <reason>   on a run that did nothing for want of an input, and
# watcher_run_end   on any run that acted or found the world fine (the ONE reset). State: $WATCHER_STATE_DIR/<WP_NAME>.skip = "<n> <last reason>" (dir defaults to
# $WP_STATE). From WATCHER_SKIP_MAX (default 20) consecutive skips, watcher_skip prints `alarm: skip-streak <name> <n> <reason>` and sets WATCHER_SKIP_ALARM to
# that text without the "alarm: " prefix; the watcher puts WATCHER_SKIP_STREAK / _REASON / _ALARM in the status.json the fleet-dash collector ingests.
_wsk_file() { printf '%s/%s.skip' "${WATCHER_STATE_DIR:-$WP_STATE}" "${WP_NAME:-unnamed}"; }
_wsk_write() { # N REASON -> atomic one-line state file
  local f t; f=$(_wsk_file); t=$f.tmp.$$
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  { printf '%s %s\n' "$1" "$2" > "$t" && mv -f "$t" "$f"; } 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
}
watcher_skip_streak() { local n; n=$(cut -d' ' -f1 "$(_wsk_file)" 2>/dev/null | head -n1); case "$n" in ''|*[!0-9]*) n=0;; esac; printf '%s' "$n"; }
watcher_skip_alarm() { # prints `skip-streak <name> <n> <reason>` when the persisted streak is at/over the threshold, nothing otherwise (also read by status writers)
  local max n r; max=${WATCHER_SKIP_MAX:-20}; case "$max" in ''|*[!0-9]*|0) max=20;; esac
  n=$(watcher_skip_streak); [ "$n" -ge "$max" ] || return 0
  r=$(cut -d' ' -f2- "$(_wsk_file)" 2>/dev/null | head -n1)
  printf 'skip-streak %s %s %s' "${WP_NAME:-unnamed}" "$n" "${r:--}"
}
watcher_skip() { # REASON
  [ -n "${WP_NAME:-}" ] || { echo "watcher_skip: wp_arm was not called" >&2; return 1; }
  local reason n
  reason=$(_wp_clean "${1:-skip}"); reason=${reason:0:120}; [ -n "$reason" ] || reason=skip
  n=$(( $(watcher_skip_streak) + 1 ))
  _wsk_write "$n" "$reason" || echo "watcher_skip: cannot write $(_wsk_file)" >&2
  WATCHER_SKIP_STREAK=$n; WATCHER_SKIP_REASON=$reason; WATCHER_SKIP_ALARM=$(watcher_skip_alarm)
  [ -z "$WATCHER_SKIP_ALARM" ] || echo "alarm: $WATCHER_SKIP_ALARM"
  return 0
}
watcher_run_end() { # any non-skip run (acted, or looked and found nothing wrong): the streak is over
  [ -n "${WP_NAME:-}" ] || return 1
  WATCHER_SKIP_STREAK=0; WATCHER_SKIP_REASON=; WATCHER_SKIP_ALARM=
  [ -e "$(_wsk_file)" ] || return 0
  _wsk_write 0 - || return 1
}

# ---------------------------------------------------------------------------------------------------------------------------
# wp_selftest: the lib's own scenarios in throwaway HOMEs (one per scenario), stub wm-decide recording argv. Prints `selftest ok N/N`.
wp_selftest() {
  local pass=0 fail=0 T got
  local root=${WP_SELFTEST_ROOT:-${TMPDIR:-$HOME/tmp}}; mkdir -p "$root"
  _st_mk() { T=$(mktemp -d "$root/wp-selftest.XXXXXX") || return 1; mkdir -p "$T/bin" "$T/.local/state"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HOME/decide.argv"\nexit "${WP_STUB_RC:-0}"\n' > "$T/bin/wm-decide.stub"; chmod +x "$T/bin/wm-decide.stub"; }
  _st_run() { local h; h=$(mktemp -d "$T/h.XXXXXX"); env -i HOME="$h" PATH="$T/bin:/usr/bin:/bin" TMPDIR="$h" TZ="${TZ:-UTC}" "$@" bash -c 'source "$0"; '"$BODY" "$WP_LIB_PATH" 2>/dev/null; rm -rf "$h"; }
  _st_ok() { # name expected  (BODY + extra env from ENVV)
    got=$(_st_run ${ENVV:-WP_X=1}); if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got '$got' want '$2'"; fi; }
  local FUT PAST; FUT='$(date -d "+1 day" -Is)'; PAST='$(date -d "-1 day" -Is)'
  local pre='export WP_GATE_TTL=0; '
  _st_mk
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED"';           _st_ok holds   "rc=0 v=HOLDS a=1"
  BODY="$pre"'wp_arm t1 "exit 1" "'"$FUT"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED"';           _st_ok gone    "rc=1 v=GONE a=0"
  BODY="$pre"'wp_arm t1 "exit 2" "'"$FUT"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED d=$WP_DEFECT"'; _st_ok unknown "rc=0 v=UNKNOWN a=1 d=-"
  ENVV="WP_PREMISE_TIMEOUT=1" BODY="$pre"'wp_arm t1 "sleep 4" "'"$FUT"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED"'; _st_ok timeout "rc=0 v=UNKNOWN a=1"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$PAST"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED d=$WP_DEFECT"'; _st_ok expired "rc=1 v=HOLDS a=0 d=expired"
  BODY="$pre"'wp_arm t1 "exit 2" "'"$PAST"'"; wp_gate; echo "rc=$? v=$WP_VERDICT a=$WP_ARMED d=$WP_DEFECT"'; _st_ok unknown-past-expires "rc=1 v=UNKNOWN a=0 d=expired"
  BODY="$pre"'wp_arm t1 "exit 0" "not-a-date"; echo -n "arm=$? "; wp_gate; echo "gate=$? a=$WP_ARMED d=$WP_DEFECT"'; _st_ok misconfigured "arm=2 gate=1 a=0 d=misconfigured"
  BODY="$pre"'wp_gate; echo "rc=$?"'; _st_ok unarmed "rc=1"
  BODY="$pre"'wp_arm t1 "exit 2" "'"$FUT"'"; mkdir -p $WP_STATE; printf "t1\th\tp\tUNKNOWN\te\t1\t-\t0\t%s\t-\tr\n" $(( $(date +%s) - 7200 )) > $WP_STATE/t1.tsv; wp_gate; echo "rc=$? a=$WP_ARMED d=$WP_DEFECT"'
  _st_ok unknown-60m "rc=0 a=1 d=unknown>60m"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_gate; wp_gate; echo "lines=$(wc -l < $WP_STATE/t1.tsv) cols=$(head -n1 $WP_STATE/t1.tsv | awk -F"\t" "{print NF}") files=$(ls $WP_STATE/t1.tsv* | wc -l)"'
  _st_ok one-line-overwritten "lines=1 cols=$(printf '%s\n' $WP_STATUS_COLS | wc -l) files=1"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_gate; wp_gate; echo "log=$(wc -l < $WP_STATE/t1.log)"'; _st_ok log-once-per-change "log=1"
  BODY='export WP_GATE_TTL=0; wp_arm t1 "echo x >> $HOME/runs; exit 0" "'"$FUT"'"; wp_gate; wp_gate; echo "runs0=$(wc -l < $HOME/runs)"; export WP_GATE_TTL=60; wp_arm t1 "echo x >> $HOME/runs; exit 0" "'"$FUT"'"; WP_EVAL_AT=0; wp_gate; wp_gate; wp_gate; echo "runs1=$(wc -l < $HOME/runs)"'
  _st_ok ttl-cache $'runs0=2\nruns1=3'
  # emit
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'" "premise text"; wp_gate; wp_emit_write limit "host=h max_runs=1" "wm-build-limits-guard set max_runs=1 --by x \"q\" \$y" "ev idence" "undo it"; echo "rc=$?"; ls $WP_STATE | grep -c "^outbox-[0-9]\{8\}\.jsonl$"; python3 -I -c "
import json,sys
r=json.loads(open(sys.argv[1]).readline()); print(sorted(r)==sorted([\"ev\",\"id\",\"ts\",\"epoch\",\"host\",\"watcher\",\"pid\",\"unit\",\"kind\",\"target\",\"what\",\"evidence\",\"reverse\",\"by\",\"premise\",\"verdict\",\"expires\",\"decide\",\"owner\"]), r[\"what\"], r[\"reverse\"], r[\"watcher\"], r[\"decide\"], r[\"by\"].startswith(\"joe-\") and r[\"by\"].endswith(\"+t1\"), r[\"pid\"]>0)" $WP_STATE/outbox-*.jsonl'
  _st_ok emit-row $'rc=0\n1\nTrue wm-build-limits-guard set max_runs=1 --by x "q" $y undo it t1 none True True'
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_emit_write a b c d e; head -c 40 $WP_STATE/outbox-*.jsonl > $HOME/first; wp_emit_write f g h i j; echo "lines=$(wc -l < $WP_STATE/outbox-*.jsonl) same=$(head -c 40 $WP_STATE/outbox-*.jsonl | cmp -s - $HOME/first && echo y || echo n)"'
  _st_ok append-only "lines=2 same=y"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; mkdir -p $WP_STATE/outbox-$(date +%Y%m%d).jsonl; wp_emit_write a b c d e; echo "rc=$?"'; _st_ok append-fails-blocks "rc=1"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_emit_write a b c; echo "rc=$?"'; _st_ok bad-arity "rc=1"
  # wm-decide present: stub renamed into place per scenario
  mv "$T/bin/wm-decide.stub" "$T/bin/wm-decide"
  BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'" "pt"; wp_gate; wp_emit_write limit "host=h" "w" "e" "r"; echo "rc=$? lines=$(wc -l < $WP_STATE/outbox-*.jsonl) rec=$(grep -c "\"ev\":\"recorded\"" $WP_STATE/outbox-*.jsonl) kind=$(grep -c -- "--kind guard" $HOME/decide.argv) agent=$(grep -c -- "--agent r7 --via t1" $HOME/decide.argv) tag=$(grep -c -- "--tag by=joe-" $HOME/decide.argv)"'
  _st_ok decide-ok "rc=0 lines=2 rec=1 kind=1 agent=1 tag=1"
  ENVV="WP_OWNER=aide" BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_emit_write rotate "host=h" "w" "e" "r"; echo "rc=$? agent=$(grep -c -- "--agent aide --via t1" $HOME/decide.argv) r7=$(grep -c -- "--agent r7" $HOME/decide.argv) owner=$(grep -c "\"owner\":\"aide\"" $WP_STATE/outbox-*.jsonl)"'
  _st_ok owner-aide "rc=0 agent=1 r7=0 owner=1"
  ENVV="WP_STUB_RC=2" BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_emit_write limit "host=h" "w" "e" "r"; echo "rc=$? lines=$(wc -l < $WP_STATE/outbox-*.jsonl) rec=$(grep -c "\"ev\":\"recorded\"" $WP_STATE/outbox-*.jsonl) dec=$(grep -c "\"decide\":\"attempt\"" $WP_STATE/outbox-*.jsonl)"'
  _st_ok decide-fails-write-proceeds "rc=0 lines=1 rec=0 dec=1"
  ENVV="WP_DECIDE_BIN=nonexistent-wm-decide" BODY="$pre"'wp_arm t1 "exit 0" "'"$FUT"'"; wp_gate; wp_emit_write limit "host=h" "w" "e" "r"; echo "rc=$? dec=$(grep -c "\"decide\":\"none\"" $WP_STATE/outbox-*.jsonl)"'
  _st_ok no-decide-binary "rc=0 dec=1"
  BODY="$pre"'wp_arm my-guard "exit 0" "'"$FUT"'"; echo "$(wp_by)"; WP_GUARD_NAME=other; echo "$(wp_by)"'; got=$(_st_run ${ENVV:-WP_X=1}); ENVV=
  if [ "$(printf '%s\n' "$got" | sed -n 1p | grep -cE '^joe-[0-9]{8}\+my-guard$')$(printf '%s\n' "$got" | sed -n 2p | grep -cE '^joe-[0-9]{8}\+other$')" = 11 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL by-tag: $got"; fi
  rm -rf "$T"
  unset -f _st_mk _st_run _st_ok
  if [ "$fail" = 0 ]; then echo "selftest ok $pass/$((pass+fail))"; return 0; fi
  echo "selftest FAILED $fail/$((pass+fail))"; return 1
}

# direct use: bash watcher-premise.sh --selftest
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--selftest" ]; then wp_selftest; exit $?; fi
