#!/usr/bin/env bash
# ffdr-terminal-reader.test.sh: A1300 FFDR spec R3 (test T5). .local/lib/skill-route-terminal.py, the one read-only view of a routed
# session's launch provenance and terminal outcome. Real-shaped state comes from the managed launcher's own path (fable-launch.sh in test
# mode, private lane state, a fake CLI that prints the observed native envelopes of tests/fixtures/account-lanes/): the never-dispatched
# 7b82413f shape (Fable limit before any model work) and the failed 59ef8917 shape (Fable limit after model usage), both F1 resume orders,
# running and interrupted. Edge cases are hand-written fixtures in their own state dir; review-ancestor runs against real processes whose
# argv the test sets with `exec -a`. No provider call, no real state or credential. Run alone: bash tests/ffdr-terminal-reader.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
RD="$D/.local/lib/skill-route-terminal.py"; AL="$D/.local/lib/account-lane.py"; AFX="$D/tests/fixtures/account-lanes"
export HOME="$T/home"; mkdir -p "$HOME"
cat >"$T/claude5" <<'S'
#!/usr/bin/env bash
# T5 fake CLI: logs like the shared spy, then acts by T5_MODE; the envelopes are the observed fixtures with the pinned id put back.
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a args=$*" >>"$SPYLOG"
sid=""; prev=""; for x in "$@"; do case "$prev" in --session-id|--resume) sid="$x";; esac; prev="$x"; done
echo "$$" >"$T5_DIR/spy.pid.$sid"
case "${T5_MODE:-ok}" in
  ok) exit 0 ;;
  fail) exit 1 ;;
  limit) jq -c --arg s "$sid" '.session_id=$s' "$T5_AFX/native-fable-limit-observed.json"; exit 1 ;;
  limit-used) jq -c --arg s "$sid" '.session_id=$s | .modelUsage={"claude-fable-5-1":{"inputTokens":1200,"outputTokens":340}} | .num_turns=3' "$T5_AFX/native-fable-limit-observed.json"; exit 1 ;;
  nf429) jq -c --arg s "$sid" '.session_id=$s' "$T5_AFX/native-nonfable-429-observed.json"; exit 1 ;;
  sleep) sleep 60; exit 0 ;;
esac
S
chmod +x "$T/claude5"; export FABLE_CLAUDE_BIN="$T/claude5" T5_DIR="$T" T5_AFX="$AFX"
rd(){ python3 -I "$RD" --decisions "$DEC" "$@"; }
oc(){ rd session "$1" | jq -r '.terminal.outcome'; }
sid8(){ printf '%s-%s' "$1" "$(uuid | cut -c10-)"; }
req5(){ jq -nc --arg t "$2" '{task_id:$t,skill:"5whysandrhyme"}' >"$T/req.$1.json"; }   # 5whysandrhyme baseline = claude-fable-5-1 high: the fable lane
clearfable(){ local a; for a in jyen.pm mcphost.dev; do python3 -I "$AL" clear --account "$a" --lane fable --by t5 --reason "reset between T5 scenarios" >/dev/null; done; }
clearnf(){ local a; for a in josephsyen jyen.tech jyen.pm; do python3 -I "$AL" clear --account "$a" --lane nonfable --by t5 --reason "reset between T5 scenarios" >/dev/null; done; }
flr_begin

