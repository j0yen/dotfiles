#!/usr/bin/env bash
# A1300/A1301 repair regressions R1-R6 for the independent review of c071fcc. Every state/home path is a temp dir; dummy credentials;
# fake claude; no real quota call. AL_ROOT=<tree> replays this file on other bytes (RED on c071fcc).
# Message fixtures: OBSERVED-IN-NOTES = shapes quoted in operator notes (secondhand, not captured here); SYNTHETIC = written for this test.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
export ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$D/tests/fixtures/account-lanes/policy.test.json}"  # source-policy fixture; the live policy is host config, not in this repo
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a args=$*" >> "$SPYLOG"
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
[ -z "${FAKE_OUT:-}" ] || printf '%s\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
S
chmod +x "$T/claude"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
run(){ : > "$SPYLOG"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc(){ cat "$T/rc"; }
lane(){ python3 -I "$P" "$@"; }
reset(){ rm -rf "$T/lanes" "$T/dec.jsonl"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
cls(){ printf '%s' "$1" | lane classify 2>/dev/null | jq -r .class 2>/dev/null; }
# random per run: a leftover process from another test can never match these ids in the launcher's ps duplicate guard
SID1=$(cat /proc/sys/kernel/random/uuid); SID2=$(cat /proc/sys/kernel/random/uuid); SID3=$(cat /proc/sys/kernel/random/uuid)

echo "== R1 strict quota contract"
ck "OBSERVED-IN-NOTES session limit = exhaustion" '[ "$(cls "You'"'"'ve hit your session limit · resets 5pm")" = exhaustion ]'
ck "OBSERVED-IN-NOTES weekly limit + date + tz = exhaustion" '[ "$(cls "You'"'"'ve hit your weekly limit · resets Nov 6, 1pm (America/Los_Angeles)")" = exhaustion ]'
ck "SYNTHETIC wrapper text with a prefix before the quota line is not the CLI's whole message = unknown" '[ "$(cls "429 usage_limit_reached: You'"'"'ve hit your session limit · resets 3am")" = unknown ]'
ck "SYNTHETIC transient rate limit is not exhaustion" '[ "$(cls "You'"'"'ve hit the rate limit, please retry")" != exhaustion ]'
ck "SYNTHETIC context limit is not exhaustion" '[ "$(cls "You have reached the maximum context limit")" != exhaustion ]'
ck "SYNTHETIC spend cap is not exhaustion (paid, never a fallback)" '[ "$(cls "You'"'"'ve hit your spend limit")" = paid_required ]'
ck "SYNTHETIC monthly/budget cap is not exhaustion" '[ "$(cls "You'"'"'ve hit your monthly limit, purchase more")" != exhaustion ]'
ck "SYNTHETIC bare 429 is transient" '[ "$(cls "API Error 429 too many requests")" = transient ]'
ck "SYNTHETIC quota phrase mixed with rate_limit_error = unknown" '[ "$(cls "You'"'"'ve hit your weekly limit; rate_limit_error overloaded")" = unknown ]'
ck "SYNTHETIC quota phrase mixed with auth = unknown" '[ "$(cls "You'"'"'ve hit your weekly limit 401 unauthorized")" = unknown ]'
LONG="$(printf 'The user wrote: You have hit your weekly limit. %.0s' $(seq 1 20))"
ck "SYNTHETIC long plain output quoting the phrase (model/tool text) = unknown" '[ "$(cls "$LONG")" = unknown ]'
SJ_TOOL='{"type":"user","message":{"content":[{"type":"tool_result","content":"You'"'"'ve hit your weekly limit · resets 5pm"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"done"}'
ck "SYNTHETIC stream-json: phrase only in tool output, successful terminal event = not exhaustion" '[ "$(cls "$SJ_TOOL")" != exhaustion ]'
SJ_ASSIST='{"type":"assistant","message":{"content":[{"type":"text","text":"You'"'"'ve hit your weekly limit"}]}}
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API Error: 500 internal server error"}'
ck "SYNTHETIC stream-json: phrase in assistant text, terminal error is a 500 = not exhaustion" '[ "$(cls "$SJ_ASSIST")" != exhaustion ]'
SJ_REAL='{"type":"user","message":"hi"}
{"type":"result","subtype":"error","is_error":true,"result":"You'"'"'ve hit your weekly limit · resets 5pm"}'
ck "SYNTHETIC stream-json: terminal error event carrying the quota line = exhaustion" '[ "$(cls "$SJ_REAL")" = exhaustion ]'
SJ_NOTERM='{"type":"assistant","message":{"content":[{"type":"text","text":"You'"'"'ve hit your weekly limit"}]}}'
ck "SYNTHETIC stream-json with no terminal event = not exhaustion" '[ "$(cls "$SJ_NOTERM")" != exhaustion ]'
reset; FAKE_RC=1 FAKE_OUT="$SJ_ASSIST" "$L" -p hi --output-format stream-json --model claude-fable-5-1 >/dev/null 2>&1
ck "headless failure whose output merely quotes the phrase mutates no quota state" '[ "$(nex)" = 0 ]'
reset; FAKE_RC=1 FAKE_ERR="You've hit the rate limit, please retry" "$L" -p hi --model claude-sonnet-5-5 >/dev/null 2>&1
ck "headless transient rate limit mutates no quota state" '[ "$(nex)" = 0 ]'
reset; FAKE_RC=1 FAKE_OUT="$SJ_REAL" "$L" -p hi --output-format stream-json --model claude-fable-5-1 >/dev/null 2>&1
ck "headless failure with a genuine terminal quota event records the trusted lane (fable on jyen.pm)" 'jq -e ".exhausted[\"jyen.pm|fable\"]" <(lane status) >/dev/null'

echo "== R2 unmapped resume"
reset; run --model claude-fable-5-1 --resume $SID3
ck "unmapped resume blocks (session_unmapped, rc 75, safe_boundary) and starts nothing" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ] && jq -e ".code==\"session_unmapped\" and .safe_boundary==true" $T/out >/dev/null'
ck "unmapped resume adopted nothing into state" '[ ! -e $T/lanes/sessions.json ] || jq -e ".sessions|has(\"$SID3\")|not" $T/lanes/sessions.json >/dev/null'
FABLE_LAUNCH_ADOPT_ACCOUNT=jyen.pm FABLE_LAUNCH_ADOPT_BY=hermes FABLE_LAUNCH_ADOPT_REASON="operator says it ran on pm" run --model claude-fable-5-1 --resume $SID3
ck "adoption with no verified prior launch evidence is refused" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ] && grep -q adopt_unverified $T/out'
jq -nc --arg s "$SID3" '{decision:"launch",session:$s,account:"jyen.pm"}' > "$T/dec.jsonl"
FABLE_LAUNCH_ADOPT_ACCOUNT=jyen.pm FABLE_LAUNCH_ADOPT_BY=hermes FABLE_LAUNCH_ADOPT_REASON="operator says it ran on pm" run --model claude-fable-5-1 --resume $SID3
ck "verified adoption still requires the unknown-effect ack (77), nothing started" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ]'
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="operator inspected effects" FABLE_LAUNCH_ADOPT_ACCOUNT=jyen.pm FABLE_LAUNCH_ADOPT_BY=hermes FABLE_LAUNCH_ADOPT_REASON="operator says it ran on pm" run --model claude-fable-5-1 --resume $SID3
ck "verified + audited + acked adoption runs on the VERIFIED account, audit row written" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q session_adopted $T/lanes/events.jsonl'
jq -nc --arg s "$SID2" '{decision:"launch",session:$s,account:"mcphost.dev"}' > "$T/dec.jsonl"
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="inspected effects ok" FABLE_LAUNCH_ADOPT_ACCOUNT=mcphost.dev FABLE_LAUNCH_ADOPT_BY=hermes FABLE_LAUNCH_ADOPT_REASON="verified from decision log" run --model claude-sonnet-5-5 --resume $SID2
ck "adoption into an account the lane does not permit (mcphost.dev non-Fable) is refused" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'

