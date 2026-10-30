#!/usr/bin/env bash
# never-ask-joe.test.sh: .claude/hooks/never-ask-joe.sh (approvals #80). Stop blocks ask lines under WM_SEAT; allows everything else.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/.claude/hooks/never-ask-joe.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/naj.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export NAJ_STATE_DIR="$tmp/state"
log="$NAJ_STATE_DIR/fires.log"
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
nlog() { [ -f "$log" ] && wc -l <"$log" | tr -d ' ' || echo 0; }

# transcript <file> <text>: one user line, one assistant line with the text, one user tool_result line last
transcript() {
  jq -nc --arg t "$2" '{type:"user",message:{role:"user",content:"go"}}' >"$1"
  jq -nc --arg t "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >>"$1"
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"x",content:"ok"}]}}' >>"$1"
}
stop_in() { jq -nc --arg p "$1" --argjson a "${2:-false}" '{hook_event_name:"Stop",transcript_path:$p,stop_hook_active:$a}'; }

# expect <name> <block|allow> <seat|-> <transcript> [stop_hook_active]
expect() {
  local name="$1" want="$2" seat="$3" tr="$4" act="${5:-false}" before out rc after
  before=$(nlog)
  if [ "$seat" = "-" ]; then out=$(stop_in "$tr" "$act" | env -u WM_SEAT bash "$hook" 2>/dev/null); rc=$?
  else out=$(stop_in "$tr" "$act" | WM_SEAT="$seat" bash "$hook" 2>/dev/null); rc=$?; fi
  after=$(nlog)
  if [ "$rc" -ne 0 ]; then bad "$name (rc=$rc)"; return; fi
  if [ "$want" = block ]; then
    if jq -e '.decision=="block" and (.reason|startswith("NEVER ASK JOE (approvals #80)"))' <<<"$out" >/dev/null 2>&1 \
       && [ $((after-before)) -eq 1 ] && tail -n1 "$log" | grep -qE "^[0-9T:+-]+ \| $seat \| stop \| ."; then ok "$name"; else bad "$name (out=[$out] newlines=$((after-before)))"; fi
  else
    if [ -z "$out" ] && [ "$after" -eq "$before" ]; then ok "$name"; else bad "$name (out=[$out] newlines=$((after-before)))"; fi
  fi
}
t() { transcript "$tmp/t.jsonl" "$1"; echo "$tmp/t.jsonl"; }

# blocks under WM_SEAT=rb
expect "block: reply yes"            block rb "$(t 'Next: reply "yes" for the fstab change')"
expect "block: want me to"           block rb "$(t 'Want me to redrive 1068?')"
expect "block: should I"             block rb "$(t 'Should I merge?')"
expect "block: needs Joes word"      block rb "$(t "This needs Joe's word.")"
expect "block: would you like"       block rb "$(t 'Would you like me to land it?')"
expect "block: keyword w/o not-done" block rb "$(t 'Token spend is fine. Want me to redrive 1068?')"
expect "block: seared not-done line plus unrelated ask" block rb "$(t "$(printf 'Not done: raising the cost limit needs Joe'"'"'s word (seared class)\nStatus: 3 runs open.\nShould I redrive 1068?')")"

# allows
expect "allow: not-done form same line" allow rb "$(t "Not done: raising the cost limit needs Joe's word (seared class)")"
expect "allow: plain STATUS"            allow rb "$(t $'STATUS 10:52 PM\nTask: hook build.\nState: tests green.\nNext: commit.')"
expect "allow: WM_SEAT unset"           allow -  "$(t 'Want me to redrive 1068?')"
expect "allow: stop_hook_active"        allow rb "$(t 'Should I merge?')" true

# AskUserQuestion
before=$(nlog)
out=$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",tool_input:{}}' | WM_SEAT=aide bash "$hook" 2>/dev/null)
if jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|startswith("NEVER ASK JOE"))' <<<"$out" >/dev/null 2>&1 \
   && [ $(( $(nlog)-before )) -eq 1 ] && tail -n1 "$log" | grep -qE " \| aide \| askuser \| "; then ok "askuser: aide -> deny + one log line"; else bad "askuser: aide -> deny (out=[$out])"; fi
before=$(nlog)
out=$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",tool_input:{}}' | env -u WM_SEAT bash "$hook" 2>/dev/null)
if [ -z "$out" ] && [ "$(nlog)" -eq "$before" ]; then ok "askuser: WM_SEAT unset -> silent"; else bad "askuser: WM_SEAT unset (out=[$out])"; fi
before=$(nlog)
out=$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls"}}' | WM_SEAT=rb bash "$hook" 2>/dev/null)
if [ -z "$out" ] && [ "$(nlog)" -eq "$before" ]; then ok "other tool under WM_SEAT -> silent"; else bad "other tool (out=[$out])"; fi

# transcript shapes: ask in an earlier assistant entry, last line is a user/tool_result (covered by t()); multiple text blocks + tool_use
f="$tmp/multi.jsonl"
{ jq -nc '{type:"user",message:{role:"user",content:"go"}}'
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Should I stop? (older entry, not the last)"}]}}'
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"x",content:"ok"}]}}'
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Built the hook."},{type:"tool_use",id:"x",name:"Bash",input:{command:"echo Should I merge?"}},{type:"text",text:"Reply \"go\" to land."}]}}'
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"x",content:"ok"}]}}'; } >"$f"
expect "block: multi text blocks, last line tool_result" block rb "$f"
f="$tmp/multi2.jsonl"
{ jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Should I stop? (older)"}]}}'
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Done. Tests green."},{type:"tool_use",id:"x",name:"Bash",input:{command:"echo Should I merge?"}}]}}'
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"x",content:"Want me to?"}]}}'; } >"$f"
expect "allow: only the LAST assistant entry counts, tool_use ignored" allow rb "$f"

# malformed transcript: exit 0, no block, one parse-error line
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Should I merge?"}]}}\n{not json\n' >"$tmp/bad.jsonl"
before=$(nlog)
out=$(stop_in "$tmp/bad.jsonl" | WM_SEAT=rb bash "$hook" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ $(( $(nlog)-before )) -eq 1 ] && tail -n1 "$log" | grep -q "parse-error"; then ok "malformed transcript: fail open + parse-error logged"; else bad "malformed transcript (rc=$rc out=[$out])"; fi

# missing transcript
before=$(nlog)
out=$(stop_in "$tmp/nope.jsonl" | WM_SEAT=rb bash "$hook" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ $(( $(nlog)-before )) -eq 1 ] && tail -n1 "$log" | grep -q "transcript-missing"; then ok "missing transcript: fail open + transcript-missing logged"; else bad "missing transcript (rc=$rc out=[$out])"; fi

# log never holds message text beyond the phrase
if ! grep -qE "fstab|1068|redrive" "$log"; then ok "fires.log holds no message text beyond the matched phrase"; else bad "fires.log leaks message text"; fi

# settings wiring
s="$here/.claude/settings.json"
jq -e '[.hooks.Stop[].hooks[].command | select(endswith("never-ask-joe.sh"))] | length >= 1' "$s" >/dev/null && ok "settings: Stop entry" || bad "settings: Stop entry"
jq -e '[.hooks.PreToolUse[] | select(.matcher=="AskUserQuestion") | .hooks[].command | select(endswith("never-ask-joe.sh"))] | length >= 1' "$s" >/dev/null && ok "settings: PreToolUse AskUserQuestion entry" || bad "settings: PreToolUse entry"

echo "never-ask-joe.test.sh: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
