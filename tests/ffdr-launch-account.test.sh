#!/usr/bin/env bash
# ffdr-launch-account.test.sh: A1300 FFDR spec r2 (test T2). Opus Dream routed launches go to the nonfable lane's primary; the reserve is
# used only after the primary's exhaustion is observed (the real non-Fable 429 envelope), a generic 429 text never switches; no launch takes
# the fable lane (the reserve account is also in the Fable order); each launch row records route, model, effort and account exactly; the
# worker env carries R4.1's SKILL_ROUTE_ROLE/SESSION/SCOPE_ID; outside FABLE_LAUNCH_TEST=1 the launcher refuses SKILL_ROUTE_POLICY and
# SKILL_ROUTE_LEDGER_IDS (R4.6). The lane policy is carbon-shaped (spec r2 facts: nonfable primaries [josephsyen], reserve [mcphost.dev];
# Fable order mcphost.dev, jyen.pm as in the launcher header), written here: synthetic, not the live file. Spy CLI, private lane state and
# log (fable-launch-review_lib.sh), dummy tokens; no provider call. Run alone: bash tests/ffdr-launch-account.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
AL="$D/.local/lib/account-lane.py"; AFX="$D/tests/fixtures/account-lanes"
jq -n '{version:1,lanes:{fable:{order:["mcphost.dev","jyen.pm"]},nonfable:{primaries:["josephsyen"],reserve:["mcphost.dev"]}}}' >"$T/lane-policy.json"
export ACCOUNT_LANE_POLICY="$T/lane-policy.json"
cat >"$T/claude2" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a role=${SKILL_ROUTE_ROLE-<unset>} session=${SKILL_ROUTE_SESSION-<unset>} scope=${SKILL_ROUTE_SCOPE_ID-<unset>} task=${SKILL_ROUTE_TASK_ID-} route=${SKILL_ROUTE_ROUTE-} effort=${SKILL_ROUTE_EFFORT-} fla=${FABLE_LAUNCH_ACCOUNT-} flm=${FABLE_LAUNCH_MODEL-} args=$*" >>"$SPYLOG"
sid=""; prev=""; for x in "$@"; do case "$prev" in --session-id|--resume) sid="$x";; esac; prev="$x"; done
case "${T2_MODE:-ok}" in
  ok) exit 0 ;;
  nf429) jq -c --arg s "$sid" '.session_id=$s' "$T2_AFX/native-nonfable-429-observed.json"; exit 1 ;;
  generic-stderr) echo 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}' >&2; exit 1 ;;
  generic-json) jq -nc --arg s "$sid" '{type:"result",subtype:"error",is_error:true,terminal_reason:"api_error",api_error_status:429,result:"API Error: 429 rate_limit_error: too many requests, please slow down",session_id:$s}'; exit 1 ;;
esac
S
chmod +x "$T/claude2"; export FABLE_CLAUDE_BIN="$T/claude2" T2_AFX="$AFX"
dq(){ jq -nc --arg t "$2" --arg c "$3" --arg ev "file:$T/ev.md" '{task_id:$t,skill:"dream",decision_class:$c,evidence_refs:["ledger:A1300",$ev]}' >"$T/req.$1.json"; }
acct(){ flr_get "$1" 'select(.decision=="launch") | .account'; }
exhausted(){ python3 -I "$AL" status | jq -r '.exhausted | keys | join(",")'; }
flr_begin

# --- Opus Dream author and review: the nonfable primary, the row says so exactly, the worker env carries R4.1
dq a1 T2-A new_vision; flr_run a1 a1 -p x; SA="$(flr_get a1 .session)"
ck "Opus Dream author (new_vision): the launch row is route opus-high, model claude-opus-5-5, effort high, account josephsyen" '[ "$FLR_RC" = 0 ] && [ "$(flr_get a1 "select(.decision==\"launch\") | [.route,.model,.effort,.account,.role] | join(\",\")")" = "opus-high,claude-opus-5-5,high,josephsyen,author" ]'
ck "the CLI ran on the row's account with --model claude-opus-5-5 --effort high" 'grep -q "spy acct=josephsyen " "$T/spy.a1" && grep -q -- "--model claude-opus-5-5" "$T/spy.a1" && grep -q -- "--effort high" "$T/spy.a1"'
ck "R4.1 author worker env: SKILL_ROUTE_ROLE=author, SKILL_ROUTE_SESSION = the id handed to the CLI, SKILL_ROUTE_SCOPE_ID empty" 'grep -qF "role=author session=$SA scope= task=T2-A route=opus-high effort=high fla=josephsyen flm=claude-opus-5-5 " "$T/spy.a1" && grep -qF -- "--session-id $SA" "$T/spy.a1"'
SR="$(uuid)"; flr_req r1 T2-R "$FX/happy.sha256"; flr_run r1 r1 --session-id "$SR" -p x
ck "Opus Dream review (consequential_uncertainty): route opus-xhigh, claude-opus-5-5 xhigh, account josephsyen, role review" '[ "$FLR_RC" = 0 ] && [ "$(flr_get r1 "select(.decision==\"launch\") | [.route,.model,.effort,.account,.role] | join(\",\")")" = "opus-xhigh,claude-opus-5-5,xhigh,josephsyen,review" ]'
ck "R4.1 review worker env: SKILL_ROUTE_ROLE=review, its own session, its scope_id" 'grep -qF "role=review session=$SR scope=$(flr_get r1 "select(.decision==\"launch\") | .scope_id") " "$T/spy.r1"'