# --- 1. outcomes from the launcher's own path
flr_req ca T5-C; flr_run ca ca -p x; SC="$(flr_get ca .session)"
ck "completed: an Opus author whose run exits 0 (state clean, unknown_effect false, latest session_end rc 0 clean)" '[ "$(oc "$SC")" = completed ] && rd session "$SC" | jq -e ".terminal.rc==0 and .terminal.reasons==[] and .launch.role==\"author\" and .launch_rows==1 and .lane.lane==\"nonfable\" and .lane.claim_live==false" >/dev/null'
ck "completed session: provenance ok (one fresh launch row, account, lane and model agree with the lane entry)" 'rd session "$SC" | jq -e ".provenance=={\"ok\":true,\"reasons\":[]}" >/dev/null'
flr_req fa T5-F; T5_MODE=fail flr_run fa fa -p x; SF="$(flr_get fa .session)"
ck "failed: a run that exits 1 on the nonfable lane (never never-dispatched off the fable lane)" '[ "$(oc "$SF")" = failed ] && rd session "$SF" | jq -e ".terminal.rc==1 and (.terminal.reasons|join(\" \")|test(\"lane .nonfable. is not fable\"))" >/dev/null'
flr_req nf T5-NF; T5_MODE=nf429 flr_run nf nf --output-format json -p x >/dev/null; SNF="$(flr_get nf .session)"; clearnf
ck "failed: the observed non-Fable 429 envelope is a failed run, not never-dispatched (residual: re-reviewing it needs a declared replay)" '[ "$(cat $T/rc.nf)" != 0 ] && [ "$(oc "$SNF")" = failed ]'
SND="$(sid8 7b82413f)"; jq -nc --arg t T5-ND --arg s "$FX/happy.sha256" --arg ev "file:$T/ev.md" '{task_id:$t,skill:"5whysandrhyme",review:{reason:"independent_verifier_required",evidence:["ledger:A1300",$ev],snapshot:$s}}' >"$T/req.nd.json"
T5_MODE=limit flr_run nd nd --session-id "$SND" --output-format json -p x >/dev/null
ck "7b82413f shape: a Fable review refused at start by the observed limit (no model usage) records native_fable_limit, sid_correlation matches" '[ "$(cat $T/rc.nd)" = 1 ] && jq -e --arg s "$SND" "select(.event==\"native_fable_limit\" and .claimed_session==\$s and .native_session_id==\$s and (.sid_correlation|startswith(\"matches\")))" "$ACCOUNT_LANE_STATE/events.jsonl" >/dev/null'
ck "7b82413f shape: never-dispatched (lane fable, failed, prev null, one launch row and claim, limit between claim and end)" '[ "$(oc "$SND")" = never-dispatched ] && rd session "$SND" | jq -e ".terminal.rc==1 and .lane.lane==\"fable\" and .lane.prev==null and .launch.role==\"review\" and .provenance.ok" >/dev/null'
clearfable
SMR="$(sid8 59ef8917)"; req5 mr T5-MR; T5_MODE=limit-used flr_run mr mr --session-id "$SMR" --output-format json -p x >/dev/null
ck "59ef8917 shape: a Fable limit after model usage is not the refusal contract (no native_fable_limit event): failed" '[ "$(oc "$SMR")" = failed ] && ! grep -q "\"claimed_session\": \"$SMR\"" "$ACCOUNT_LANE_STATE/events.jsonl"'
clearfable
# F1, both resume orders: (a) limit at start, lane cleared by hand, resumed with the ack, model work, rc 1; (b) model work, rc 1, resumed
# with the ack, the Fable limit at the first call. Each ends lane fable, state failed, latest rc 1 with a matching limit event: failed.
SA="$(sid8 f1aaaaaa)"; req5 f1a T5-F1A; T5_MODE=limit flr_run f1a1 f1a --session-id "$SA" --output-format json -p x >/dev/null
ck "F1 (a) after run 1 (refused at start): never-dispatched" '[ "$(oc "$SA")" = never-dispatched ]'
clearfable; FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 T5_MODE=fail flr_run f1a2 f1a --resume "$SA" --output-format json -p x >/dev/null
ck "F1 (a) resumed with the ack and failed after model work: failed (prev not null), never never-dispatched" '[ "$(cat $T/rc.f1a2)" = 1 ] && [ "$(oc "$SA")" = failed ] && rd session "$SA" | jq -e ".lane.prev!=null and .launch_rows==2 and (.terminal.reasons|join(\" \")|test(\"prev is not null\"))" >/dev/null'
SB="$(sid8 f1bbbbbb)"; req5 f1b T5-F1B; T5_MODE=fail flr_run f1b1 f1b --session-id "$SB" --output-format json -p x >/dev/null
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 T5_MODE=limit flr_run f1b2 f1b --resume "$SB" --output-format json -p x >/dev/null
ck "F1 (b) model work then a resume refused by the limit (matching event recorded): failed, never never-dispatched" 'jq -e --arg s "$SB" "select(.event==\"native_fable_limit\" and .claimed_session==\$s and (.sid_correlation|startswith(\"matches\")))" "$ACCOUNT_LANE_STATE/events.jsonl" >/dev/null && [ "$(oc "$SB")" = failed ]'
clearfable
SRUN="$(uuid)"; flr_req rq T5-RUN; T5_MODE=sleep flr_bg run rq --session-id "$SRUN" -p x 2>/dev/null   # its shell reports the SIGKILL below; not a check line
for i in $(seq 1 50); do [ -s "$T/spy.pid.$SRUN" ] && break; sleep 0.1; done
ck "running: state running and the claim pid alive with its start time" '[ "$(oc "$SRUN")" = running ] && rd session "$SRUN" | jq -e ".lane.claim_live==true and .terminal.rc==null" >/dev/null'
CP="$(jq -r --arg s "$SRUN" '.sessions[$s].claim.pid' "$ACCOUNT_LANE_STATE/sessions.json")"; SP="$(cat "$T/spy.pid.$SRUN")"
kill -9 "$CP" 2>/dev/null; for i in $(seq 1 30); do kill -0 "$CP" 2>/dev/null || break; sleep 0.1; done
for c in $(pgrep -P "$SP"); do kill "$c" 2>/dev/null; done; kill "$SP" 2>/dev/null
ck "interrupted: the supervisor (claim pid) killed with SIGKILL leaves state running with a dead claim" '[ "$(oc "$SRUN")" = interrupted ] && rd session "$SRUN" | jq -e ".lane.claim_live==false" >/dev/null'
ck "absent: a session with no launch row (provenance false)" 'rd session "$(uuid)" | jq -e ".terminal.outcome==\"absent\" and .launch==null and .lane==null and .provenance.ok==false" >/dev/null'
ck "task: every 5whysandrhyme review session of T5-ND in log order, role filter applied" '[ "$(rd task T5-ND --skill 5whysandrhyme --role review | jq -r "map(.session)|join(\",\")")" = "$SND" ] && [ "$(rd task T5-ND --skill 5whysandrhyme --role author | jq length)" = 0 ] && [ "$(rd task T5-C --skill dream | jq -r ".[0].terminal.outcome")" = completed ]'
ck "task: --scope-id filters on the row scope_id" 'S1="$(flr_get nd .scope_id)"; [ "$(rd task T5-ND --skill 5whysandrhyme --scope-id "$S1" | jq length)" = 1 ] && [ "$(rd task T5-ND --skill 5whysandrhyme --scope-id nope | jq length)" = 0 ]'
ck "the seeded legacy rows and the torn-line-free log parse with no malformed count" '! rd session "$SC" | jq -e ".terminal.reasons|join(\" \")|test(\"malformed\")" >/dev/null'

