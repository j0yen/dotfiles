#!/usr/bin/env bash
# analysis-route AC 1 (A1300 E13 R6): every row of the PRD's page-gate table (A1-A8 admit, B1-B19 refuse), built as its caption states,
# exits 0 or 2 within the 4 s budget, every refusal of a new page follows R6's message rule, and admit row A1 exits 2 on the vendored
# f9066716 gate. Rows A1-A4 and A7 (and A8, B7, B14) take their launch row from a decisions log the real fable-launch.sh writes under
# FABLE_LAUNCH_TEST=1 with the spy CLI and a pre-drawn session id; the other rows change one field of such a row with jq (the launcher's
# field shapes: reasons one string). A subagent's write gives the hook input its agent_id. Rows A7, B12, B14 and B16 run with an 8 MB main
# transcript and 50 subagent files totalling at least 8 MB. A1, A7, B11, B12, B15 and B19 also run as a Bash create of the same new page
# (disposition F33); two decoys separate a gate that scans other transcripts (F34). Private HOME, decisions logs, markers, wiki and
# transcripts. From R (AR_ROOT): the gate. From this checkout: the launcher, resolver and policy that write the rows.
# Run alone: bash tests/analysis-route_ac01_page_gate.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
G="$R/.claude/hooks/analysis-page-gate.sh"
ck "vendored f9066716 gate, resolver and policy present with their full sha256 digests (missing or changed = FAIL)" 'ar_fixtures_ok'
now_ms(){ local t=${EPOCHREALTIME//[!0-9]/}; echo $((t / 1000)); }

# --- launch rows from the real launcher (this checkout's launcher, resolver and policy; spy CLI; pre-drawn session ids)
ar_launcher_env "$D"
OPX='"requested":{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}'
S1="$(uuid)"; S4="$(uuid)"; S8="$(uuid)"; S7="$(uuid)"
ar_launch L1 '{"task_id":"AR1-A1","skill":"wwhtbt","decision_class":"unresolved_consequential","evidence_refs":'"$EVJ"','"$OPX"'}' --session-id "$S1" -p x
ar_launch L4 '{"task_id":"AR1-A4","skill":"5whysandrhyme","decision_class":"consequential_prevention","evidence_refs":'"$EVJ"','"$OPX"'}' --session-id "$S4" -p x
ar_launch L8 '{"task_id":"AR1-A8","skill":"wwhtbt","decision_class":"unresolved_consequential","evidence_refs":'"$EVJ"'}' --session-id "$S8" -p x
ar_launch L7 '{"task_id":"AR1-B7","skill":"wwhtbt"}' --session-id "$S7" -p x
lrow(){ jq -R -c 'fromjson? | objects | select(.decision=="launch")' "$T/new.$1" | tail -1; }
ROW1=$(lrow L1); ROW4=$(lrow L4); ROW8=$(lrow L8); ROW7=$(lrow L7)
ck "launcher row (A1): S1 author wwhtbt opus-xhigh claude-opus-5-5, reasons one string recording the requested alternate" 'jq -e --arg s "$S1" ".session==\$s and .role==\"author\" and .skill==\"wwhtbt\" and .route==\"opus-xhigh\" and .model==\"claude-opus-5-5\" and (.reasons|type)==\"string\" and (.reasons|contains(\"requested alternate opus-xhigh for fable-xhigh\"))" <<<"$ROW1" >/dev/null 2>&1'
ck "launcher row (A4): S4 author 5whysandrhyme opus-xhigh claude-opus-5-5 with the alternate reason" 'jq -e --arg s "$S4" ".session==\$s and .role==\"author\" and .skill==\"5whysandrhyme\" and .model==\"claude-opus-5-5\" and (.reasons|contains(\"requested alternate\"))" <<<"$ROW4" >/dev/null 2>&1'
ck "launcher rows (A8/B14 default fable-xhigh, B7 default sonnet-medium) record no requested alternate" 'jq -e --arg s "$S8" ".session==\$s and .route==\"fable-xhigh\" and .model==\"claude-fable-5-1\" and (.reasons|contains(\"requested alternate\")|not)" <<<"$ROW8" >/dev/null 2>&1 && jq -e --arg s "$S7" ".session==\$s and .route==\"sonnet-medium\" and .model==\"claude-sonnet-5-5\" and (.reasons|contains(\"requested alternate\")|not)" <<<"$ROW7" >/dev/null 2>&1'
unset FABLE_LAUNCH_TEST SKILL_ROUTE_POLICY SKILL_ROUTING_DECISIONS SKILL_ROUTE_LEDGER_IDS   # every gate run below gets a clean env (env -i)

# --- filler for the timed rows: an 8 MB main transcript (2000 lines) and 50 subagent files totalling >= 8 MB, none holding the tested id
python3 -I - "$T/filler" <<'PY'
import json, os, sys
d = sys.argv[1]; os.makedirs(d + "/subagents", exist_ok=True)
def line(i, agent=None):
    if i % 2:
        o = {"type": "user", "isSidechain": bool(agent), "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_filler_%06d" % (i - 1), "content": "r" * 4300}]}}
    else:
        o = {"type": "assistant", "isSidechain": bool(agent), "message": {"model": "claude-opus-5-5", "role": "assistant", "content": [{"type": "text", "text": "t" * 4100}, {"type": "tool_use", "id": "toolu_filler_%06d" % i, "name": "Read", "input": {"file_path": "/x"}}]}}
    if agent: o["agentId"] = agent
    return json.dumps(o)