echo "== R3 unknown effect"
reset; run --model claude-fable-5-1 --session-id $SID1; run --model claude-fable-5-1 --resume $SID1
ck "interactive run that exited 0 (observed clean) resumes without ack" 'grep -q "acct=jyen.pm" $SPYLOG'
reset; FAKE_RC=3 FAKE_ERR="SYNTHETIC connect ECONNREFUSED 127.0.0.1:443" run -p x --model claude-fable-5-1 --session-id $SID1; run --model claude-fable-5-1 --resume $SID1
ck "headless network failure (non-zero exit) -> resume blocked 77 with no ack, nothing replayed" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ] && [ "$(nex)" = 0 ]'
ck "network failure created no exhaustion" '[ "$(nex)" = 0 ]'
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="inspected: read-only task" run --model claude-fable-5-1 --resume $SID1
ck "explicit audited ack resumes once" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q ack_unknown_effect.*true $T/lanes/events.jsonl'
reset; FAKE_RC=1 FAKE_ERR="SYNTHETIC 401 unauthorized" run -p x --model claude-fable-5-1 --session-id $SID1; run --model claude-fable-5-1 --resume $SID1
ck "auth failure also marks unknown effect" '[ "$(rc)" = 77 ]'
reset; FAKE_RC=1 FAKE_ERR="SYNTHETIC something odd" run -p x --model claude-sonnet-5-5 --session-id $SID1; run --model claude-sonnet-5-5 --resume $SID1
ck "unrecognised failure marks unknown effect" '[ "$(rc)" = 77 ]'
reset; FAKE_SLEEP=20 "$L" -p x --model claude-fable-5-1 --session-id $SID1 >/dev/null 2>&1 & lp=$!; sleep 1.5
kill -9 $lp 2>/dev/null; wait $lp 2>/dev/null; pkill -f "$T/claude" 2>/dev/null; sleep 0.3
run --model claude-fable-5-1 --resume $SID1
ck "supervisor killed mid-task (dead stale claim, no end record) -> 77, nothing replayed" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ]'
reset; FAKE_SLEEP=20 "$L" --model claude-fable-5-1 --session-id $SID1 >/dev/null 2>&1 & lp=$!; sleep 1.5
kill -9 $lp 2>/dev/null; wait $lp 2>/dev/null; pkill -f "$T/claude" 2>/dev/null; sleep 0.3
run --model claude-fable-5-1 --resume $SID1
ck "interrupted INTERACTIVE claim (killed) -> 77" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ]'
reset; run -p x --model claude-fable-5-1 --session-id $SID1; run --model claude-fable-5-1 --resume $SID1
ck "headless clean exit resumes without ack" 'grep -q "acct=jyen.pm" $SPYLOG'
reset; FAKE_SLEEP=20 "$L" --model claude-fable-5-1 --session-id $SID1 >/dev/null 2>&1 & lp=$!; sleep 1.5
run --model claude-fable-5-1 --resume $SID1
ck "resume while the interactive claim is alive = duplicate refused (73), not unknown-effect" '[ "$(rc)" = 73 ] && [ ! -s $SPYLOG ]'
kill $lp 2>/dev/null; wait $lp 2>/dev/null; pkill -f "$T/claude" 2>/dev/null
reset; FAKE_RC=1 FAKE_OUT="SYNTHETIC garbage" "$L" --model claude-fable-5-1 --session-id $SID2 >/dev/null 2>&1
ck "interactive non-zero exit marks unknown effect; exhaustion is NOT inferred from a TUI (declared unsupported)" 'jq -e ".sessions[\"$SID2\"].unknown_effect==true" $T/lanes/sessions.json >/dev/null && [ "$(nex)" = 0 ]'