# --- a generic 429 never switches; the observed non-Fable 429 envelope does, to the reserve, and only while the primary is exhausted
dq g1 T2-G1 prioritization; T2_MODE=generic-stderr flr_run g1 g1 -p x
dq g2 T2-G2 prioritization; T2_MODE=generic-json flr_run g2 g2 --output-format json -p x >/dev/null
ck "generic 429 text (one stderr line, and a json result with an unanchored 429 text): runs fail, no exhaustion recorded" '[ "$(cat $T/rc.g1)" != 0 ] && [ "$(cat $T/rc.g2)" != 0 ] && [ -z "$(exhausted)" ]'
dq a2 T2-A2 difficult_decomposition; flr_run a2 a2 -p x
ck "after the generic 429s the next Opus Dream launch is still on the primary" '[ "$FLR_RC" = 0 ] && [ "$(acct a2)" = josephsyen ]'
dq e1 T2-E prioritization; T2_MODE=nf429 flr_run e1 e1 --output-format json -p x >/dev/null
ck "the observed non-Fable 429 envelope on josephsyen records josephsyen|nonfable exhausted (no switch inside that run)" '[ "$(cat $T/rc.e1)" != 0 ] && [ "$(acct e1)" = josephsyen ] && [ "$(exhausted)" = "josephsyen|nonfable" ]'
dq a3 T2-A3 new_vision; flr_run a3 a3 -p x
ck "with the primary exhausted, the next Opus Dream launch takes the reserve mcphost.dev, recorded in its row and seen by the CLI" '[ "$FLR_RC" = 0 ] && [ "$(acct a3)" = mcphost.dev ] && grep -q "spy acct=mcphost.dev " "$T/spy.a3"'
python3 -I "$AL" clear --account josephsyen --lane nonfable --by t2 --reason "primary usable again in this test" >/dev/null
dq a4 T2-A4 consequential_uncertainty; flr_run a4 a4 -p x
ck "once the primary is cleared, launches return to josephsyen (the reserve is not sticky)" '[ "$FLR_RC" = 0 ] && [ "$(acct a4)" = josephsyen ]'
ck "never the fable lane: every session T2 launched is a nonfable lane entry, every claim event says nonfable" '[ "$(jq -r "[.sessions[] | .lane] | unique | join(\",\")" "$ACCOUNT_LANE_STATE/sessions.json")" = nonfable ] && [ "$(jq -r "select(.event==\"session_claim\") | .lane" "$ACCOUNT_LANE_STATE/events.jsonl" | sort -u | tr "\n" " ")" = "nonfable " ]'
ck "every launch row T2 wrote is claude-opus-5-5 on an Opus route with its class effort, on josephsyen or the reserve" '[ "$(jq -r "select(.decision==\"launch\" and (.task_id|startswith(\"T2-\"))) | [.route,.model,.effort] | join(\",\")" "$DEC" | sort -u | tr "\n" " ")" = "opus-high,claude-opus-5-5,high opus-xhigh,claude-opus-5-5,xhigh " ] && [ -z "$(jq -r "select(.decision==\"launch\" and (.task_id|startswith(\"T2-\"))) | .account" "$DEC" | grep -vxE "josephsyen|mcphost.dev")" ]'

# --- R4.6: outside FABLE_LAUNCH_TEST=1 the routing policy and the ledger cannot be overridden (private HOME; refused before anything runs)
P="$T/prod"; mkdir -p "$P"; echo '{"task_id":"T2-P","skill":"wwhtbt"}' >"$T/req.p.json"
prod(){ env -u FABLE_LAUNCH_TEST -u FABLE_RR_DIR -u FABLE_TOKEN_STORE -u FABLE_CLAUDE_BIN -u ACCOUNT_LANE_STATE -u ACCOUNT_LANE_POLICY -u ACCOUNT_LANE_TEST \
  -u ACCOUNT_LANE_NOW -u SKILL_ROUTE_POLICY -u SKILL_ROUTE_LEDGER_IDS -u SKILL_ROUTING_DECISIONS HOME="$P" SPYLOG="$T/spy.prod" "$@" "$L" --route-request "$T/req.p.json" -p x; }
: >"$T/spy.prod"; prod env SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" 2>"$T/err.pp"; prc=$?
ck "production mode with SKILL_ROUTE_POLICY set: 64, refused before anything runs (no row, no lane state, nothing started)" '[ "$prc" = 64 ] && grep -qF "SKILL_ROUTE_POLICY override refused" "$T/err.pp" && [ ! -e "$P/.local/state" ] && [ ! -s "$T/spy.prod" ]'
prod env SKILL_ROUTE_LEDGER_IDS="$T/ids.txt" 2>"$T/err.pl"; lrc=$?
ck "production mode with SKILL_ROUTE_LEDGER_IDS set: 64, refused before anything runs" '[ "$lrc" = 64 ] && grep -qF "SKILL_ROUTE_LEDGER_IDS override refused" "$T/err.pl" && [ ! -e "$P/.local/state" ] && [ ! -s "$T/spy.prod" ]'
prod env >/dev/null 2>"$T/err.p0"; crc=$?
ck "control: production mode without them is not refused by R4.6 (it fails later, on the private HOME's missing lane policy or credential; nothing started)" '[ "$crc" != 64 ] && [ "$crc" != 0 ] && ! grep -q "override refused" "$T/err.p0" && [ ! -s "$T/spy.prod" ]'
ck "SKILL_ROUTING_DECISIONS stays honoured in test mode (every T2 row is in the private log)" '[ "$(jq -r "select(.task_id==\"T2-A\") | .decision" "$DEC")" = launch ]'
ck "no token in stderr, spy args or any row" '! grep -q TOKEN- "$T"/err.* "$T"/spy.* "$DEC"'
flr_end
