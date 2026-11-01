#!/usr/bin/env bash
# answers-first.sh: Joe 10-31 11:5x PM "always answers first then action" (approvals #185, CLAUDE.md § Output ANSWERS FIRST).
# PreToolUse on the aide (WM_SEAT=aide): when the newest Joe message in the transcript contains a question mark and no assistant
# text has been emitted after it, the tool call is denied with the reason "answer first". Sweep prompts and seat lines never count.
set -u
[ "${WM_SEAT:-}" = aide ] || [ "${ANSWERS_FIRST_FORCE:-}" = 1 ] || exit 0
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
  rm -rf "$d"; echo "selftest: 4 PASS"; exit 0
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
        if not txt or txt.startswith(("AIDE SWEEP","<system-reminder>","[Monitor","<task-notification","[SYSTEM")): continue
        if "?" in txt: q=txt[:80]; answered=False
        else: q=None
    elif t=="assistant" and q is not None:
        if isinstance(c,list) and any(isinstance(x,dict) and x.get("type")=="text" and x.get("text","").strip() for x in c): answered=True
if q is not None and not answered:
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"answer first (Joe 10-31 #185): reply to '%s' in text before any tool call" % q}}))
PY