echo "== R4 reset evidence"
reset; printf '%s' "Claude AI usage limit reached|1800003600" | lane record --account jyen.pm --lane fable >/dev/null; r=$?
ck "unobserved epoch-suffix legacy form is NOT trusted: unknown, rc 4, no state" '[ $r = 4 ] && [ "$(nex)" = 0 ]'
now=1800000000
for bad in 1799999000 0 -5 9999999999 abc 1800000000; do reset
  printf '%s' "You've hit your usage limit" | lane record --account jyen.pm --lane fable --reset-epoch "$bad" >/dev/null 2>&1
  ck "malformed/past/out-of-range --reset-epoch '$bad': exhaustion kept, reset stays unknown" '[ "$(jq -r ".exhausted[\"jyen.pm|fable\"].reset_at" <(lane status))" = null ] || [ "$(nex)" = 0 -a "$bad" = abc ]'
done
reset; printf '%s' "You've hit your usage limit" | lane record --account jyen.pm --lane fable --reset-epoch 1800003600 >/dev/null
ck "strict future epoch from a trusted caller is accepted" '[ "$(jq -r ".exhausted[\"jyen.pm|fable\"].reset_at" <(lane status))" = 1800003600 ]'
printf '%s' "You've hit your usage limit" | lane record --account jyen.pm --lane fable --reset-epoch 1799000000 >/dev/null
ck "a later past/invalid reset never clears or shortens the known reset" '[ "$(jq -r ".exhausted[\"jyen.pm|fable\"].reset_at" <(lane status))" = 1800003600 ]'
reset; printf '%s' "You've hit your usage limit" | lane record --account jyen.pm --lane fable >/dev/null
run --model claude-fable-5-1; ck "unknown reset keeps exhaustion (mcphost.dev), no auto-clear" 'grep -q "acct=mcphost.dev" $SPYLOG'