# --- 2. hand-written fixtures (one state dir + decisions log; each case is one session)
K="$T/craft"; mkdir -p "$K/lanes"; KD="$K/dec.jsonl"; : >"$KD"; KE="$K/lanes/events.jsonl"; : >"$KE"
krd(){ ACCOUNT_LANE_STATE="$K/lanes" python3 -I "$RD" --decisions "$KD" "$@"; }
koc(){ krd session "$1" | jq -r '.terminal.outcome'; }
krow(){ # SID [jq edits]: a launch row (dream author on opus-xhigh/josephsyen unless edited)
  jq -nc --arg s "$1" '{ts:"2026-11-17T00:00:00-08:00",decision:"launch",task_id:"K",skill:"dream",route:"opus-xhigh",model:"claude-opus-5-5",effort:"xhigh",account:"josephsyen",session:$s,resume:false,reasons:"fixture",role:"author",scope:"",scope_id:""}' | jq -c "${2:-.}" >>"$KD"; }
kev(){ printf '%s\n' "$1" >>"$KE"; }
KS='{}'
kent(){ KS="$(jq -c --arg s "$1" --argjson e "$2" '.[$s]=$e' <<<"$KS")"; jq -nc --argjson s "$KS" '{version:1,sessions:$s}' >"$K/lanes/sessions.json"; }
claim(){ printf '{"account": "%s", "ack_unknown_effect": false, "event": "session_claim", "lane": "%s", "pinned": false, "resume": false, "session": "%s", "ts": 1800000000}' "$2" "$3" "$1"; }
send(){ printf '{"event": "session_end", "rc": %s, "session": "%s", "state": "%s", "ts": 1800000001}' "$2" "$1" "$3"; }
limit(){ printf '{"account": "%s", "claimed_session": "%s", "event": "native_fable_limit", "lane": "fable", "native_session_id": "%s", "sid_correlation": "%s", "ts": 1800000001}' "$2" "$1" "$1" "${3:-matches the session id passed to the CLI}"; }
ent(){ jq -nc --arg a "$1" --arg l "$2" --arg m "$3" --arg st "$4" --argjson ue "$5" '{account:$a,lane:$l,model:$m,ts:1800000000,state:$st,unknown_effect:$ue,claim:{pid:999999999,start:1},prev:null}'; }
# completed positive and its variants
K1="$(uuid)"; krow "$K1"; kent "$K1" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$K1" josephsyen nonfable)"; kev "$(send "$K1" 0 clean)"
ck "fixture control: clean, unknown_effect false, latest end rc 0 clean -> completed" '[ "$(koc "$K1")" = completed ]'
K2="$(uuid)"; krow "$K2"; kent "$K2" "$(ent josephsyen nonfable claude-opus-5-5 clean false | jq -c 'del(.unknown_effect)')"; kev "$(claim "$K2" josephsyen nonfable)"; kev "$(send "$K2" 0 clean)"
ck "clean with unknown_effect missing -> unknown, not completed" '[ "$(koc "$K2")" = unknown ]'
K3="$(uuid)"; krow "$K3"; kent "$K3" "$(ent josephsyen nonfable claude-opus-5-5 clean null)"; kev "$(claim "$K3" josephsyen nonfable)"; kev "$(send "$K3" 0 clean)"
ck "clean with unknown_effect null -> unknown, not completed" '[ "$(koc "$K3")" = unknown ]'
K4="$(uuid)"; krow "$K4"; kent "$K4" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$K4" josephsyen nonfable)"; kev "$(send "$K4" 0 clean)"; kev "$(send "$K4" 1 failed)"
ck "clean but the latest session_end (file order) has rc 1 -> unknown (contradiction)" '[ "$(koc "$K4")" = unknown ] && krd session "$K4" | jq -e ".terminal.rc==1 and (.terminal.reasons|join(\" \")|test(\"contradiction\"))" >/dev/null'
K5="$(uuid)"; krow "$K5"; kent "$K5" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$K5" josephsyen nonfable)"
ck "clean with no session_end -> unknown" '[ "$(koc "$K5")" = unknown ]'
K6="$(uuid)"; krow "$K6"; kent "$K6" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$K6" josephsyen nonfable)"; kev "$(send "$K6" 0 clean)"; kev "$(claim "$K6" josephsyen nonfable)"
ck "clean but a session_claim after the latest session_end -> unknown" '[ "$(koc "$K6")" = unknown ]'
K7="$(uuid)"; krow "$K7"; kent "$K7" "$(ent josephsyen nonfable claude-opus-5-5 adopted true)"; kev "$(claim "$K7" josephsyen nonfable)"
ck "any other state (adopted) -> unknown" '[ "$(koc "$K7")" = unknown ]'
K8="$(uuid)"; krow "$K8"
ck "a launch row with no sessions.json entry -> unknown" '[ "$(koc "$K8")" = unknown ] && krd session "$K8" | jq -e ".lane==null and .provenance.ok==false" >/dev/null'
sleep 60 & KP=$!; FLR_BG+=("$KP"); KPS="$(cut -d')' -f2- "/proc/$KP/stat" | awk '{print $20}')"
K9="$(uuid)"; krow "$K9"; kent "$K9" "$(ent josephsyen nonfable claude-opus-5-5 running false | jq -c --argjson p "$KP" --argjson st "$((KPS+1))" '.claim={pid:$p,start:$st}')"; kev "$(claim "$K9" josephsyen nonfable)"
K10="$(uuid)"; krow "$K10"; kent "$K10" "$(ent josephsyen nonfable claude-opus-5-5 running false | jq -c --argjson p "$KP" --argjson st "$KPS" '.claim={pid:$p,start:$st}')"; kev "$(claim "$K10" josephsyen nonfable)"
ck "state running whose claim pid is alive with another start time (a reused pid) -> interrupted; the same pid with its start time -> running" '[ "$(koc "$K9")" = interrupted ] && [ "$(koc "$K10")" = running ]'
kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null
K11="$(uuid)"; krow "$K11"; kent "$K11" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$K11" josephsyen nonfable)"; kev "$(send "$K11" 1 clean)"
ck "clean but the latest session_end has rc 1 with state clean -> unknown (contradiction), not completed" '[ "$(koc "$K11")" = unknown ] && krd session "$K11" | jq -e ".terminal.rc==1 and (.terminal.reasons|join(\" \")|test(\"contradiction\"))" >/dev/null'
# never-dispatched positive and its variants (fable lane on jyen.pm)
nd(){ # SID [entry jq] [limit line] : one fresh fable run refused at start
  krow "$1" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm"'
  kent "$1" "$(ent jyen.pm fable claude-fable-5-1 failed true | jq -c "${2:-.}")"; kev "$(claim "$1" jyen.pm fable)"; kev "${3:-$(limit "$1" jyen.pm)}"; kev "$(send "$1" 1 failed)"; }
