#!/usr/bin/env bash
# ctl-fable-xhigh-transition.sh <old-pid> <session-id> <old-unit> <new-unit>
# Graceful checkpoint of a print-mode Fable analysis unit, then resume the SAME session at --effort xhigh.
# Checkpoint = wait (no cap) until the session transcript has no pending tool_use (no helper agent or tool in flight), then SIGTERM that exact pid.
set -u
PID="$1"; SID="$2"; OLD="$3"; NEW="$4"
LOG="$HOME/.cache/aide/xhigh-transition.log"; T="$HOME/.claude/projects/-home-jsy/$SID.jsonl"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep -qx -- '--effort' || { log "pid $PID not the expected claude (cmdline); abort"; exit 2; }
log "start: pid=$PID sid=$SID old=$OLD new=$NEW"
pending(){ python3 -I - "$T" <<'PY'
import json,sys
L=open(sys.argv[1]).read().splitlines()
u=set();r=set()
for l in L:
    try:d=json.loads(l)
    except Exception:continue
    c=d.get('message',{}).get('content')
    if not isinstance(c,list):continue
    for b in c:
        if not isinstance(b,dict):continue
        if b.get('type')=='tool_use':u.add(b['id'])
        if b.get('type')=='tool_result':r.add(b.get('tool_use_id'))
print(len(u-r))
PY
}
n=0
while kill -0 "$PID" 2>/dev/null; do
  p=$(pending)
  if [ "$p" = "0" ]; then
    sleep 1; [ "$(pending)" = "0" ] || continue
    log "quiescent (0 pending tool calls); SIGTERM $PID"; kill -TERM "$PID"; break
  fi
  n=$((n+1)); [ $((n%30)) -eq 1 ] && log "waiting: $p tool call(s) in flight"
  sleep 2
done
for _ in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then log "pid $PID still alive after SIGTERM grace; SIGKILL by pid"; kill -KILL "$PID"; sleep 2; fi
kill -0 "$PID" 2>/dev/null && { log "FAIL old pid $PID still alive"; exit 3; }
log "old pid $PID exited; unit $OLD: $(systemctl --user is-active "$OLD" 2>&1)"
systemctl --user reset-failed "$OLD" 2>/dev/null
PROMPT="Continuation after a controlled effort transition (Joe approved xhigh default, 11-06 11:2x PM, relayed by Hermes). You are the SAME session ($SID); your earlier turns, evidence, helpers' results and files are preserved. Your launch effort is now xhigh; use max only for a specific unresolved gap that you record in the ledger first. Do not start a fresh investigation and do not duplicate work already done: read your own last steps, then continue the original task (Skill 5whysandrhyme deliverables 1-5 in ~/wintermute-operations/work-stoppage-fivewhys-task-20261106.md, which now says Fable/xhigh). Facts since your last turns: ctl itself now runs Sonnet 5.5 (Joe: stop Fable on ctl, approvals #245), the event bridge router is installed and independently verified (proof ~/wintermute-operations/ctl-pre-fable-routing-proof-20261106.json, all six booleans true), the bridge recovery proof ~/wintermute-operations/ctl-event-recovery-proof-20261106.json is owned by the running Sonnet verifier. Use completion signals; no periodic Fable status jobs; no caps."
systemd-run --user --unit="$NEW" --collect -p RuntimeMaxSec=infinity -p MemoryMax=infinity -p MemoryHigh=infinity -p TasksMax=infinity -p WorkingDirectory="$HOME" -p StandardOutput=append:$HOME/wintermute-operations/work-stoppage-fivewhys-20261106.jsonl -p StandardError=append:$HOME/wintermute-operations/work-stoppage-fivewhys-20261106.stderr \
  /usr/bin/bash -c '"$HOME/.local/bin/fable-launch.sh" -p "$1" --resume "$2" --model claude-fable-5-1 --effort xhigh --allowedTools Skill Read Write Edit Bash Agent Glob Grep --output-format stream-json --verbose; rc=$?; "$HOME/.local/bin/ctl-analysis-done-notify.sh" "$2" "$rc"; exit $rc' _ "$PROMPT" "$SID" 
log "new unit $NEW launched rc=$?"