echo "== R6 trusted lane, atomic claim, audit account"
reset; printf '%s' "You've hit your weekly limit" | lane record --account josephsyen --lane nonfable >/dev/null; r=$?
ck "lane is the trusted --lane (nonfable on josephsyen), never text-derived: josephsyen|nonfable recorded" '[ $r = 0 ] && jq -e ".exhausted[\"josephsyen|nonfable\"] and (.exhausted|length==1)" <(lane status) >/dev/null'
printf '%s' "You've hit your weekly limit" | lane record --account josephsyen >/dev/null; r=$?
ck "record without trusted lane/model metadata refused (64)" '[ $r = 64 ]'
reset; lane record --account jyen.pm --lane fable <<<"You've hit your usage limit" >/dev/null
lane session-claim --session $SID1 --account jyen.pm --lane fable --pid $$ >"$T/o"
ck "stale select result (jyen.pm) passed to a fresh claim after exhaustion is overridden atomically -> mcphost.dev" 'jq -e ".account==\"mcphost.dev\"" $T/o >/dev/null && grep -q selection_changed $T/lanes/events.jsonl'
reset; for a in jyen.pm mcphost.dev; do lane record --account $a --lane fable <<<"You've hit your usage limit" >/dev/null; done
lane session-claim --session $SID1 --lane fable --pid $$ >"$T/o"; r=$?
ck "fresh claim with the whole lane exhausted blocks (75), maps nothing" '[ $r = 75 ] && [ ! -e $T/lanes/sessions.json ] || ! jq -e ".sessions|has(\"$SID1\")" $T/lanes/sessions.json >/dev/null'
# routed pinned resume: decision row account is the PINNED account
mkdir -p "$T/ev"; echo e > "$T/ev/e.md"; printf 'A1300\n' > "$T/ids"
export SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" SKILL_ROUTE_LEDGER_IDS="$T/ids"
reset; lane record --account jyen.pm --lane fable <<<"You've hit your usage limit" >/dev/null
echo '{"task_id":"A1300","skill":"5whysandrhyme"}' > "$T/req.json"
: > "$SPYLOG"; "$L" --route-request "$T/req.json" -p hi >/dev/null 2>&1
S1="$(jq -r '.sessions|keys[0]' $T/lanes/sessions.json)"
lane clear --account jyen.pm --lane fable --by t --reason "test clear audited" >/dev/null
: > "$SPYLOG"; "$L" --route-request "$T/req.json" --resume "$S1" -p again >/dev/null 2>&1
ck "pinned routed resume ran on the recorded account (mcphost.dev)" 'grep -q "acct=mcphost.dev" $SPYLOG'
ck "decision-log row for the pinned resume names the PINNED account, not the policy pre-selection" '[ "$(jq -rs "map(select(.decision==\"launch\" and .resume==true))|last|.account" $SKILL_ROUTING_DECISIONS)" = mcphost.dev ]'