with open(d + "/main.jsonl", "w") as f:
    for i in range(2000): f.write(line(i) + "\n")
for a in range(50):
    with open(d + "/subagents/agent-filler%02d.jsonl" % a, "w") as f:
        for i in range(42): f.write(line(i, "filler%02d" % a) + "\n")
PY
MB=$(( $(stat -c %s "$T/filler/main.jsonl") / 1048576 )); SUBB=$(cat "$T/filler/subagents"/*.jsonl | wc -c)
ck "timed-row filler: main transcript >= 8 MB in 2000 lines, 50 subagent files totalling >= 8 MB" '[ "$(stat -c %s "$T/filler/main.jsonl")" -ge 8388608 ] && [ "$(wc -l <"$T/filler/main.jsonl")" = 2000 ] && [ "$(ls "$T/filler/subagents" | wc -l)" = 50 ] && [ "$SUBB" -ge 8388608 ]'

# --- scenario helpers: sc NAME SESSION [timed] makes a private HOME, marker dir, wiki, transcripts and decisions log
sc(){ SC="$T/sc/$1"; SS="$2"; mkdir -p "$SC/home" "$SC/marks" "$SC/wiki/decisions" "$SC/wiki/answers" "$SC/proj/$SS/subagents"
  MAIN="$SC/proj/$SS.jsonl"; LOG="$SC/dec.jsonl"; : >"$LOG"; TU="toolu_ar1_$1"; PAGE="$SC/wiki/decisions/2026-11-18-ar1-$1-wwhtbt.md"
  if [ "${3:-}" = timed ]; then cp "$T/filler/main.jsonl" "$MAIN"; cp "$T/filler/subagents"/*.jsonl "$SC/proj/$SS/subagents/"; else : >"$MAIN"; fi; }
mark(){ touch "$SC/marks/$1.${2:-$SS}"; }
logrow(){ printf '%s\n' "$1" >>"$LOG"; }
tu_line(){ jq -nc --arg m "$1" --arg id "$2" --arg p "$PAGE" --arg s "$SS" --arg a "${3:-}" '{parentUuid:null,isSidechain:($a!=""),type:"assistant",timestamp:"2026-11-18T23:00:00.000Z",sessionId:$s,
  message:{id:"msg_ar1",type:"message",role:"assistant",model:$m,content:[{type:"text",text:"writing the page"},{type:"tool_use",id:$id,name:"Write",input:{file_path:$p,content:"x"}}]}}
  + (if $a=="" then {} else {agentId:$a} end)'; }
main_tu(){ tu_line "$1" "${2:-$TU}" >>"$MAIN"; }
sub_tu(){ tu_line "$2" "${3:-$TU}" "$1" >>"$SC/proj/$SS/subagents/agent-$1.jsonl"; }
# hin TOOL [AGENT]: the hook input (a subagent's call carries agent_id and agent_type; its transcript_path is the main session's)
hin(){ jq -nc --arg tool "$1" --arg a "${2:-}" --arg s "$SS" --arg t "$MAIN" --arg id "$TU" --arg p "$PAGE" '{session_id:$s,transcript_path:$t,cwd:"/tmp",
  permission_mode:"default",hook_event_name:"PreToolUse",tool_name:$tool,tool_use_id:$id,
  tool_input:(if $tool=="Write" then {file_path:$p,content:"x"} else {command:("cat > " + $p + " <<'"'"'X'"'"'"), description:"write page"} end)}
  + (if $a=="" then {} else {agent_id:$a,agent_type:"general-purpose"} end)'; }
# gate ID TOOL AGENT [VAR=VAL...]: run the gate under test with a clean environment; rc in RC_<ID>, stderr in $T/err.ID, ms in MS_<ID>
GATE="$G"; ALLMS=""
gate(){ local id="$1" tool="$2" ag="$3" s e; shift 3; hin "$tool" "$ag" >"$T/in.$id"
  s=$(now_ms); env -i PATH="$PATH" HOME="$SC/home" ANALYSIS_WIKI_DIR="$SC/wiki" SKILL_MARKER_DIR="$SC/marks" SKILL_ROUTING_DECISIONS="$LOG" "$@" bash "$GATE" <"$T/in.$id" >/dev/null 2>"$T/err.$id"
  printf -v "RC_${id//-/_}" '%s' "$?"; e=$(now_ms); printf -v "MS_${id//-/_}" '%s' "$((e - s))"; ALLMS="$ALLMS $id:$((e - s))"; }
rc(){ local v="RC_${1//-/_}"; printf '%s' "${!v:-x}"; }
ms(){ local v="MS_${1//-/_}"; printf '%s' "${!v:-99999}"; }
msg(){ grep -qF -- "--route-request" "$T/err.$1" && grep -qF "requested.route" "$T/err.$1" && ! grep -qF "model=fable" "$T/err.$1"; }
found(){ grep -qF "turn model: $2 (found in the $3 transcript" "$T/err.$1"; }
unknown(){ grep -qF "turn model: unknown (" "$T/err.$1" && grep -qF "$2" "$T/err.$1"; }
both(){ gate "$1-W" Write "$2" "${@:3}"; gate "$1-B" Bash "$2" "${@:3}"; }   # F33: the same row as a Write and as a Bash create

# --- admit rows
sc A1 "$S1"; logrow "$ROW1"; mark wwhtbt; main_tu "$OPUS"; both A1 ""
ck "A1 fresh marker; row: author, wwhtbt, claude-opus-5-5, requested alternate; Opus turn -> 0 (Write and Bash)" '[ "$(rc A1-W)" = 0 ] && [ "$(rc A1-B)" = 0 ]' || cat "$T/err.A1-W"
GATE="$BGATE"; gate A1-base-W Write ""; gate A1-base-B Bash ""; GATE="$G"
ck "A1 on the vendored f9066716 gate -> 2, refusing claude-opus-5-5 (Write and Bash)" '[ "$(rc A1-base-W)" = 2 ] && [ "$(rc A1-base-B)" = 2 ] && grep -qF "claude-opus-5-5" "$T/err.A1-base-W" && grep -qF "claude-opus-5-5" "$T/err.A1-base-B"'
sc A2 "$S1"; printf '{"ts":"2026-11-18T00:00:00-08:00","decision":"launch","task_id":"AR1-A2","session":"%s"\n' "$S1" >>"$LOG"; logrow "$ROW1"; mark wwhtbt; main_tu "$OPUS"; gate A2 Write ""
ck "A2 A1 with a malformed line before the row -> 0" '[ "$(rc A2)" = 0 ]'
sc A3 "$S1"; mkdir -p "$SC/elsewhere"; printf '%s\n' "$ROW1" >"$SC/elsewhere/custom.jsonl"; mark wwhtbt; main_tu "$OPUS"
gate A3 Write "" SKILL_ROUTING_DECISIONS="$SC/elsewhere/custom.jsonl"
ck "A3 A1 with the log only at a non-default SKILL_ROUTING_DECISIONS path and none under HOME -> 0" '[ ! -e "$SC/home/.local/state/skill-routing/decisions.jsonl" ] && [ "$(rc A3)" = 0 ]'
mkdir -p "$SC/home/.local/state/skill-routing"; printf '%s\n' "$ROW1" >"$SC/home/.local/state/skill-routing/decisions.jsonl"; : >"$LOG"
gate A3-honoured Write ""
ck "control: SKILL_ROUTING_DECISIONS is honoured (an empty named log hides the row under HOME: Opus turn -> 2)" '[ "$(rc A3-honoured)" = 2 ] && msg A3-honoured'
hin Write "" >"$T/in.A3-default"
env -i PATH="$PATH" HOME="$SC/home" ANALYSIS_WIKI_DIR="$SC/wiki" SKILL_MARKER_DIR="$SC/marks" bash "$G" <"$T/in.A3-default" >/dev/null 2>"$T/err.A3-default"; RC_A3_default=$?
ck "control: without SKILL_ROUTING_DECISIONS the default log under HOME is read -> 0" '[ "$RC_A3_default" = 0 ]'
sc A4 "$S4"; PAGE="$SC/wiki/answers/2026-11-18-ar1-a4-five-whys-rhyme.md"; logrow "$ROW4"; mark 5whysandrhyme; main_tu "$OPUS"; gate A4 Write ""
ck "A4 A1 for 5whysandrhyme writing answers/*five-whys* -> 0" '[ "$(rc A4)" = 0 ]'
sc A5 "$(uuid)"; mark wwhtbt; main_tu "$FABLE"; gate A5 Write ""
GATE="$BGATE"; gate A5-base Write ""; GATE="$G"
ck "A5 fresh marker, Fable turn, no row (today's rule) -> 0, and 0 on the f9066716 gate (the A1 control's fixture is sound)" '[ "$(rc A5)" = 0 ] && [ "$(rc A5-base)" = 0 ]'
sc A6 "$S1"; logrow "$ROW1"; mark wwhtbt; main_tu "$SONNET"; : >"$PAGE"; gate A6 Write ""; gate A6-B Bash ""
ck "A6 edit of an existing page -> 0 (even from a turn that could not create it)" '[ "$(rc A6)" = 0 ] && [ "$(rc A6-B)" = 0 ]'
sc A7 "$S1" timed; logrow "$ROW1"; mark wwhtbt
for v in W B; do
  tool=Write; [ $v = B ] && tool=Bash; hin "$tool" "" >"$T/in.A7-$v"; grep -qF "$TU" "$MAIN" && echo "  A7 setup: the id is already in the transcript"
  s=$(now_ms); ( env -i PATH="$PATH" HOME="$SC/home" ANALYSIS_WIKI_DIR="$SC/wiki" SKILL_MARKER_DIR="$SC/marks" SKILL_ROUTING_DECISIONS="$LOG" bash "$G" <"$T/in.A7-$v" >/dev/null 2>"$T/err.A7-$v"; echo $? >"$T/rc.A7-$v" ) &
  bp=$!; AR_BG+=("$bp"); sleep 1; main_tu "$OPUS"; wait "$bp"; e=$(now_ms); printf -v "MS_A7_$v" '%s' "$((e - s))"; ALLMS="$ALLMS A7-$v:$((e - s))"
  sed -i '$d' "$MAIN"   # take the appended line back out for the next variant
done
ck "A7 A1 with the tool_use line appended 1 s after the hook starts (8 MB transcript, 50 subagent files) -> 0 within 4 s (Write and Bash)" '[ "$(cat "$T/rc.A7-W")" = 0 ] && [ "$(cat "$T/rc.A7-B")" = 0 ] && [ "$(ms A7-W)" -ge 1000 ] && [ "$(ms A7-W)" -lt 4000 ] && [ "$(ms A7-B)" -ge 1000 ] && [ "$(ms A7-B)" -lt 4000 ]'
sc A8 "$S8"; logrow "$ROW8"; mark wwhtbt; main_tu "$FABLE"; gate A8 Write ""
ck "A8 row: author, wwhtbt, fable-xhigh, claude-fable-5-1 (a default route); Fable turn -> 0" '[ "$(rc A8)" = 0 ]'

# --- refuse rows (each with a fresh marker unless it says otherwise; every refusal of a new page checked for the message rule)
sc B1a "$S1"; logrow "$ROW1"; main_tu "$OPUS"; gate B1a Write ""
sc B1b "$S1"; logrow "$ROW1"; mark wwhtbt "$(uuid)"; main_tu "$OPUS"; gate B1b Write ""
ck "B1 A1 without a marker, or with a marker for another session -> 2" '[ "$(rc B1a)" = 2 ] && [ "$(rc B1b)" = 2 ] && msg B1a && msg B1b'
sc B2 "$S1"; logrow "$ROW1"; mark wwhtbt; main_tu "$SONNET"; gate B2 Write ""
ck "B2 A1 with a Sonnet turn -> 2, naming claude-sonnet-5-5 in the main transcript" '[ "$(rc B2)" = 2 ] && msg B2 && found B2 "$SONNET" main'
sc B3 "$S1"; logrow "$(jq -c --arg s "$(uuid)" '.session=$s' <<<"$ROW1")"; mark wwhtbt; main_tu "$OPUS"; gate B3 Write ""
ck "B3 A1's row for another session -> 2" '[ "$(rc B3)" = 2 ] && msg B3'
sc B4 "$S1"; logrow "$ROW1"; logrow "$(jq -c '.task_id="AR1-B4" | .skill="dream" | .route="opus-high" | .effort="high" | .reasons="decision_class new_vision -> opus-high; class new_vision evidence verified"' <<<"$ROW1")"
mark wwhtbt; main_tu "$OPUS"; gate B4 Write ""
ck "B4 A1 followed by a later author row of S for dream (on the same Opus model) -> 2" '[ "$(rc B4)" = 2 ] && msg B4'
sc B5 "$S1"; logrow "$ROW1"; logrow "$(jq -c '.task_id="AR1-B5" | .route="sonnet-medium" | .model="claude-sonnet-5-5" | .effort="medium" | .reasons="no decision_class: baseline sonnet-medium"' <<<"$ROW1")"
mark wwhtbt; main_tu "$OPUS"; gate B5 Write ""
ck "B5 A1 followed by a later author row of S for wwhtbt on claude-sonnet-5-5 -> 2, naming the found claude-opus-5-5" '[ "$(rc B5)" = 2 ] && msg B5 && found B5 "$OPUS" main'
sc B6 "$S1"; logrow "$(jq -c '.role="review"' <<<"$ROW1")"; mark wwhtbt; main_tu "$OPUS"; gate B6 Write ""
ck "B6 A1's row with role review -> 2" '[ "$(rc B6)" = 2 ] && msg B6'
sc B7 "$S7"; logrow "$ROW7"; mark wwhtbt; main_tu "$SONNET"; gate B7 Write ""
ck "B7 row: author, wwhtbt, sonnet-medium, no requested alternate; Sonnet turn -> 2" '[ "$(rc B7)" = 2 ] && msg B7'
sc B8 "$S1"; mark wwhtbt; main_tu "$OPUS"; gate B8 Write "" SKILL_ROUTE_SKILL=wwhtbt SKILL_ROUTE_TASK_ID=AR1-A1 SKILL_ROUTE_ROUTE=opus-xhigh SKILL_ROUTE_SESSION="$S1" SKILL_ROUTE_ROLE=author
ck "B8 SKILL_ROUTE_SKILL/SKILL_ROUTE_TASK_ID set, no row; Opus turn -> 2" '[ "$(rc B8)" = 2 ] && msg B8'
sc B9 "$S1"; printf '{"decision":"launch","session":"%s","model":"claude-opus-5-5","reasons":"requested alternate\n' "$S1" >"$LOG"; mark wwhtbt; main_tu "$OPUS"; gate B9 Write ""
ck "B9 a log holding only a malformed line; Opus turn -> 2" '[ "$(rc B9)" = 2 ] && msg B9'
sc B10 "$S1"; logrow "$ROW1"; chmod 000 "$LOG"; mark wwhtbt; main_tu "$OPUS"; gate B10 Write ""
ck "B10 an unreadable log; Opus turn -> 2 (the log is unreadable to this user)" '[ ! -r "$LOG" ] && [ "$(rc B10)" = 2 ] && msg B10'; chmod 600 "$LOG"
sc B11 "$S1"; logrow "$ROW1"; mark wwhtbt; sub_tu sa11 "$SONNET"; both B11 sa11
ck "B11 A1 with the tool_use only in a subagent transcript on claude-sonnet-5-5 -> 2, naming it in the subagent transcript (Write and Bash)" '[ "$(rc B11-W)" = 2 ] && [ "$(rc B11-B)" = 2 ] && msg B11-W && msg B11-B && found B11-W "$SONNET" subagent && found B11-B "$SONNET" subagent'
sc B12 "$S1" timed; logrow "$ROW1"; mark wwhtbt; both B12 ""
ck "B12 A1 with the tool_use in no transcript (8 MB, 50 subagent files) -> 2 within 4 s, unknown, naming the main transcript read (Write and Bash)" '[ "$(rc B12-W)" = 2 ] && [ "$(rc B12-B)" = 2 ] && msg B12-W && msg B12-B && unknown B12-W "$MAIN" && unknown B12-B "$MAIN" && [ "$(ms B12-W)" -lt 4000 ] && [ "$(ms B12-B)" -lt 4000 ]'
sc B13 "$S1"; logrow "$(jq -c '.reasons="decision_class unresolved_consequential -> opus-xhigh; class unresolved_consequential evidence verified"' <<<"$ROW1")"; mark wwhtbt; main_tu "$OPUS"; gate B13 Write ""
ck "B13 A1's row (route opus-xhigh, claude-opus-5-5) with reasons lacking requested alternate; Opus turn -> 2" '[ "$(rc B13)" = 2 ] && msg B13'
sc B14 "$S8" timed; logrow "$ROW8"; mark wwhtbt; gate B14 Write ""
ck "B14 row: author, wwhtbt, fable-xhigh, claude-fable-5-1 (default); tool_use in no transcript (timed) -> 2 within 4 s, unknown" '[ "$(rc B14)" = 2 ] && msg B14 && unknown B14 "$MAIN" && [ "$(ms B14)" -lt 4000 ]'
sc B15 "$(uuid)"; mark wwhtbt; sub_tu sa15 "$SONNET"; both B15 sa15
GATE="$BGATE"; gate B15-base Write sa15; GATE="$G"
ck "B15 no launch row, fresh marker, tool_use only in a claude-sonnet-5-5 subagent transcript -> 2, naming it (Write and Bash); 0 on the f9066716 gate" '[ "$(rc B15-W)" = 2 ] && [ "$(rc B15-B)" = 2 ] && msg B15-W && msg B15-B && found B15-W "$SONNET" subagent && found B15-B "$SONNET" subagent && [ "$(rc B15-base)" = 0 ]'
sc B16 "$S1" timed; logrow "$(jq -c '.role="review"' <<<"$ROW1")"; mark wwhtbt; gate B16 Write ""
ck "B16 only a review-role row of S; fresh marker; tool_use in no transcript (timed) -> 2 within 4 s, unknown" '[ "$(rc B16)" = 2 ] && msg B16 && unknown B16 "$MAIN" && [ "$(ms B16)" -lt 4000 ]'
sc B17 "$S1"; logrow "$ROW1"; mark wwhtbt; touch -d '-200 min' "$SC/marks/wwhtbt.$SS"; main_tu "$OPUS"; gate B17 Write ""
ck "B17 A1 with S's marker older than SKILL_TTL_MIN (180) -> 2" '[ "$(rc B17)" = 2 ] && msg B17'
sc B18 "$S1"; PAGE="$SC/wiki/answers/2026-11-18-ar1-b18-five-whys-rhyme.md"; logrow "$ROW1"; mark 5whysandrhyme; main_tu "$OPUS"; gate B18 Write ""
ck "B18 A1's wwhtbt alternate row with a fresh 5whysandrhyme marker; an Opus turn writes a new answers/*five-whys* page -> 2" '[ "$(rc B18)" = 2 ] && msg B18'
sc B19 "$S1"; logrow "$ROW1"; mark wwhtbt; main_tu "$FABLE"; both B19m ""
sc B19s "$S1"; logrow "$ROW1"; mark wwhtbt; sub_tu sa19 "$FABLE"; both B19s sa19
ck "B19 A1's row with a claude-fable-5-1 turn, from the main thread or a subagent -> 2, naming the found Fable model (Write and Bash)" '[ "$(rc B19m-W)" = 2 ] && [ "$(rc B19m-B)" = 2 ] && [ "$(rc B19s-W)" = 2 ] && [ "$(rc B19s-B)" = 2 ] && msg B19m-W && msg B19s-B && found B19m-W "$FABLE" main && found B19m-B "$FABLE" main && found B19s-W "$FABLE" subagent && found B19s-B "$FABLE" subagent'

# --- decoys (F34): a gate that searches any transcript but the one the hook input names fails these
sc Di "$S1"; logrow "$ROW1"; mark wwhtbt; sub_tu sx "$SONNET"; sub_tu sy "$OPUS"; main_tu "$OPUS" toolu_other; gate Di Write sx
ck "decoy (i): agent_id X; the id is in agent-X.jsonl on claude-sonnet-5-5 and also in another subagent file on claude-opus-5-5 -> 2, naming claude-sonnet-5-5" '[ "$(rc Di)" = 2 ] && msg Di && found Di "$SONNET" subagent && grep -qF "agent-sx.jsonl" "$T/err.Di"'
sc Dii "$S1"; logrow "$ROW1"; mark wwhtbt; sub_tu sz "$OPUS"; gate Dii Write ""
ck "decoy (ii): a main-thread call whose id is only in a subagent file on claude-opus-5-5 -> 2, unknown (the main transcript read)" '[ "$(rc Dii)" = 2 ] && msg Dii && unknown Dii "$MAIN"'

all_fast(){ local x; for x in $ALLMS; do [ "${x#*:}" -lt 4000 ] || return 1; done; }
ck "every gate run decided within the 4 s budget ($(echo $ALLMS | wc -w) runs; slowest $(printf '%s\n' $ALLMS | sort -t: -k2 -n | tail -1) ms)" 'all_fast'
# AR1_SHOW="<id> ..." prints those runs' stderr (a reading aid for reviewers; no assertion depends on it)
[ -n "${AR1_SHOW:-}" ] && for x in $AR1_SHOW; do echo "--- $x"; cat "$T/err.$x"; done
ar_end
