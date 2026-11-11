#!/usr/bin/env bash
# A1300/A1301 account exhaustion: per-account/model-lane state, launch selection, resume safety, scrubbing. Offline only.
# Fake claude + SYNTHETIC labelled provider errors + dummy credentials; no real quota call, no real home/state writes.
# AL_ROOT=<tree> replays the file against other bytes (RED on the base commit).
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
export ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$D/tests/fixtures/account-lanes/policy.test.json}"  # source-policy fixture; the live policy is host config, not in this repo
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a apikey=${ANTHROPIC_API_KEY:-unset} auth=${ANTHROPIC_AUTH_TOKEN:-unset} args=$*" >> "$SPYLOG"
[ -z "${FAKE_OUT:-}" ] || printf '%s\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
S
chmod +x "$T/claude"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
run(){ : > "$SPYLOG"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc(){ cat "$T/rc"; }
lane(){ python3 -I "$P" "$@"; }
reset(){ rm -rf "$T/lanes"; }
# Message shapes follow operator notes quoting the CLI ("You've hit your weekly limit · resets Nov 6, 1pm (America/Los_Angeles)", secondhand,
# not captured here); dates are moved to the test clock. The LANE always comes from trusted metadata (--lane), never from the text.
LIMIT_FABLE="You've hit your weekly limit · resets Feb 1, 9pm (America/Los_Angeles)"
LIMIT_GENERIC="You've hit your weekly limit · resets Feb 1, 9pm (America/Los_Angeles)"
LIMIT_NODATE="You've hit your usage limit"
exh(){ printf '%s' "$3" | lane record --account "$1" --lane "$2" >/dev/null; }
SID1=aaaaaaaa-1111-2222-3333-444444444444; SID2=bbbbbbbb-1111-2222-3333-444444444444

# --- selection ---
reset; run --model claude-fable-5-1; ck "fable not exhausted -> jyen.pm" 'grep -q "acct=jyen.pm" $SPYLOG'
run --model claude-sonnet-5-5; ck "nonfable default -> josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'
exh jyen.pm fable "$LIMIT_FABLE"
run --model claude-fable-5-1; ck "fable exhausted on jyen.pm -> mcphost.dev" 'grep -q "acct=mcphost.dev" $SPYLOG'
run --model claude-sonnet-5-5; ck "jyen.pm fable exhausted does not move nonfable (stays in the primary round-robin pool, never jyen.pm)" 'grep -Eq "acct=(josephsyen|jyen.tech)" $SPYLOG'
exh josephsyen nonfable "$LIMIT_GENERIC"
run --model claude-sonnet-5-5; ck "josephsyen exhausted -> jyen.tech" 'grep -q "acct=jyen.tech" $SPYLOG'
exh jyen.tech nonfable "$LIMIT_GENERIC"
run --model claude-sonnet-5-5; ck "both primaries exhausted -> jyen.pm nonfable despite its fable exhaustion" 'grep -q "acct=jyen.pm" $SPYLOG'
reset; exh jyen.tech nonfable "$LIMIT_GENERIC"; run --model claude-haiku-5-5; ck "only jyen.tech exhausted -> josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'
reset; exh jyen.pm nonfable "$LIMIT_GENERIC"; run --model claude-sonnet-5-5; ck "jyen.pm nonfable exhaustion irrelevant while primaries live" 'grep -q "acct=josephsyen" $SPYLOG'
run --model claude-fable-5-1; ck "jyen.pm nonfable exhaustion does not disable its fable lane" 'grep -q "acct=jyen.pm" $SPYLOG'
reset; for a in josephsyen jyen.tech jyen.pm; do exh $a nonfable "$LIMIT_GENERIC"; done
run --model claude-sonnet-5-5; ck "all nonfable lanes exhausted -> block 75, mcphost.dev NOT used" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ] && grep -q lane_exhausted $T/out'
reset; exh jyen.pm fable "$LIMIT_FABLE"; exh mcphost.dev fable "$LIMIT_FABLE"
run --model claude-fable-5-1; ck "fable exhausted everywhere -> block 75, no nonfable fallback" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'
run --helper --model claude-sonnet-5-5; ck "helper sonnet still served by josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'
lane check --account mcphost.dev --model claude-sonnet-5-5 >"$T/o"; ck "check: mcphost.dev not permitted for nonfable (ctl-launch/account-follow guard)" '[ $? = 75 ] || grep -q account_not_permitted $T/o'
lane check --account mcphost.dev --model claude-sonnet-5-5 >"$T/o"; r=$?; ck "check rc 75 + code account_not_permitted" '[ $r = 75 ] && grep -q account_not_permitted $T/o'
# --- resets / audited clear / no oscillation ---
reset; exh jyen.pm fable "$LIMIT_FABLE"; ra="$(jq -r '.exhausted["jyen.pm|fable"].reset_at' <(lane status))"
ck "reset parsed from reliable evidence (future epoch)" '[ "$ra" -gt 1800000000 ]'
ACCOUNT_LANE_NOW=$((ra-5)) run --model claude-fable-5-1; ck "before reset still mcphost.dev" 'grep -q "acct=mcphost.dev" $SPYLOG'
ACCOUNT_LANE_NOW=$((ra+5)) run --model claude-fable-5-1; ck "after reset back to jyen.pm" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q reset_expired $T/lanes/events.jsonl'
exh jyen.pm fable "$LIMIT_FABLE"
printf '%s' "You've hit your weekly limit · resets 11pm" | lane record --account jyen.pm --lane fable >/dev/null
ck "a later, earlier-resetting report never shortens a known reset" '[ "$(jq -r ".exhausted[\"jyen.pm|fable\"].reset_at" <(lane status))" = "$ra" ]'
reset; exh jyen.pm fable "$LIMIT_NODATE"
ACCOUNT_LANE_NOW=2000000000 run --model claude-fable-5-1; ck "unknown reset never auto-clears (fable stays on mcphost.dev)" 'grep -q "acct=mcphost.dev" $SPYLOG'
lane clear --account jyen.pm --lane fable >"$T/o"; ck "clear without audit refused" '[ $? = 75 ] || grep -q audit_required $T/o'
lane clear --account jyen.pm --lane fable --by hermes --reason "operator verified reset in console" >/dev/null; run --model claude-fable-5-1
ck "audited clear restores jyen.pm + audit row" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q cleared_by_hand $T/lanes/events.jsonl'
# --- malformed / stale state ---
reset; mkdir -p "$T/lanes"; echo '{not json' > "$T/lanes/state.json"; run --model claude-sonnet-5-5
ck "malformed state -> 76, nothing started, not treated as empty" '[ "$(rc)" = 76 ] && [ ! -s $SPYLOG ] && grep -q state_invalid $T/out'
echo '{"version":1,"exhausted":{"jyen.pm|fable":{"since":"x","reset_at":null}}}' > "$T/lanes/state.json"; run --model claude-fable-5-1
ck "wrong-typed entry -> 76" '[ "$(rc)" = 76 ] && [ ! -s $SPYLOG ]'
echo '{"version":2,"exhausted":{}}' > "$T/lanes/state.json"; run --model claude-fable-5-1; ck "unknown version -> 76" '[ "$(rc)" = 76 ]'
reset; echo '{"lanes":{}}' > "$T/pol.json"; ACCOUNT_LANE_POLICY="$T/pol.json" run --model claude-fable-5-1; ck "malformed policy -> 76" '[ "$(rc)" = 76 ] && [ ! -s $SPYLOG ]'
reset; echo '{"version":1,"exhausted":{"jyen.pm|fable":{"since":1,"reset_at":5}}}' > /dev/null; mkdir -p "$T/lanes"
echo '{"version":1,"exhausted":{"jyen.pm|fable":{"since":1,"reset_at":5,"source":"old"}}}' > "$T/lanes/state.json"; run --model claude-fable-5-1
ck "stale (reset long past) entry expires, jyen.pm used" 'grep -q "acct=jyen.pm" $SPYLOG'
# --- evidence classes: only a usage-limit message establishes exhaustion ---
reset
for pair in "auth|SYNTHETIC 401 Unauthorized: invalid token, please run /login" "network|SYNTHETIC connect ECONNREFUSED 127.0.0.1:443" "transient|SYNTHETIC 429 rate_limit_error: overloaded, try again later" "paid_required|SYNTHETIC extra usage credit balance required" "unknown|SYNTHETIC something odd"; do
  c="${pair%%|*}"; txt="${pair#*|}"
  : > "$SPYLOG"; FAKE_RC=1 FAKE_ERR="$txt" "$L" -p hi --model claude-fable-5-1 >/dev/null 2>"$T/err"; r=$?
  ck "$c failure: rc preserved, no exhaustion recorded" '[ $r = 1 ] && [ "$(jq -r ".exhausted|length" <(lane status))" = 0 ]'
  run --model claude-fable-5-1; ck "$c failure: next fable launch still jyen.pm (no fallback)" 'grep -q "acct=jyen.pm" $SPYLOG'