echo "== R5 callers (no live side effects)"
# watcher + rotate behavioral tests run the REAL scripts under the lib's throwaway-HOME harness, policy via ACCOUNT_LANE_POLICY in a temp dir
(
  . "$D/.local/lib/fleet-token-lib.sh"; set +e; set +u 2>/dev/null; R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
  ft_st_env "$R"; FT_ST_T="$R"; unset INVOCATION_ID
  W="$D/.local/bin/fleet-token-429-watch.sh"; RT="$D/.local/bin/fleet-token-rotate.sh"
  NOW=1790000000; export FLEET_TOKEN_NOW_EPOCH=$NOW ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=$NOW ACCOUNT_LANE_STATE="$R/lanes"
  export WP_STATE="$R/home/.local/state/watcher-premise" WP_DECIDE_BIN="$R/fakes/record" FLEET_TOKEN_429_EXPIRES="$(date -d '+1 day' -Is)" FLEET_TOKEN_ROTATE_CMD="$RT"
  cat > "$R/pol.json" <<'J'
{"version":1,"lanes":{"fable":{"order":["acctF","mcphost.dev"]},"nonfable":{"primaries":["acctA","acctC"],"reserve":["acctR"]}}}
J
  for a in acctA acctC acctR acctF mcphost.dev; do ft_st_store $a "canary-tok-7f3e9a-$a"; done
  printf 'acctA\nmcphost.dev\nacctC\n' > "$FT_CFG/ring"
  "$D/.local/bin/fleet-token-store.sh" current acctA >/dev/null
  fl(){ cat "$FAKE_LOG_DIR/$1.log" 2>/dev/null; }
  seats(){ for s in ctl rb r7; do printf '{"quota_wait_until":%s,"quota_account":"acctA"}\n' "$((NOW+7200))" > "$FT_DASH/$s-tick.json"; done; }
  tokj(){ jq -r "$1" "$FT_TOKJSON"; }
  q=0; qf=0; ckk(){ if eval "$2"; then q=$((q+1)); echo "PASS $1"; else qf=$((qf+1)); echo "FAIL $1"; fi; }
  seats; ACCOUNT_LANE_POLICY="$R/pol.json" "$W" >"$R/o" 2>"$R/e"
  ckk "watcher (policy installed): ring candidate mcphost.dev skipped for the non-Fable fleet token -> acctC" '[ "$(tokj .account)" = acctC ]'
  ckk "watcher records the limit in the nonfable lane of the limited account with the seat-tick reset" 'jq -e ".exhausted[\"acctA|nonfable\"].reset_at==$((NOW+7200))" <(ACCOUNT_LANE_POLICY="$R/pol.json" python3 -I "$D/.local/lib/account-lane.py" status) >/dev/null'
  ckk "watcher recorded only the nonfable lane (no fable entry)" '[ "$(jq -r "[.exhausted|keys[]|select(endswith(\"|fable\"))]|length" <(ACCOUNT_LANE_POLICY="$R/pol.json" python3 -I "$D/.local/lib/account-lane.py" status))" = 0 ]'
  # exhausted candidate skipped
  "$D/.local/bin/fleet-token-store.sh" current acctA >/dev/null; printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' > "$FT_TOKJSON"; rm -rf "$R/lanes" "$FT_STATE"/*.stamp "$FT_STATE"/blocked-until-* "$FT_ROTLOG" "$WP_STATE"; printf 'acctA\nacctC\nacctR\n' > "$FT_CFG/ring"
  ACCOUNT_LANE_POLICY="$R/pol.json" python3 -I "$D/.local/lib/account-lane.py" record-structured --account acctC --lane nonfable --source seat-tick-quota-wait >/dev/null
  seats; ACCOUNT_LANE_POLICY="$R/pol.json" "$W" >"$R/o" 2>"$R/e"
  ckk "watcher (policy installed): exhausted nonfable candidate acctC skipped -> reserve acctR" '[ "$(tokj .account)" = acctR ]'
  # not enforced: unchanged legacy behaviour
  printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' > "$TOKJ" 2>/dev/null; printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' > "$FT_TOKJSON"; rm -rf "$R/lanes" "$FT_STATE"/*.stamp "$FT_STATE"/blocked-until-* "$FT_ROTLOG" "$WP_STATE"; printf 'acctA\nmcphost.dev\nacctC\n' > "$FT_CFG/ring"
  seats; env -u ACCOUNT_LANE_POLICY "$W" >"$R/o" 2>"$R/e"
  ckk "no policy installed: legacy ring behaviour unchanged (mcphost.dev is the next candidate)" '[ "$(tokj .account)" = mcphost.dev ] && [ ! -e "$R/lanes/state.json" ]'
  # rotate
  printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' > "$FT_TOKJSON"; : > "$FAKE_LOG_DIR/place.log"; rm -f "$FAKE_LOG_DIR/verify.log"
  ACCOUNT_LANE_POLICY="$R/pol.json" "$RT" mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate: mcphost.dev for the non-Fable fleet token REFUSED (rc 1), nothing verified or placed" '[ $rc = 1 ] && [ -z "$(fl place)" ] && [ -z "$(fl verify)" ] && [ "$(tokj .account)" = acctA ]'
  ACCOUNT_LANE_POLICY="$R/pol.json" "$RT" mcphost.dev --by t --trigger joe-20261108 >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate: a joe- trigger does NOT lift the permission rule" '[ $rc = 1 ] && [ -z "$(fl place)" ]'
  ACCOUNT_LANE_POLICY="$R/pol.json" "$RT" --check mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate --check refuses mcphost.dev too (switch-at arm time)" '[ $rc = 1 ]'
  ACCOUNT_LANE_POLICY="$R/pol.json" ACCOUNT_LANE_STATE="$R/l2" python3 -I "$D/.local/lib/account-lane.py" record-structured --account acctC --lane nonfable --source seat-tick-quota-wait >/dev/null
  ACCOUNT_LANE_POLICY="$R/pol.json" ACCOUNT_LANE_STATE="$R/l2" "$RT" acctC --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate: exhausted nonfable lane refused for a hand trigger" '[ $rc = 1 ] && [ -z "$(fl place)" ]'
  ACCOUNT_LANE_POLICY="$R/pol.json" ACCOUNT_LANE_STATE="$R/l2" "$RT" acctC --by t --trigger joe-20261108 >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate: Joe's word lifts an EXHAUSTED lane (like a block)" '[ $rc = 0 ] && [ "$(tokj .account)" = acctC ]'
  env -u ACCOUNT_LANE_POLICY "$RT" mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "rotate: no policy installed = legacy behaviour (rotation allowed)" '[ $rc = 0 ]'
  echo "sub pass=$q fail=$qf" > "$T/sub.txt"; [ $qf = 0 ]
) > "$T/sub.out" 2>&1
cat "$T/sub.out" | grep -E "^(PASS|FAIL)"; sp=$(grep -c ^PASS "$T/sub.out"); sf=$(grep -c ^FAIL "$T/sub.out"); p=$((p+sp)); f=$((f+sf))
# ctl-launch behavioral (fake claude, temp HOME)
CH="$T/ch"; mkdir -p "$CH/.local/lib" "$CH/.config/wm-decide" "$CH/.config/fleet-token/store" "$CH/wake"
cp "$D/.local/lib/ctl-model-policy.sh" "$D/.local/lib/aide-lane.sh" "$CH/.local/lib/"
echo '{"ctl":{"model":"claude-sonnet-5-5","effort":"medium"}}' > "$CH/.config/wm-decide/seat-model-hold.json"
for a in josephsyen jyen.pm mcphost.dev; do cp "$T/store/$a" "$CH/.config/fleet-token/store/$a"; done
cl(){ : > "$SPYLOG"; HOME="$CH" XDG_CONFIG_HOME="$CH/.config" AIDE_CLAUDE_BIN="$T/claude" AIDE_WAKE_DIR="$CH/wake" AIDE_CLAUDE_JSON="$CH/none.json" ANTHROPIC_API_KEY=sk-DUMMY "$D/.local/bin/ctl-launch.sh" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
reset; cl --account mcphost.dev -p x
ck "ctl-launch --account mcphost.dev (non-Fable ctl model) refused rc 75, nothing started" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'
cl --account josephsyen -p x
ck "ctl-launch --account josephsyen allowed, selected token only, inherited API key scrubbed" '[ "$(rc)" = 0 ] && grep -q "acct=josephsyen" $SPYLOG && ! grep -q sk-DUMMY $SPYLOG'
lane record-structured --account josephsyen --lane nonfable --source seat-tick-quota-wait >/dev/null
cl --account josephsyen -p x; ck "ctl-launch refuses an account whose nonfable lane is exhausted" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'
cl --account jyen.pm -p x; ck "ctl-launch allows jyen.pm for the nonfable lane (reserve; its Fable state is separate)" '[ "$(rc)" = 0 ] && grep -q "acct=jyen.pm" $SPYLOG'
# fable-review goes through the launcher by default
FR="$D/.local/bin/fable-review.sh"; echo "# page" > "$T/page.md"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo "VERDICT: APPROVE"\n' > "$T/claude2"; chmod +x "$T/claude2"
cat > "$T/wmd" <<'X'
#!/usr/bin/env bash
echo d-20261108-000000-aide-ab12
X
chmod +x "$T/wmd"
reset; : > "$SPYLOG"; (unset FABLE_REVIEW_CLAUDE; FABLE_REVIEW_LAUNCH=env FABLE_REVIEW_OUT="$T/fr.txt" WM_DECIDE_BIN="$T/wmd" FABLE_CLAUDE_BIN="$T/claude" FAKE_OUT="VERDICT: APPROVE" "$FR" "$T/page.md" >/dev/null 2>&1)
ck "fable-review default path runs through fable-launch.sh (policy account jyen.pm, fable model, high)" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--model claude-fable-5-1" $SPYLOG && grep -q -- "--effort high" $SPYLOG'
lane record --account jyen.pm --lane fable <<<"You've hit your usage limit" >/dev/null; lane record --account mcphost.dev --lane fable <<<"You've hit your usage limit" >/dev/null
: > "$SPYLOG"; (unset FABLE_REVIEW_CLAUDE; FABLE_REVIEW_LAUNCH=env FABLE_REVIEW_OUT="$T/fr.txt" WM_DECIDE_BIN="$T/wmd" FABLE_CLAUDE_BIN="$T/claude" "$FR" "$T/page.md" >/dev/null 2>&1)
ck "fable-review with the Fable lane exhausted everywhere starts nothing (no inherited-token bypass)" '[ ! -s $SPYLOG ]'

echo "== isolation"
ck "no live HOME state written by this file" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
ck "no token or evidence text in lane state" '! grep -rq "TOKEN-\|canary-tok" "$T/lanes" 2>/dev/null'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
