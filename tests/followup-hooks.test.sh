#!/usr/bin/env bash
# follow-up tracker parts D + E (approvals #114): SessionStart prints a seat's owed ids; the Stop gate refuses a sweep that ends with an uncited
# overdue id; ctl is checked against every seat. wm-decide is a fixture (the part-A contract), never the live ledger; state lives under a tmp dir.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="${FUP_TEST_TMP:-/mnt/data/hand/tmp-fupD}"; mkdir -p "$base"
tmp="$(mktemp -d -p "$base")"; trap 'rm -rf "$tmp"' EXIT
fail=0; pass=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
SS="$here/.claude/hooks/seat-context-start.sh"; GATE="$here/.claude/hooks/followup-stop-gate.sh"
bash -n "$SS" && bash -n "$GATE" && bash -n "$here/.claude/hooks/followup-lib.sh" && bash -n "$here/.local/bin/seat-tick.sh"; chk "bash -n hooks, lib, seat-tick" $?
[ -x "$GATE" ]; chk "followup-stop-gate.sh executable" $?

# fake wm-decide: `followups --json [--agent X]` over $FU_FIXTURE (a list of id objects), the part-A shape
cat >"$tmp/wm-decide" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = followups ] || exit 2
agent=""; [ "${3:-}" = --agent ] && agent="$4"
[ -n "${FU_FAIL:-}" ] && exit "$FU_FAIL"
[ -n "${FU_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
jq -c --arg a "$agent" '[.[] | select($a=="" or .owner==$a)] as $i | {owed:($i|length), overdue:([$i[]|select(.state=="overdue")]|length), escalated:([$i[]|select(.state=="escalated")]|length), oldest:($i[0].id // ""), by_agent:($i|group_by(.owner)|map({(.[0].owner):length})|add // {}), ids:$i}' "$FU_FIXTURE"
FAKE
chmod +x "$tmp/wm-decide"
export WM_DECIDE_BIN="$tmp/wm-decide" FU_FIXTURE="$tmp/fix.json" HOME="$tmp/home" SEATS_TABLE="$tmp/none.tsv" FOLLOWUP_STOP_FIRES_LOG="$tmp/state/fires.log"
mkdir -p "$HOME"; unset TMUX
echo '[{"id":"d-rb01","owner":"rb","age_h":3.1,"state":"owed"},{"id":"d-r701","owner":"r7","age_h":30.5,"state":"overdue"}]' >"$FU_FIXTURE"

# a. SessionStart
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"
grep -qF 'FOLLOW-UPS OWED (seat rb): 1 owed, 0 overdue: d-rb01 3.1h owed' <<<"$o"; chk "a: seat rb SessionStart prints its owed id" $?
! grep -q 'd-r701' <<<"$o"; chk "a: seat rb does not see r7's id" $?
o="$(WM_SEAT=r7 bash "$SS" 2>&1 </dev/null)"
grep -qF 'FOLLOW-UPS OWED (seat r7): 1 owed, 1 overdue: d-r701 30.5h overdue' <<<"$o" && ! grep -q 'd-rb01' <<<"$o"; chk "a: seat r7 sees only its own overdue id" $?
many="$(jq -nc '[range(0;12) | {id:("d-m\(.)"),owner:"rb",age_h:1,state:"owed"}]')"; echo "$many" >"$FU_FIXTURE"
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null | grep 'FOLLOW-UPS')"
grep -q 'd-m9 1h owed and 2 more$' <<<"$o" && ! grep -q 'd-m10' <<<"$o"; chk "a: capped at 10 ids + 'and 2 more'" $?
echo '[]' >"$FU_FIXTURE"
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; ! grep -q 'FOLLOW-UPS\|unmeasured' <<<"$o"; chk "a: nothing owed -> silent" $?
# d. SessionStart unmeasured
o="$(WM_DECIDE_BIN="$tmp/missing" WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"
grep -q '^follow-ups: unmeasured (.*absent)' <<<"$o"; chk "d: WM_DECIDE_BIN missing -> SessionStart prints unmeasured" $?
o="$(FU_FAIL=3 WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; grep -q '^follow-ups: unmeasured (exit 3)' <<<"$o"; chk "d: non-zero exit -> unmeasured (exit 3)" $?
o="$(FU_GARBAGE=1 WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; grep -q '^follow-ups: unmeasured (non-JSON output)' <<<"$o"; chk "d: non-JSON -> unmeasured" $?

