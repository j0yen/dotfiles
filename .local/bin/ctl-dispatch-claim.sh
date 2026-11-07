#!/usr/bin/env bash
# ctl-dispatch-claim.sh scan | run <key> | status   (A1210, recovery plan 666e step 4)
# Durable task-file dispatch. A dispatchable task file = <FB>/*.task.md carrying a line `Dispatch: ctl` (approved marker).
#   key   = sha256(path + content)[:16]; one claim dir per key (mkdir = atomic single claim); changed content = new key.
#   scan  : hold-gate first (held -> nothing claimed, retried next scan); then per file: no marker -> state=skipped;
#           else claim, write claim.json, start the worker detached via DP_START (default systemd-run + this script's `run`).
#           stale claims (state=claimed, never started, older than DP_STALE s) are retried once; a started claim that
#           never finished is marked failed-owned and Hermes+aide are notified. Started work is never re-executed.
#   run   : wrapper around the worker command DP_WORKER ("$path" appended); writes started marker, then receipt.json
#           {source,sha,rc,state=done|failed,started,finished}.
# Env (tests): DP_FEEDBACK DP_STATE DP_HOLD DP_WORKER DP_START DP_NOTIFY DP_STALE
set -uo pipefail
FB="${DP_FEEDBACK:-$HOME/wintermute-operations/feedback}"
ST="${DP_STATE:-$HOME/.cache/aide/dispatch}"
HOLDCMD="${DP_HOLD:-$HOME/.local/bin/hold-gate.sh ctl-dispatch}"
STALE="${DP_STALE:-600}"
NOTIFY="${DP_NOTIFY:-$HOME/.local/bin/seat-event.sh}"
SELF="$(readlink -f "$0")"
mkdir -p "$ST/claims"
ts(){ date +%Y-%m-%dT%H:%M:%S; }
note(){ [ "$NOTIFY" = none ] && return 0; for s in hermes aide; do "$NOTIFY" "$s" "ctl-dispatch: $1" >/dev/null 2>&1 || true; done; }
keyof(){ { printf '%s\0' "$1"; cat "$1"; } | sha256sum | cut -c1-16; }
jw(){ python3 -I -c 'import json,sys;json.dump(dict(a.split("=",1) for a in sys.argv[2:]),open(sys.argv[1],"w"))' "$@"; }
jget(){ python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

start_worker(){ # $1 key
  if [ -n "${DP_START:-}" ]; then "$DP_START" "$1"; else
    systemd-run --user --quiet --collect --unit="ctl-dispatch-$1" --description="ctl dispatch task $1" --setenv=DP_FEEDBACK="$FB" --setenv=DP_STATE="$ST" --setenv=DP_NOTIFY="$NOTIFY" ${DP_WORKER:+--setenv=DP_WORKER="$DP_WORKER"} "$SELF" run "$1"; fi
}

cmd_run(){
  k="$1"; d="$ST/claims/$k"; [ -f "$d/claim.json" ] || { echo "no claim $k" >&2; exit 66; }
  src="$(jget "$d/claim.json" source)"
  # started marker is created exclusively: a second run for the same claim cannot execute the effect again
  if ! ( set -C; echo "$(ts)" > "$d/started" ) 2>/dev/null; then echo "already-started $k"; exit 0; fi
  W="${DP_WORKER:-$HOME/.local/bin/fable-launch.sh --helper --model claude-sonnet-5-5 --effort medium --permission-mode bypassPermissions --no-session-persistence -p}"
  if [ -n "${DP_WORKER:-}" ]; then $W "$src" >"$d/worker.out" 2>"$d/worker.err"; rc=$?
  else $W "Execute the approved Hermes task file $src. It carries a Dispatch: ctl marker. Do the work it names, write results where it says, and end with a one-line RESULT." >"$d/worker.out" 2>"$d/worker.err" </dev/null; rc=$?; fi
  st=done; [ $rc -eq 0 ] || st=failed
  jw "$d/receipt.json" source="$src" key="$k" rc="$rc" state="$st" started="$(cat "$d/started")" finished="$(ts)"
  [ "$st" = failed ] && note "task $k ($(basename "$src")) FAILED rc=$rc after start; owned, not re-run (receipt $d/receipt.json)"
  exit 0
}

cmd_scan(){
  if ! $HOLDCMD >/dev/null 2>"$ST/hold.err"; then echo "held: $(head -c 160 "$ST/hold.err")"; return 0; fi
  n=0
  for f in "$FB"/*.task.md; do
    [ -f "$f" ] || continue
    k="$(keyof "$f")"; d="$ST/claims/$k"
    if ! mkdir "$d" 2>/dev/null; then
      # existing claim: recover stale unstarted / unfinished
      [ -f "$d/receipt.json" ] && continue
      c="$(jget "$d/claim.json" state 2>/dev/null)"; [ "$c" = skipped ] && continue
      age=$(( $(date +%s) - $(stat -c %Y "$d/claim.json" 2>/dev/null || date +%s) ))
      if [ ! -f "$d/started" ]; then
        if [ "$age" -ge "$STALE" ] && [ ! -f "$d/retried" ]; then touch "$d/retried"; start_worker "$k" && echo "retried-unstarted $k" && n=$((n+1)); fi
      else
        sage=$(( $(date +%s) - $(stat -c %Y "$d/started") ))
        if [ "$sage" -ge "$STALE" ] && [ ! -f "$d/orphan" ] && ! systemctl --user is-active --quiet "ctl-dispatch-$k" 2>/dev/null && [ -z "${DP_START:-}" ]; then
          touch "$d/orphan"; jw "$d/receipt.json" source="$f" key="$k" rc=-1 state=failed-owned started="$(cat "$d/started")" finished="$(ts)"
          note "task $k ($(basename "$f")) started but no worker/receipt; failed-owned, not re-run"; fi
      fi
      continue
    fi
    if ! grep -qE '^Dispatch: ctl[[:space:]]*$' "$f"; then
      jw "$d/claim.json" source="$f" key="$k" state=skipped reason=no-dispatch-marker ts="$(ts)"; echo "skipped $k $(basename "$f")"; continue; fi
    jw "$d/claim.json" source="$f" key="$k" state=claimed ts="$(ts)" sha="$k"
    echo "claimed $k $(basename "$f")"; n=$((n+1))
    start_worker "$k" || { rm -f "$d/started"; echo "start-failed $k" ; note "task $k start failed (claim kept, retried after ${STALE}s)"; }
  done
  echo "scan-done started=$n"
}

case "${1:-}" in
  scan) cmd_scan;;
  run) cmd_run "${2:?key}";;
  status) for d in "$ST"/claims/*/; do [ -f "$d/claim.json" ] || continue; printf '%s %s %s\n' "$(basename "$d")" "$(jget "$d/claim.json" state)$( [ -f "$d/receipt.json" ] && echo "/$(jget "$d/receipt.json" state)")" "$(basename "$(jget "$d/claim.json" source)")"; done;;
  *) echo "usage: $0 scan|run <key>|status" >&2; exit 64;;
esac