N1="$(uuid)"; nd "$N1"
ck "fixture control: the never-dispatched proof -> never-dispatched" '[ "$(koc "$N1")" = never-dispatched ]'
N2="$(uuid)"; nd "$N2" . "$(limit "$N2" mcphost.dev)"
ck "a limit event whose account is not the entry account -> failed, not never-dispatched" '[ "$(koc "$N2")" = failed ]'
N3="$(uuid)"; nd "$N3" . "$(limit "$N3" jyen.pm "none: no session id was passed to the CLI (unpinned run)")"
ck "a limit event whose sid_correlation is not matches -> failed" '[ "$(koc "$N3")" = failed ]'
N4="$(uuid)"; nd "$N4" '.prev={"account":"jyen.pm","lane":"fable","state":"failed"}'
ck "prev not null (a resumed session) -> failed" '[ "$(koc "$N4")" = failed ]'
N5="$(uuid)"; nd "$N5" '.lane="nonfable"'
ck "entry lane not fable -> failed" '[ "$(koc "$N5")" = failed ]'
N6="$(uuid)"; krow "$N6" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm"'; kent "$N6" "$(ent jyen.pm fable claude-fable-5-1 failed true)"
kev "$(limit "$N6" jyen.pm)"; kev "$(claim "$N6" jyen.pm fable)"; kev "$(send "$N6" 1 failed)"
ck "the limit event before the claim (file order) -> failed" '[ "$(koc "$N6")" = failed ]'
N7="$(uuid)"; nd "$N7"; krow "$N7" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm" | .resume=true'
ck "two launch rows (a resume) -> failed" '[ "$(koc "$N7")" = failed ]'
N8="$(uuid)"; krow "$N8" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm"'; kent "$N8" "$(ent jyen.pm fable claude-fable-5-1 failed true)"
kev "$(claim "$N8" jyen.pm fable)"; kev "$(claim "$N8" jyen.pm fable)"; kev "$(limit "$N8" jyen.pm)"; kev "$(send "$N8" 1 failed)"
ck "two session_claim events -> failed" '[ "$(koc "$N8")" = failed ]'
N9="$(uuid)"; krow "$N9" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm"'; kent "$N9" "$(ent jyen.pm fable claude-fable-5-1 failed true)"
kev "$(claim "$N9" jyen.pm fable)"; kev "$(limit "$N9" jyen.pm)"; kev "$(send "$N9" 0 clean)"
N10="$(uuid)"; krow "$N10" '.route="fable-high" | .model="claude-fable-5-1" | .effort="high" | .account="jyen.pm"'; kent "$N10" "$(ent jyen.pm fable claude-fable-5-1 failed true)"
kev "$(claim "$N10" jyen.pm fable)"; kev "$(limit "$N10" jyen.pm)"; kev "$(send "$N10" 1 killed)"
ck "the latest session_end is rc 0 clean, or rc 1 with a state other than failed, beside a failed entry -> failed, not never-dispatched" '[ "$(koc "$N9")" = failed ] && [ "$(koc "$N10")" = failed ]'
N11="$(uuid)"; nd "$N11" . "$(limit "$N11" jyen.pm | jq -c --arg o "$(uuid)" '.native_session_id=$o')"
N12="$(uuid)"; nd "$N12" . "$(limit "$N12" jyen.pm | jq -c --arg o "$(uuid)" '.claimed_session=$o')"
ck "a limit event whose native_session_id (or claimed_session) is another id -> failed, not never-dispatched" '[ "$(koc "$N11")" = failed ] && [ "$(koc "$N12")" = failed ]'
ck "provenance: two claims for one launch row is an unrouted run" 'krd session "$N8" | jq -e ".provenance.ok==false and (.provenance.reasons|join(\" \")|test(\"unrouted run\"))" >/dev/null'
# a malformed or partial event line never yields completed or never-dispatched
cp -r "$K" "$T/craft-bad"; printf '{"event": "session_end", "rc": 0, "sess' >>"$T/craft-bad/lanes/events.jsonl"
ck "a partial last event line: the completed fixture reads unknown, the never-dispatched one failed (both name the line)" '[ "$(ACCOUNT_LANE_STATE="$T/craft-bad/lanes" python3 -I "$RD" --decisions "$T/craft-bad/dec.jsonl" session "$K1" | jq -r .terminal.outcome)" = unknown ] && ACCOUNT_LANE_STATE="$T/craft-bad/lanes" python3 -I "$RD" --decisions "$T/craft-bad/dec.jsonl" session "$N1" | jq -e ".terminal.outcome==\"failed\" and (.terminal.reasons|join(\" \")|test(\"1 malformed or partial\"))" >/dev/null'
cp -r "$K" "$T/craft-mid"; sed -i '2i not json at all' "$T/craft-mid/lanes/events.jsonl"
ck "a malformed middle event line: no completed, no never-dispatched" '[ "$(ACCOUNT_LANE_STATE="$T/craft-mid/lanes" python3 -I "$RD" --decisions "$T/craft-mid/dec.jsonl" session "$K1" | jq -r .terminal.outcome)" = unknown ] && [ "$(ACCOUNT_LANE_STATE="$T/craft-mid/lanes" python3 -I "$RD" --decisions "$T/craft-mid/dec.jsonl" session "$N1" | jq -r .terminal.outcome)" = failed ]'
ck "a malformed middle event line: provenance not ok either (the session_claim count is not provable)" 'ACCOUNT_LANE_STATE="$T/craft-mid/lanes" python3 -I "$RD" --decisions "$T/craft-mid/dec.jsonl" session "$K1" | jq -e ".provenance.ok==false and (.provenance.reasons|join(\" \")|test(\"not provable\"))" >/dev/null && krd session "$K1" | jq -e ".provenance.ok==true" >/dev/null'
cp -r "$K" "$T/craft-noev"; rm "$T/craft-noev/lanes/events.jsonl"
ck "absent events.jsonl: clean and failed sessions read unknown (never completed or never-dispatched)" '[ "$(ACCOUNT_LANE_STATE="$T/craft-noev/lanes" python3 -I "$RD" --decisions "$T/craft-noev/dec.jsonl" session "$K1" | jq -r .terminal.outcome)" = unknown ] && [ "$(ACCOUNT_LANE_STATE="$T/craft-noev/lanes" python3 -I "$RD" --decisions "$T/craft-noev/dec.jsonl" session "$N1" | jq -r .terminal.outcome)" = unknown ]'
cp -r "$K" "$T/craft-mal"; printf '{"version": 1, "sessions": [' >"$T/craft-mal/lanes/sessions.json"
ck "malformed sessions.json: every session unknown, reason lane state malformed" '[ "$(ACCOUNT_LANE_STATE="$T/craft-mal/lanes" python3 -I "$RD" --decisions "$T/craft-mal/dec.jsonl" task K --skill dream | jq -r "map(.terminal.outcome)|unique|join(\",\")")" = unknown ] && ACCOUNT_LANE_STATE="$T/craft-mal/lanes" python3 -I "$RD" --decisions "$T/craft-mal/dec.jsonl" session "$K1" | jq -e ".terminal.reasons|index(\"lane state malformed\")" >/dev/null'
cp -r "$K" "$T/craft-dec"; printf '%s\n' '{"ts":"x","decision":"launch","task_id":"K","sess' '123' >>"$T/craft-dec/dec.jsonl"
ck "malformed decisions-log lines are skipped and counted in a reason" 'ACCOUNT_LANE_STATE="$T/craft-dec/lanes" python3 -I "$RD" --decisions "$T/craft-dec/dec.jsonl" session "$K1" | jq -e ".terminal.outcome==\"completed\" and (.terminal.reasons|index(\"decisions log: 2 malformed line(s) skipped\"))" >/dev/null'
# provenance: every false rule of R3, beside a true control
P0="$(uuid)"; krow "$P0"; kent "$P0" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P0" josephsyen nonfable)"; kev "$(send "$P0" 0 clean)"
pv(){ krd session "$1" | jq -r '.provenance.reasons|join(" | ")'; }
ck "provenance control: one fresh row, account, lane and model agree, one claim -> ok" 'krd session "$P0" | jq -e ".provenance.ok==true" >/dev/null'
P1="$(uuid)"; krow "$P1"; kent "$P1" "$(ent jyen.tech nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P1" jyen.tech nonfable)"; kev "$(send "$P1" 0 clean)"
ck "provenance false: launch-row account differs from the lane account" 'pv "$P1" | grep -q "launch-row account \"josephsyen\" != lane account \"jyen.tech\""'
P2="$(uuid)"; krow "$P2"; kent "$P2" "$(ent josephsyen fable claude-opus-5-5 clean false)"; kev "$(claim "$P2" josephsyen fable)"; kev "$(send "$P2" 0 clean)"
ck "provenance false: the launch model lane (nonfable) differs from the entry lane" 'pv "$P2" | grep -q "launch model lane nonfable != lane entry lane \"fable\""'
P3="$(uuid)"; krow "$P3"; kent "$P3" "$(ent josephsyen nonfable claude-sonnet-5-5 clean false)"; kev "$(claim "$P3" josephsyen nonfable)"; kev "$(send "$P3" 0 clean)"
ck "provenance false: the entry model differs from the launch rows' model (an unrouted resume rewrote it)" 'pv "$P3" | grep -q "lane entry model \"claude-sonnet-5-5\" != launch-row model \"claude-opus-5-5\""'
P4="$(uuid)"; krow "$P4"; kent "$P4" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P4" josephsyen nonfable)"; kev "$(claim "$P4" josephsyen nonfable)"; kev "$(send "$P4" 0 clean)"
ck "provenance false: two claims, one launch row (an unrouted run)" 'pv "$P4" | grep -q "unrouted run: 2 session_claim"'
P5="$(uuid)"; krow "$P5"; kent "$P5" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P5" josephsyen nonfable)"; kev "{\"event\": \"session_abort\", \"session\": \"$P5\", \"ts\": 1}"; kev "$(claim "$P5" josephsyen nonfable)"; kev "$(send "$P5" 0 clean)"
ck "provenance: a claim undone by session_abort is not counted (two claims, one abort, one row -> ok)" 'krd session "$P5" | jq -e ".provenance.ok==true" >/dev/null'
P6="$(uuid)"; krow "$P6" '.resume=true'; kent "$P6" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P6" josephsyen nonfable)"; kev "$(send "$P6" 0 clean)"
ck "provenance false: the first launch row is a resume" 'pv "$P6" | grep -q "the first launch row is a resume"'
for k in task_id role scope_id model effort account; do
  P7="$(uuid)"; krow "$P7"; case $k in task_id) e='.task_id="K2"';; role) e='.role="review"';; scope_id) e='.scope_id="abc"';; model) e='.model="claude-sonnet-5-5"';; effort) e='.effort="high"';; account) e='.account="jyen.tech"';; esac
  krow "$P7" "$e | .resume=true"; kent "$P7" "$(ent josephsyen nonfable claude-opus-5-5 clean false)"; kev "$(claim "$P7" josephsyen nonfable)"; kev "$(claim "$P7" josephsyen nonfable)"; kev "$(send "$P7" 0 clean)"
  ck "provenance false: launch rows of one session disagree on $k" 'pv "$P7" | grep -q "launch rows disagree on $k"'