done
printf '%s' "You've hit your weekly limit but also 401 unauthorized" | lane record --account jyen.pm --lane fable >"$T/o"; ck "mixed limit+auth evidence = unknown, rc 4, no state" '[ $? = 4 ] || grep -q unknown $T/o'
ck "mixed evidence leaves no state" '[ "$(jq -r ".exhausted|length" <(lane status))" = 0 ]'
: > "$SPYLOG"; FAKE_RC=1 FAKE_ERR="$LIMIT_FABLE" "$L" -p hi --model claude-fable-5-1 >/dev/null 2>"$T/err"; r=$?
ck "headless limit failure: rc preserved + fable lane recorded" '[ $r = 1 ] && jq -e ".exhausted[\"jyen.pm|fable\"]" <(lane status) >/dev/null'
ck "run did not auto-switch this run: single spawn on jyen.pm" '[ "$(grep -c "^spy" $SPYLOG)" = 1 ] && grep -q "acct=jyen.pm" $SPYLOG'
ck "evidence text/token never stored" '! grep -rq "TOKEN-\|SYNTHETIC" "$T/lanes"'
reset; : > "$SPYLOG"; FAKE_RC=1 FAKE_ERR="$LIMIT_GENERIC" "$L" -p hi --model claude-sonnet-5-5 >/dev/null 2>&1
ck "generic limit on sonnet run records nonfable lane of josephsyen only" 'jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null && [ "$(jq -r ".exhausted|length" <(lane status))" = 1 ]'
# --- credentials ---
reset; mv "$T/store/mcphost.dev" "$T/store/x"; exh jyen.pm fable "$LIMIT_FABLE"; run --model claude-fable-5-1
ck "fallback credential missing -> 66, no other account used" '[ "$(rc)" = 66 ] && [ ! -s $SPYLOG ]'; mv "$T/store/x" "$T/store/mcphost.dev"
reset; : > "$SPYLOG"; ANTHROPIC_API_KEY=sk-DUMMY ANTHROPIC_AUTH_TOKEN=DUMMY-AUTH CLAUDE_CODE_OAUTH_TOKEN=TOKEN-JOSEPH-dummy0000 "$L" --model claude-fable-5-1 >/dev/null 2>"$T/err"
ck "inherited API key/auth token scrubbed, selected account OAuth wins over inherited OAuth" 'grep -q "acct=jyen.pm apikey=unset auth=unset" $SPYLOG && grep -q scrubbed $T/err'
ck "scrub message names variable, never value" '! grep -q "sk-DUMMY\|DUMMY-AUTH" $T/err'
ck "no paid/API fallback path in source" '! grep -q "ANTHROPIC_API_KEY=" "$L" && ! grep -qi "paid.*fallback.*enable" "$P"'
run --model claude-fable-5-1; ck "no token in stderr/spy args" '! grep -q "TOKEN-" "$T/err" && ! grep -q "TOKEN-" $SPYLOG'
# --- sessions: pinned resume, transfer block, duplicates, unknown effect ---
reset; run --model claude-fable-5-1 --session-id $SID1; ck "session mapped on jyen.pm" 'jq -e ".sessions[\"$SID1\"].account==\"jyen.pm\"" <(cat $T/lanes/sessions.json) >/dev/null'
run --model claude-fable-5-1 --resume $SID1; ck "pinned resume on recorded account" 'grep -q "acct=jyen.pm" $SPYLOG'
exh jyen.pm fable "$LIMIT_FABLE"
run --model claude-fable-5-1 --resume $SID1
ck "recorded account exhausted: transfer unsupported -> structured safe-boundary block 75, nothing started" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ] && jq -e ".code==\"account_transfer_unsupported\" and .safe_boundary==true and .from_account==\"jyen.pm\"" $T/out >/dev/null'
run --model claude-fable-5-1; ck "fresh launch honours policy (mcphost.dev)" 'grep -q "acct=mcphost.dev" $SPYLOG'
run --model claude-sonnet-5-5 --resume $SID1; ck "fable->nonfable model switch on a session refused (unsupported)" '[ "$(rc)" = 75 ] && grep -q model_switch_unsupported $T/out && [ ! -s $SPYLOG ]'
reset; run --model claude-fable-5-1 --session-id $SID2; exh jyen.pm fable "$LIMIT_FABLE"; lane clear --account jyen.pm --lane fable --by t --reason "test reset audited" >/dev/null
exh jyen.pm fable "$LIMIT_NODATE"; lane clear --account jyen.pm --lane fable --by t --reason "test reset audited" >/dev/null
run --model claude-fable-5-1 --resume $SID2; ck "policy account changed but recorded account usable -> pinned, no transfer" 'grep -q "acct=jyen.pm" $SPYLOG'
# unknown effect: exhaustion observed on a running session marks it
reset; run --model claude-fable-5-1 --session-id $SID1
: > "$SPYLOG"; FAKE_RC=1 FAKE_ERR="$LIMIT_FABLE" "$L" -p hi --model claude-fable-5-1 --resume $SID1 >/dev/null 2>&1
ck "exhaustion during a session marks unknown_effect" 'jq -e ".sessions[\"$SID1\"].unknown_effect==true" $T/lanes/sessions.json >/dev/null'
lane clear --account jyen.pm --lane fable --by t --reason "test reset audited" >/dev/null
run --model claude-fable-5-1 --resume $SID1; ck "unknown-effect resume blocked (77), no replay" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ] && grep -q unknown_effect $T/out'
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="operator inspected effects" run --model claude-fable-5-1 --resume $SID1; ck "explicit ack resumes (audited)" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q ack_unknown_effect $T/lanes/events.jsonl'
run --model claude-fable-5-1 --continue; ck "--continue (unmappable) refused" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
# duplicate / concurrency: claim is atomic and liveness is pid+starttime
reset; sleep 30 & sp=$!
lane session-claim --session $SID1 --lane fable --pid $sp >/dev/null; lane session-claim --session $SID1 --resume --lane fable --pid $$ >"$T/o"; r=$?
ck "second claim while holder alive refused (duplicate_live_session)" '[ $r = 75 ] && grep -q duplicate_live_session $T/o'
kill $sp; wait $sp 2>/dev/null; lane session-claim --session $SID1 --resume --lane fable --pid $$ >"$T/o"; r=$?; ck "claim after a dead unfinished holder is unknown-effect (77), not silent" '[ $r = 77 ]'
lane session-claim --session $SID1 --resume --lane fable --pid $$ --ack-unknown-effect >/dev/null; ck "claim after holder exit with explicit ack succeeds" '[ $? = 0 ]'
reset; for i in $(seq 1 12); do ( printf '%s' "$LIMIT_GENERIC" | lane record --account josephsyen --lane nonfable >/dev/null; printf '%s' "$LIMIT_FABLE" | lane record --account jyen.pm --lane fable >/dev/null ) & done; wait
ck "12 concurrent recorders leave valid JSON with both lanes" 'jq -e ".exhausted|length==2" <(lane status) >/dev/null && [ "$(grep -c "\"event\": \"exhausted\"" $T/lanes/events.jsonl)" = 24 ]'
reset; sleep 30 & sp=$!; pids=""; for i in 1 2 3 4 5 6; do ( lane session-claim --session $SID2 --lane fable --pid $sp >/dev/null; echo $? >> "$T/claims" ) & done; wait $(jobs -p | grep -v $sp) 2>/dev/null; sleep 0.5
ck "6 racing claims: exactly one winner" '[ "$(grep -c "^0$" $T/claims)" = 1 ] && [ "$(grep -c "^75$" $T/claims)" = 5 ]'; kill $sp 2>/dev/null
# --- native child helper ---
G="$D/.claude/hooks/fable-native-agent-guard.sh"
o="$(echo '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"x"}}' | FABLE_LAUNCH_ACCOUNT=mcphost.dev "$G")"; ck "native non-Fable child under mcphost.dev parent denied" 'echo "$o" | grep -q deny'
o="$(echo '{"tool_name":"Agent","tool_input":{"model":"claude-fable-5-1","effort":"high"}}' | FABLE_LAUNCH_ACCOUNT=mcphost.dev "$G")"; ck "native Fable high child under mcphost.dev allowed" '[ -z "$o" ]'
# --- ctl account follow: never follows the fleet onto a Fable-lane-only account ---
mkdir -p "$T/home/.config/fleet-token/store" "$T/home/.cache/fleet-dash"; cp "$T/store/mcphost.dev" "$T/home/.config/fleet-token/store/mcphost.dev"; echo '{"account":"mcphost.dev"}' > "$T/home/.cache/fleet-dash/token.json"
AAF_TOKEN_JSON="$T/home/.cache/fleet-dash/token.json" bash "$D/.local/bin/ctl-account-follow.sh" >/dev/null 2>&1
ck "account-follow declines mcphost.dev for ctl's non-Fable lane (logged)" 'grep -q "not usable by ctl" "$T/home/.local/state/aide/follow.log"'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
