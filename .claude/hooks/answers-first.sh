#!/usr/bin/env bash
# answers-first.sh: Joe 10-31 11:5x PM "always answers first then action" (approvals #185, CLAUDE.md § Output ANSWERS FIRST).
# PreToolUse on the carbon executor seat (WM_SEAT=aide or ctl): when the newest Joe message in the transcript contains a question mark and no assistant
# text has been emitted after it (12:1x AM: any Joe message, not only a question), the tool call is denied with the reason "answer first". Sweep prompts and seat lines never count.
set -u
case "${WM_SEAT:-}" in aide|ctl) ;; *) [ "${ANSWERS_FIRST_FORCE:-}" = 1 ] || exit 0 ;; esac
if [ "${1:-}" = --selftest ]; then
  d=$(mktemp -d); t="$d/t.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"why is the dash wrong?"}}' > "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); echo "$r" | grep -q '"deny"' && echo "PASS question-no-answer denies" || { echo "FAIL 1: $r"; exit 1; }
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Because the tile reads a stale field."}]}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); [ -z "$r" ] && echo "PASS answered then tool allowed" || { echo "FAIL 2: $r"; exit 1; }
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"AIDE SWEEP (cron). what kills this in the next hour?"}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); [ -z "$r" ] && echo "PASS sweep prompt exempt" || { echo "FAIL 3: $r"; exit 1; }
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok?"}]}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); [ -z "$r" ] && echo "PASS tool_result ignored" || { echo "FAIL 4: $r"; exit 1; }
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"i expect you to respond"}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); echo "$r" | grep -q '"deny"' && echo "PASS statement-no-reply denies" || { echo "FAIL 5: $r"; exit 1; }
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Responding."}]}}' >> "$t"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"Stop hook feedback:\nOWED NOW (seat aide, 17 row(s)): each row is done this turn"}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); [ -z "$r" ] && echo "PASS stop-hook feedback ignored" || { echo "FAIL 6: $r"; exit 1; }
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context. did you resume everything?"}}' >> "$t"
  r=$(printf '{"transcript_path":"%s","tool_name":"Bash"}' "$t" | ANSWERS_FIRST_FORCE=1 bash "$0"); [ -z "$r" ] && echo "PASS compaction summary ignored" || { echo "FAIL 7: $r"; exit 1; }
  rm -rf "$d"; echo "selftest: 7 PASS"; exit 0
fi
inp=$(cat); tp=$(printf '%s' "$inp" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0
python3 -I - "$tp" <<'PY'
import sys,json
q=None; answered=False
for ln in open(sys.argv[1],encoding="utf-8",errors="replace"):
    try: d=json.loads(ln)
    except Exception: continue
    m=d.get("message") or {}; c=m.get("content"); t=d.get("type")
    if t=="user":
        if isinstance(c,str): txt=c
        elif isinstance(c,list): txt=" ".join(x.get("text","") for x in c if isinstance(x,dict) and x.get("type")=="text")
        else: txt=""
        txt=txt.strip()
        if d.get("isMeta"): continue
        # 11-01 12:4x AM: Stop-hook feedback and the compaction summary are synthetic user entries; counting them deadlocked the aide for 15 min
        if not txt or txt.startswith(("AIDE SWEEP","<system-reminder>","[Monitor","<task-notification","[SYSTEM","Stop hook feedback:",
                                      "This session is being continued from a previous conversation","[Request interrupted","<command-name>","<local-command",
                                      "UserPromptSubmit hook","PreToolUse hook","Stop hook blocking")): continue
        q=txt[:80]; answered=False   # Joe 11-01 12:1x AM: every Joe message, question or statement, gets a reply first
    elif t=="assistant" and q is not None:
        if isinstance(c,list) and any(isinstance(x,dict) and x.get("type")=="text" and x.get("text","").strip() for x in c): answered=True
if q is not None and not answered:
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"answer first (Joe 10-31 #185): reply to Joe's message '%s' in text before any tool call" % q}}))
PY