done
# reader errors: refused override, non-regular or symlinked state, unreadable log, usage
ck "ACCOUNT_LANE_STATE without FABLE_LAUNCH_TEST=1: exit 2, refused" 'out="$(env -u FABLE_LAUNCH_TEST ACCOUNT_LANE_STATE="$K/lanes" python3 -I "$RD" --decisions "$KD" session "$K1" 2>&1)"; [ $? = 2 ] && grep -q "override refused" <<<"$out"'
cp -r "$K" "$T/fifo1"; rm "$T/fifo1/lanes/sessions.json"; mkfifo "$T/fifo1/lanes/sessions.json"
ck "a FIFO sessions.json: exit 2 at once (opened O_NONBLOCK, not a regular file)" 'timeout 5 env ACCOUNT_LANE_STATE="$T/fifo1/lanes" python3 -I "$RD" --decisions "$T/fifo1/dec.jsonl" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'
cp -r "$K" "$T/fifo2"; rm "$T/fifo2/lanes/events.jsonl"; mkfifo "$T/fifo2/lanes/events.jsonl"
ck "a FIFO events.jsonl: exit 2 at once" 'timeout 5 env ACCOUNT_LANE_STATE="$T/fifo2/lanes" python3 -I "$RD" --decisions "$T/fifo2/dec.jsonl" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'
cp -r "$K" "$T/sym1"; mv "$T/sym1/lanes/events.jsonl" "$T/sym1/ev.real"; ln -s "$T/sym1/ev.real" "$T/sym1/lanes/events.jsonl"
ck "a symlinked events.jsonl: exit 2 (O_NOFOLLOW)" 'ACCOUNT_LANE_STATE="$T/sym1/lanes" python3 -I "$RD" --decisions "$T/sym1/dec.jsonl" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'
cp -r "$K" "$T/sym2"; mv "$T/sym2/lanes/sessions.json" "$T/sym2/ss.real"; ln -s "$T/sym2/ss.real" "$T/sym2/lanes/sessions.json"
ck "a symlinked sessions.json: exit 2" 'ACCOUNT_LANE_STATE="$T/sym2/lanes" python3 -I "$RD" --decisions "$T/sym2/dec.jsonl" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'
mkfifo "$T/dec.fifo"
ck "a FIFO decisions log: exit 2 at once" 'timeout 5 env ACCOUNT_LANE_STATE="$K/lanes" python3 -I "$RD" --decisions "$T/dec.fifo" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'
cp "$KD" "$T/dec.noread"; chmod 000 "$T/dec.noread"
if [ -r "$T/dec.noread" ]; then echo "NOTE running as a user who can read mode 000 files; the unreadable-log case is not exercised"; else
  ck "an unreadable decisions log: exit 2" 'krd --decisions "$T/dec.noread" session "$K1" >/dev/null 2>&1; [ $? = 2 ]'; fi