# transcripts: a user prompt, then a turn with assistant text and an optional tool_use command
mk_tr() {  # mk_tr <file> <final text> [bash command]
  : >"$1"
  jq -nc '{type:"user",message:{role:"user",content:"old prompt d-r701"}}' >>"$1"
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"old turn mentions d-r701"}]}}' >>"$1"
  jq -nc '{type:"user",message:{role:"user",content:"sweep now"}}' >>"$1"
  [ -n "${3:-}" ] && { jq -nc --arg c "$3" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >>"$1"
    jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"x",content:"ok"}]}}' >>"$1"; }
  jq -nc --arg t "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >>"$1"
}
stop() { jq -nc --arg t "$TR" --arg s "${SA:-false}" --arg sid "${SID:-s1}" '{session_id:$sid,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:($s=="true")}' | bash "$GATE"; }
echo '[{"id":"d-r701","owner":"rb","age_h":30.5,"state":"overdue"}]' >"$FU_FIXTURE"; TR="$tmp/t.jsonl"; mkdir -p "$tmp/state"; : >"$FOLLOWUP_STOP_FIRES_LOG"

# b / c
mk_tr "$TR" "STATUS: all quiet"
o="$(WM_SEAT=rb stop)"
jq -e '.decision=="block" and (.reason|test("d-r701")) and ((.reason|split("\n")|length)==1)' <<<"$o" >/dev/null; chk "b: overdue id not in this turn -> refused, one-line reason names it" $?
grep -q 'FOLLOWUP-STOP-REFUSED seat=rb' "$tmp/state/fires.log"; chk "b: refusal logged to the fires log" $?
mk_tr "$TR" "STATUS: all quiet" "/home/jsy/.local/bin/rb-row.sh --decision d-r701 --note done"
o="$(WM_SEAT=rb stop)"; [ -z "$o" ]; chk "c: id cited in an rb-row.sh command of this turn -> allowed" $?
mk_tr "$TR" "STATUS: handled d-r701 with a row"
o="$(WM_SEAT=rb stop)"; [ -z "$o" ]; chk "c: full id in the final turn text -> allowed" $?
mk_tr "$TR" "STATUS: quiet" "wm-decide list --pending | grep d-r701"
o="$(WM_SEAT=rb stop)"; jq -e '.decision=="block"' <<<"$o" >/dev/null; chk "c: a read command naming the id does not count as a citation" $?
mk_tr "$TR" "STATUS: quiet"   # d-r701 only in the PREVIOUS turn (mk_tr puts it there)
o="$(WM_SEAT=rb stop)"; jq -e '.decision=="block"' <<<"$o" >/dev/null; chk "c: a mention in an earlier turn does not count" $?
echo '[{"id":"d-esc9","owner":"rb","age_h":80,"state":"escalated"},{"id":"d-own1","owner":"rb","age_h":2,"state":"owed"}]' >"$FU_FIXTURE"
o="$(WM_SEAT=rb stop)"; jq -e '.decision=="block" and (.reason|test("d-esc9")) and (.reason|test("d-own1")|not)' <<<"$o" >/dev/null; chk "b: an escalated id blocks, an merely owed one does not" $?
echo '[{"id":"d-own1","owner":"rb","age_h":2,"state":"owed"}]' >"$FU_FIXTURE"
o="$(WM_SEAT=rb stop)"; [ -z "$o" ]; chk "b: only owed (not overdue) ids -> allowed" $?
echo '[{"id":"d-r701","owner":"rb","age_h":30.5,"state":"overdue"}]' >"$FU_FIXTURE"

# d. Stop fails open
o="$(WM_DECIDE_BIN="$tmp/missing" WM_SEAT=rb stop)"; rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && grep -q 'FOLLOWUP-STOP-ALLOW unmeasured seat=rb' "$tmp/state/fires.log"; chk "d: WM_DECIDE_BIN missing -> Stop allows and logs unmeasured" $?
o="$(FU_GARBAGE=1 WM_SEAT=rb stop)"; [ -z "$o" ]; chk "d: non-JSON tracker output -> Stop allows" $?