ck "an absent decisions log: no launch rows (absent, exit 0)" '[ "$(krd --decisions "$T/no-such.jsonl" session "$K1" | jq -r .terminal.outcome)" = absent ]'
ck "usage errors exit 2 (no command, task without --skill, review-ancestor without --pid, bad --role)" 'krd >/dev/null 2>&1; a=$?; krd task K >/dev/null 2>&1; b=$?; krd review-ancestor >/dev/null 2>&1; c=$?; krd task K --skill dream --role boss >/dev/null 2>&1; d=$?; [ "$a$b$c$d" = 2222 ]'
before="$(cd "$K" && find . -type f -exec sha256sum {} + | sort | sha256sum)"; krd task K --skill dream >/dev/null; krd session "$K1" >/dev/null; krd review-ancestor --pid $$ >/dev/null
ck "the reader never writes (state dir and log byte-identical after reads)" '[ "$(cd "$K" && find . -type f -exec sha256sum {} + | sort | sha256sum)" = "$before" ]'

# --- 3. review-ancestor (mirrors T3): real processes, argv set with exec -a, a sleep leaf as --pid
RV="$(uuid)"; krow "$RV" '.role="review" | .scope_id="s1"'; AU="$(uuid)"; krow "$AU"
anc(){ # NAME ARGV0 ARGS...: a process whose argv is [ARGV0, -c, <script>, x, ARGS...] and whose one child is a sleep (the leaf)
  local n="$1" a0="$2"; shift 2
  LEAF="$T/leaf.$n" bash -c 'exec -a "$0" bash -c "sleep 60 & echo \$! >\"\$LEAF\"; wait" x "$@"' "$a0" "$@" & FLR_BG+=($!); echo $! >"$T/anc.$n"
  local i; for i in $(seq 1 50); do [ -s "$T/leaf.$n" ] && break; sleep 0.1; done; FLR_BG+=("$(cat "$T/leaf.$n")")
}
leaf(){ cat "$T/leaf.$1"; }
anc w1 wrapper; W1="$(cat "$T/anc.w1")"; W1S="$(cut -d')' -f2- /proc/$W1/stat | awk '{print $20}')"
kent "$RV" "$(ent josephsyen nonfable claude-opus-5-5 running false | jq -c --argjson p "$W1" --argjson s "$W1S" '.claim={pid:$p,start:$s}')"
ck "review-ancestor: an ancestor whose pid and start time equal a review session's claim is named (argv ignored)" 'krd review-ancestor --pid "$(leaf w1)" | jq -e --arg s "$RV" --argjson p "$W1" ".review_session==\$s and .pid==\$p and (.reason|test(\"claim\"))" >/dev/null'
ck "review-ancestor: --self equal to that review session is never a review ancestor" 'krd review-ancestor --pid "$(leaf w1)" --self "$RV" | jq -e ".review_session==null" >/dev/null'
kent "$RV" "$(ent josephsyen nonfable claude-opus-5-5 running false | jq -c --argjson p "$W1" --argjson s "$((W1S+1))" '.claim={pid:$p,start:$s}')"
ck "review-ancestor: same pid, different start time (a reused pid) is not the claim" 'krd review-ancestor --pid "$(leaf w1)" | jq -e ".review_session==null" >/dev/null'
kent "$AU" "$(ent josephsyen nonfable claude-opus-5-5 running false | jq -c --argjson p "$W1" --argjson s "$W1S" '.claim={pid:$p,start:$s}')"
ck "review-ancestor: the claim of an author session is not a review ancestor" 'krd review-ancestor --pid "$(leaf w1)" | jq -e ".review_session==null" >/dev/null'
anc c1 claude --session-id "$RV" -p x
ck "review-ancestor: argv[0] claude carrying --session-id <review> is named" 'krd review-ancestor --pid "$(leaf c1)" | jq -e --arg s "$RV" ".review_session==\$s and (.reason|test(\"claude\"))" >/dev/null'
ck "review-ancestor: --self equal to the review id a claude ancestor carries is not a review ancestor (the launch's own resumed id)" 'krd review-ancestor --pid "$(leaf c1)" --self "$RV" | jq -e ".review_session==null" >/dev/null'
anc c2 /opt/bin/claude "--resume=$RV"; anc c3 claude -r "$RV"
ck "review-ancestor: the --resume=<id> and -r <id> forms under a claude argv[0] (any path) are named" 'krd review-ancestor --pid "$(leaf c2)" | jq -e --arg s "$RV" ".review_session==\$s" >/dev/null && krd review-ancestor --pid "$(leaf c3)" | jq -e --arg s "$RV" ".review_session==\$s" >/dev/null'
anc a1 python3 -I /x/.local/lib/account-lane.py run --session "$RV" -- /x/claude --session-id "$RV" -p x
ck "review-ancestor: an account-lane.py run supervisor carrying the review id is named" 'krd review-ancestor --pid "$(leaf a1)" | jq -e --arg s "$RV" ".review_session==\$s and (.reason|test(\"account-lane.py run\"))" >/dev/null'
anc t1 tmux new-session -d -s r7b claude --session-id "$RV"
ck "review-ancestor: a tmux-server-shaped ancestor (argv[0] tmux) carrying a review --session-id is ignored" 'krd review-ancestor --pid "$(leaf t1)" | jq -e ".review_session==null" >/dev/null'
printf '#!/usr/bin/env bash\nsleep 60 & echo $! >"$LEAF"; wait\n' >"$T/driver.sh"; chmod +x "$T/driver.sh"
LEAF="$T/leaf.d1" bash "$T/driver.sh" -r "$RV" & FLR_BG+=($!); for i in $(seq 1 50); do [ -s "$T/leaf.d1" ] && break; sleep 0.1; done; FLR_BG+=("$(cat "$T/leaf.d1")")
ck "review-ancestor: a driver script taking -r <review sid> is ignored" 'krd review-ancestor --pid "$(leaf d1)" | jq -e ".review_session==null" >/dev/null'
anc c4 claude --session-id "$AU"
ck "review-ancestor: a claude ancestor carrying an author session id is ignored" 'krd review-ancestor --pid "$(leaf c4)" | jq -e ".review_session==null" >/dev/null'
printf '%s\n' 'bash -c "sleep 60 & echo \$! >\"\$LEAF\"; wait"; true' >"$T/mid.sh"   # two commands: bash forks the inner shell, keeping the claude-argv parent
LEAF="$T/leaf.deep" bash -c 'exec -a claude bash "$1" x --session-id "$0"' "$RV" "$T/mid.sh" & FLR_BG+=($!); for i in $(seq 1 50); do [ -s "$T/leaf.deep" ] && break; sleep 0.1; done; FLR_BG+=("$(cat "$T/leaf.deep")")
ck "review-ancestor: a claude ancestor two levels up is named" 'krd review-ancestor --pid "$(leaf deep)" | jq -e --arg s "$RV" ".review_session==\$s" >/dev/null'
ck "review-ancestor: no review anywhere up the chain of this test -> null, exit 0" 'krd review-ancestor --pid $$ | jq -e ".review_session==null and .pid==null" >/dev/null'
ck "review-ancestor: a pid that does not exist -> exit 2" 'krd review-ancestor --pid 999999999 >/dev/null 2>&1; [ $? = 2 ]'
flr_end