# e. cap: two refusals, the third Stop passes with an OVERRIDE row
mk_tr "$TR" "STATUS: quiet"; : >"$tmp/state/fires.log"; SID=cap1
SA=false; o1="$(WM_SEAT=rb stop)"; SA=true; o2="$(WM_SEAT=rb stop)"; o3="$(WM_SEAT=rb stop)"; SA=false
jq -e '.decision=="block"' <<<"$o1" >/dev/null && jq -e '.decision=="block"' <<<"$o2" >/dev/null && [ -z "$o3" ]; chk "e: refused twice, third Stop with stop_hook_active allows" $?
grep -q 'FOLLOWUP-STOP-OVERRIDE seat=rb n=1 ids=d-r701' "$tmp/state/fires.log"; chk "e: FOLLOWUP-STOP-OVERRIDE logged with the id" $?
o="$(WM_SEAT=rb stop)"; jq -e '.decision=="block"' <<<"$o" >/dev/null; chk "e: the next turn's first Stop is gated again" $?
unset SID

# f. ctl covers every seat
echo '[{"id":"d-r7x1","owner":"r7","age_h":40,"state":"overdue"}]' >"$FU_FIXTURE"; mk_tr "$TR" "STATUS: quiet"
o="$(WM_SEAT=ctl stop)"; jq -e '.decision=="block" and (.reason|test("d-r7x1"))' <<<"$o" >/dev/null; chk "f: ctl with an uncited r7 overdue id -> refused" $?
o="$(WM_SEAT=rb stop)"; [ -z "$o" ]; chk "f: rb is not gated on r7's id" $?
mk_tr "$TR" "STATUS: quiet" "rb-row.sh --seat ctl CONFIRM d-r7x1"
o="$(WM_SEAT=ctl stop)"; [ -z "$o" ]; chk "f: ctl citing the r7 id in a row command -> allowed" $?

# g. no WM_SEAT, subagents, foreign sid
mk_tr "$TR" "STATUS: quiet"
o="$(env -u WM_SEAT bash -c 'jq -nc --arg t "$1" "{session_id:\"s1\",transcript_path:\$t,stop_hook_active:false}" | bash "$2"' _ "$TR" "$GATE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$o" ]; chk "g: no WM_SEAT -> exit 0, silent" $?
o="$(jq -nc --arg t "$TR" '{session_id:"s1",agent_id:"a1",transcript_path:$t}' | WM_SEAT=rb bash "$GATE" 2>&1)"; [ -z "$o" ]; chk "g: a subagent call is never gated" $?
echo '[{"id":"d-r701","owner":"rb","age_h":30.5,"state":"overdue"}]' >"$FU_FIXTURE"
printf 'rb\toperator\tsid-real\t30\n' >"$tmp/seats.tsv"
o="$(SEATS_TABLE="$tmp/seats.tsv" SID=sid-coder WM_SEAT=rb stop)"; [ -z "$o" ]; chk "g: a child session that inherited WM_SEAT=rb (sid differs from seats.tsv) is not gated" $?
o="$(SEATS_TABLE="$tmp/seats.tsv" SID=sid-real WM_SEAT=rb stop)"; jq -e '.decision=="block"' <<<"$o" >/dev/null; chk "g: the seat's own sid in seats.tsv is gated" $?
o="$(env -u WM_SEAT bash "$SS" 2>&1 </dev/null)"; [ -z "$o" ]; chk "g: SessionStart without WM_SEAT/tmux stays silent" $?

# registration
S="$here/.claude/settings.json"
n="$(jq -r '[.hooks.Stop[] | select(.matcher=="") | .hooks[] | select(.type=="command" and .command=="/home/jsy/.claude/hooks/followup-stop-gate.sh")] | length' "$S")"
[ "$n" = 1 ]; chk "followup-stop-gate.sh registered once under Stop (matcher \"\", same shape as seat-ask-inject.sh)" $?
[ "$(grep -c 'followup-stop-gate\|followup-lib\|D1\|D2\|^- \*\*E ' "$here/docs/mechanisms.md")" -ge 3 ]; chk "docs/mechanisms.md has the D1, D2 and E lines" $?
echo "followup-hooks: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
