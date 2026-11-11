#!/usr/bin/env bash
# A1300/A1301 final bounded deltas F1-F4 (+F2 observed fixtures) from REPAIR-DELTA-REVIEW. Temp HOME/state, dummy credentials, fake claude.
# AL_ROOT=<tree> replays on other bytes (RED on 2e03528). Fixture provenance: tests/fixtures/account-lanes/README.md.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
export ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$D/tests/fixtures/account-lanes/policy.test.json}"  # source-policy fixture; the live policy is host config, not in this repo
FX="${AL_FIXTURES:-$(cd "$(dirname "$0")" && pwd)/fixtures/account-lanes}"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"; REALHOME="$HOME"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a args=$*" >> "$SPYLOG"
if [ -n "${FAKE_TRAP:-}" ]; then
  trap 'echo INT >> "$INTLOG"; exit 130' INT; trap 'echo TERM >> "$INTLOG"; exit 143' TERM
  for i in $(seq 1 100); do sleep 0.2; done; exit 0
fi
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
[ -z "${FAKE_OUT:-}" ] || printf '%b\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%b\n' "$FAKE_ERR" >&2
[ -z "${FAKE_KILL:-}" ] || kill -9 $$
exit "${FAKE_RC:-0}"
S
chmod +x "$T/claude"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" INTLOG="$T/int.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
run(){ : > "$SPYLOG"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc(){ cat "$T/rc"; }
lane(){ python3 -I "$P" "$@"; }
reset(){ rm -rf "$T/lanes" "$T/dec.jsonl" "$INTLOG"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
cls(){ printf '%s' "$1" | lane classify 2>/dev/null | jq -r .class 2>/dev/null; }
U(){ cat /proc/sys/kernel/random/uuid; }
WHOLE="You've hit your usage limit"; QUOTED="Sure. The error said: You've hit your usage limit"

echo "== F1 untrusted model output never retires a lane"
ck "reviewer example classifies unknown, not exhaustion" '[ "$(cls "$QUOTED")" = unknown ]'
hl(){ reset; "$L" -p hi --model claude-sonnet-5-5 "$@" >/dev/null 2>&1; }   # env FAKE_* set by caller
FAKE_RC=124 FAKE_OUT="$QUOTED" hl;  ck "reviewer example: rc124 + quoted stdout -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$QUOTED" hl;    ck "rc1 + quoted stdout -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_ERR="$QUOTED" hl;    ck "rc1 + quoted stderr -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="partial model answer" FAKE_ERR="$QUOTED" hl; ck "mixed: partial stdout + quoted stderr -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$WHOLE" FAKE_ERR="warning: something" hl; ck "mixed: whole line on stdout but stderr non-empty -> no state (untrusted channel mix)" '[ "$(nex)" = 0 ]'
FAKE_RC=124 FAKE_OUT="$WHOLE" hl;   ck "rc124 (timeout kill) + whole line on stdout -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=143 FAKE_OUT="$WHOLE" hl;   ck "rc143 (SIGTERM) + whole line -> no state" '[ "$(nex)" = 0 ]'
FAKE_KILL=1 FAKE_OUT="$WHOLE" hl;   ck "child killed by signal (rc -9) + whole line -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="partial answer\n$WHOLE" hl; ck "partial answer then the whole line on stdout (2 lines) -> no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$WHOLE" hl;     ck "F1 residual: exact bare phrase alone on stdout with rc1 does NOT retire the lane (stdout is the model channel; plain stdout quota shape unobserved)" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="You've hit your weekly limit · resets Nov 2, 8pm (America/Los_Angeles)" hl; ck "F1 residual: an exact OBSERVED-wording line on stdout (rc1) is also not inferred" '[ "$(nex)" = 0 ]'
FAKE_RC=2 FAKE_OUT="$WHOLE" hl;     ck "F1 residual: exact phrase on stdout with another non-zero rc" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_ERR="$WHOLE" hl;     ck "trustworthy full stderr (exactly one whole line, rc1) still records" 'jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null'
FAKE_RC=1 FAKE_OUT="partial model text" FAKE_ERR="You've hit your weekly limit · resets Nov 2, 8pm (America/Los_Angeles)" hl
ck "rc1 + the whole message alone on stderr (stdout partial text ignored) -> recorded" 'jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null'
SJQ='{"type":"result","subtype":"error","is_error":true,"result":"Sure. The error said: You'"'"'ve hit your usage limit"}'
FAKE_RC=1 FAKE_OUT="$SJQ" hl --output-format stream-json; ck "stream-json terminal error whose text merely quotes the phrase -> no state" '[ "$(nex)" = 0 ]'
SJW='{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage limit"}'
FAKE_RC=1 FAKE_OUT="$SJW" hl --output-format stream-json --no-session-persistence; ck "stream-json terminal error that IS the whole message -> recorded (structured path retained)" 'jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null'

echo "== F2 observed fixtures (read-only provenance in tests/fixtures/account-lanes/README.md)"
n=0; okc=0; okr=0
while IFS= read -r line; do
  n=$((n+1)); txt="$(jq -r .text <<<"$line")"; ts="$(jq -r .saved_ts <<<"$line")"; ep="$(date -d "$ts" +%s)"
  [ "$(cls "$txt")" = exhaustion ] && okc=$((okc+1))
  reset; printf '%s' "$txt" | ACCOUNT_LANE_NOW=$ep lane record --account josephsyen --lane nonfable >/dev/null
  r="$(jq -r '.exhausted["josephsyen|nonfable"].reset_at' <(ACCOUNT_LANE_NOW=$ep lane status))"
  [ "$r" != null ] && [ "$r" -gt "$ep" ] && okr=$((okr+1))
done < "$FX/observed-quota.jsonl"
ck "OBSERVED quota texts (4 saved CLI records) all classify as exhaustion" '[ "$n" = 4 ] && [ "$okc" = 4 ]'
ck "OBSERVED quota texts parse a future reset relative to their saved timestamp" '[ "$okr" = 4 ]'
ck "OBSERVED fixture records carry source+timestamp provenance and the rate_limit category (category alone is not trusted)" 'jq -es "all(.[]; .source and .saved_ts and .error==\"rate_limit\" and .isApiErrorMessage==true)" "$FX/observed-quota.jsonl" >/dev/null'
OKJ="$(jq -c .event "$FX/observed-result-success.json")"
ck "OBSERVED successful stream-json terminal result is never exhaustion" '[ "$(cls "$OKJ")" != exhaustion ]'
for u in "You've hit your limit · resets 5pm" "Claude usage limit reached. Your limit will reset at 3pm" "5-hour limit reached ∙ resets 3pm" "Weekly limit reached ∙ resets Nov 12, 1pm" "You've hit your org's monthly usage limit" "Claude AI usage limit reached|1800003600"; do
  ck "UNOBSERVED wording stays unknown (no regex widening): ${u:0:40}" '[ "$(cls "$u")" = unknown ]'
done

echo "== F3 installed guards fail closed without policy (real scripts)"
(
  . "$D/.local/lib/fleet-token-lib.sh"; set +e; set +u 2>/dev/null; R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
  ft_st_env "$R"; FT_ST_T="$R"; unset INVOCATION_ID
  RT="$D/.local/bin/fleet-token-rotate.sh"; W="$D/.local/bin/fleet-token-429-watch.sh"
  NOW=1790000000; export FLEET_TOKEN_NOW_EPOCH=$NOW ACCOUNT_LANE_STATE="$R/lanes"
  export WP_STATE="$R/home/.local/state/watcher-premise" WP_DECIDE_BIN="$R/fakes/record" FLEET_TOKEN_429_EXPIRES="$(date -d '+1 day' -Is)" FLEET_TOKEN_ROTATE_CMD="$RT"
  for a in acctA acctC mcphost.dev; do ft_st_store $a "canary-tok-7f3e9a-$a"; done
  "$D/.local/bin/fleet-token-store.sh" current acctA >/dev/null
  q=0; qf=0; ckk(){ if eval "$2"; then q=$((q+1)); echo "PASS $1"; else qf=$((qf+1)); echo "FAIL $1"; fi; }
  tokj(){ jq -r "$1" "$FT_TOKJSON"; }
  # legacy: nothing installed
  unset ACCOUNT_LANE_POLICY
  "$RT" --check mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "legacy tree (no tool, no policy): rotate --check mcphost.dev behaves as before (rc 0)" '[ $rc = 0 ]'
  # installed tool, no policy
  mkdir -p "$HOME/.local/lib"; cp "$D/.local/lib/account-lane.py" "$HOME/.local/lib/"
  "$RT" --check mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "tool installed, policy missing: rotate --check REFUSES (rc 1) with an actionable warning" '[ $rc = 1 ] && grep -q "WARNING: account lane policy NOT in force" "$R/e" && grep -q "restoring the previous scripts" "$R/e"'
  "$RT" acctC --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "tool installed, policy missing: even an ordinary allowed account is refused, nothing placed" '[ $rc = 1 ] && [ -z "$(cat "$FAKE_LOG_DIR/place.log" 2>/dev/null)" ] && [ "$(tokj .account)" = acctA ]'
  "$RT" mcphost.dev --by t --trigger joe-20261108 >"$R/o" 2>"$R/e"; rc=$?
  ckk "tool installed, policy missing: a joe- trigger does not bypass the missing policy" '[ $rc = 1 ] && [ "$(tokj .account)" = acctA ]'
  # unreadable policy path
  ACCOUNT_LANE_POLICY="$R/nope.json" "$RT" --check mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "named policy path unreadable: refused" '[ $rc = 1 ] && grep -q WARNING "$R/e"'
  echo '{ not json' > "$R/bad.json"; ACCOUNT_LANE_POLICY="$R/bad.json" "$RT" --check acctC --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "malformed policy: refused (tool state_invalid), not permitted" '[ $rc = 1 ]'
  # watcher: broken -> every ring candidate skipped, no rotation
  printf 'acctA\nmcphost.dev\nacctC\n' > "$FT_CFG/ring"
  for s in ctl rb r7; do printf '{"quota_wait_until":%s,"quota_account":"acctA"}\n' "$((NOW+7200))" > "$FT_DASH/$s-tick.json"; done
  "$W" >"$R/o" 2>"$R/e"
  ckk "watcher with tool installed but no policy: no rotation (all candidates skipped, fail closed)" '[ "$(tokj .account)" = acctA ] && [ -z "$(cat "$FAKE_LOG_DIR/place.log" 2>/dev/null)" ]'
  # reviewed rollback: restore prior scripts = remove tool -> legacy again
  rm -f "$HOME/.local/lib/account-lane.py"
  "$RT" --check mcphost.dev --by t --trigger hand >"$R/o" 2>"$R/e"; rc=$?
  ckk "reviewed rollback (tool removed with the scripts) returns to legacy behaviour" '[ $rc = 0 ]'
  echo "sub $q $qf" > "$R/sub"; cp "$R/sub" "$T/sub1"; [ $qf = 0 ]
) > "$T/sub1.out" 2>&1
grep -E "^(PASS|FAIL)" "$T/sub1.out"; p=$((p+$(grep -c ^PASS "$T/sub1.out"))); f=$((f+$(grep -c ^FAIL "$T/sub1.out")))
CH="$T/ch"; mkdir -p "$CH/.local/lib" "$CH/.config/wm-decide" "$CH/.config/fleet-token/store" "$CH/wake" "$CH/.local/state/aide" "$CH/.cache/fleet-dash"
cp "$D/.local/lib/ctl-model-policy.sh" "$D/.local/lib/aide-lane.sh" "$CH/.local/lib/"
echo '{"ctl":{"model":"claude-sonnet-5-5","effort":"medium"}}' > "$CH/.config/wm-decide/seat-model-hold.json"
for a in josephsyen jyen.pm mcphost.dev; do cp "$T/store/$a" "$CH/.config/fleet-token/store/$a"; done
cl(){ : > "$SPYLOG"; env -u ACCOUNT_LANE_POLICY HOME="$CH" XDG_CONFIG_HOME="$CH/.config" AIDE_CLAUDE_BIN="$T/claude" AIDE_WAKE_DIR="$CH/wake" AIDE_CLAUDE_JSON="$CH/none.json" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
CLB="$D/.local/bin/ctl-launch.sh"
cl "$CLB" --account mcphost.dev -p x; ck "ctl-launch legacy tree (no tool, no policy): unchanged (mcphost.dev launches)" '[ "$(rc)" = 0 ]'
cp "$D/.local/lib/account-lane.py" "$CH/.local/lib/"
cl "$CLB" --account mcphost.dev -p x; ck "ctl-launch: tool installed, policy missing -> refused 75 + warning, nothing started" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ] && grep -q "WARNING.*NOT in force" $T/err'
cl "$CLB" --account josephsyen -p x; ck "ctl-launch: tool installed, policy missing -> even josephsyen refused (fail closed)" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'
mkdir -p "$CH/.config/account-lanes"; cp "$D/tests/fixtures/account-lanes/policy.test.json" "$CH/.config/account-lanes/policy.json"
cl "$CLB" --account josephsyen -p x; ck "ctl-launch: policy restored -> allowed" '[ "$(rc)" = 0 ] && grep -q "acct=josephsyen" $SPYLOG'
rm -f "$CH/.config/account-lanes/policy.json"
# ctl-account-follow with tool installed + no policy: logs the warning and does not follow
echo '{"account":"mcphost.dev"}' > "$CH/.cache/fleet-dash/token.json"
env -u ACCOUNT_LANE_POLICY HOME="$CH" AAF_TOKEN_JSON="$CH/.cache/fleet-dash/token.json" AAF_DRY=1 bash "$D/.local/bin/ctl-account-follow.sh" >"$T/out" 2>&1
ck "ctl-account-follow: tool installed, policy missing -> WARNING logged, no follow" 'grep -q "WARNING: account lane policy NOT in force" "$CH/.local/state/aide/follow.log" && ! grep -q "ctl-relaunch" "$T/out"'

echo "== F4a model metadata parsing"
reset; run --model=claude-sonnet-5-5; ck "fable-launch --model=X selects josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'
run --model claude-sonnet-5-5; ck "fable-launch --model X selects a non-Fable primary (round-robin: second fresh launch = jyen.tech)" 'grep -q "acct=jyen.tech" $SPYLOG'
run --model=claude-fable-5-1; ck "fable-launch --model=fable selects the Fable lane (jyen.pm)" 'grep -q "acct=jyen.pm" $SPYLOG'
run --model=claude-sonnet-5-5 --model claude-fable-5-1; ck "conflicting --model=X --model Y refused 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
run --model claude-sonnet-5-5 --model=claude-fable-5-1; ck "conflicting --model X --model=Y refused 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
run --model=claude-sonnet-5-5 --model=claude-sonnet-5-5; ck "duplicate --model=X --model=X refused 64" '[ "$(rc)" = 64 ]'
mkdir -p "$CH/.config/account-lanes"; cp "$D/tests/fixtures/account-lanes/policy.test.json" "$CH/.config/account-lanes/policy.json"
cl env ACCOUNT_LANE_POLICY="$CH/.config/account-lanes/policy.json" "$CLB" --account mcphost.dev --model=claude-sonnet-5-5 -p x; ck "ctl-launch --model=X form is lane-checked (mcphost.dev non-Fable refused 75)" '[ "$(rc)" = 75 ] && [ ! -s $SPYLOG ]'
cl env ACCOUNT_LANE_POLICY="$CH/.config/account-lanes/policy.json" "$CLB" --account josephsyen --model=claude-sonnet-5-5 -p x; ck "ctl-launch --model=X allowed on josephsyen" '[ "$(rc)" = 0 ]'
cl env ACCOUNT_LANE_POLICY="$CH/.config/account-lanes/policy.json" "$CLB" --account mcphost.dev --model=claude-fable-5-1 -p x; ck "ctl-launch --model=fable conflicts with ctl policy: refused 64 before any token" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'

echo "== F4c success never erases an independent unknown-effect signal"
reset; S1=$(U); FAKE_SLEEP=3 "$L" -p x --model claude-sonnet-5-5 --session-id $S1 >/dev/null 2>&1 & bp=$!; sleep 1
lane session-mark-unknown --session $S1 --by hermes --reason "operator saw partial write" >/dev/null 2>&1; wait $bp
ck "explicit external mark during a run that then exits 0 stays unknown_effect (not clean)" 'jq -e ".sessions[\"$S1\"].unknown_effect==true and .sessions[\"$S1\"].state!=\"clean\"" $T/lanes/sessions.json >/dev/null'
run --model claude-sonnet-5-5 --resume $S1; ck "and the next resume needs the ack (77)" '[ "$(rc)" = 77 ] && [ ! -s $SPYLOG ]'
lane session-mark-unknown --session $S1 --by x --reason short >/dev/null; ck "mark-unknown without an audit reason is refused" '[ $? = 75 ]'
reset; S2=$(U); FAKE_SLEEP=3 "$L" -p x --model claude-sonnet-5-5 --session-id $S2 >/dev/null 2>&1 & bp=$!; sleep 1
printf '%s' "$WHOLE" | lane record --account josephsyen --lane nonfable --session $S2 >/dev/null; wait $bp
ck "exhaustion evidence tagged with the session during a run that exits 0 is not erased by success" 'jq -e ".sessions[\"$S2\"].unknown_effect==true" $T/lanes/sessions.json >/dev/null && jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null'
reset; S3=$(U); run -p x --model claude-sonnet-5-5 --session-id $S3; ck "control: undisturbed rc 0 run is clean" 'jq -e ".sessions[\"$S3\"].state==\"clean\"" $T/lanes/sessions.json >/dev/null'

echo "== F4b signals"
# A launcher started with `&` from a non-interactive shell inherits SIGINT=ignored (real operators hit this too): the first probe leaves that
# disposition in place (the supervisor must still collect and forward), the pty probe and a default-disposition launch use SIG_DFL.
DFLPY='import os,signal,sys; [signal.signal(x,signal.SIG_DFL) for x in (signal.SIGINT,signal.SIGQUIT)]; os.execv(sys.argv[1], sys.argv[1:])'   # $! must be THIS pid, so no shell function in between
sigrun(){ reset; : > "$INTLOG"; : > "$SPYLOG"; FAKE_TRAP=1 python3 -I -c "$DFLPY" "$L" --model claude-sonnet-5-5 --session-id $1 >/dev/null 2>&1 & SP=$!
  for i in $(seq 1 50); do [ -s "$SPYLOG" ] && break; sleep 0.2; done; sleep 0.7; }   # signal only once the child runs under the supervisor
waitexit(){ for i in $(seq 1 40); do kill -0 $SP 2>/dev/null || return 0; sleep 0.2; done; return 1; }
S4=$(U); sigrun $S4; kill -INT $SP; waitexit; r=$?; kill -9 $SP 2>/dev/null; pkill -f "$T/claude" 2>/dev/null
ck "bare kill -INT of the supervisor is forwarded: child receives it once and the run ends" '[ $r = 0 ] && [ "$(grep -c INT $INTLOG)" = 1 ]'
ck "interrupted run is unknown_effect (resume needs ack)" 'jq -e ".sessions[\"$S4\"].unknown_effect==true" $T/lanes/sessions.json >/dev/null'
S5=$(U); sigrun $S5; kill -TERM $SP; waitexit; r=$?; kill -9 $SP 2>/dev/null; pkill -f "$T/claude" 2>/dev/null
ck "kill -TERM forwarded: child terminates, supervisor exits" '[ $r = 0 ] && [ "$(grep -c TERM $INTLOG)" = 1 ]'
run --model claude-sonnet-5-5 --resume $S5; ck "after TERM: resume blocked 77" '[ "$(rc)" = 77 ]'
reset; : > "$INTLOG"; : > "$SPYLOG"; FAKE_TRAP=1 "$L" --model claude-sonnet-5-5 >/dev/null 2>&1 & SP=$!
for i in $(seq 1 50); do [ -s "$SPYLOG" ] && break; sleep 0.2; done; sleep 0.7
kill -INT $SP; sleep 1; kill -0 $SP 2>/dev/null; alive=$?; kill -TERM $SP; waitexit; ex=$?; kill -9 $SP 2>/dev/null; pkill -f "$T/claude" 2>/dev/null
ck "launcher started with an inherited ignored SIGINT (nohup/& semantics): INT is collected, the child keeps the ignore disposition, TERM still ends the run" '[ $alive = 0 ] && [ $ex = 0 ] && ! grep -q INT $INTLOG'
if command -v script >/dev/null; then
  reset; S6=$(U); : > "$INTLOG"
  : > "$SPYLOG"; ( for i in $(seq 1 50); do [ -s "$SPYLOG" ] && break; sleep 0.2; done; sleep 0.7; printf '\003'; sleep 2 ) | FAKE_TRAP=1 timeout 10 script -qec "$L --model claude-sonnet-5-5" /dev/null >/dev/null 2>&1
  pkill -f "$T/claude" 2>/dev/null
  ck "pty ^C: delivered to the foreground group once (no double delivery by the supervisor)" '[ "$(grep -c INT $INTLOG)" = 1 ]'
else ck "pty ^C (script not available: skipped)" 'true'; fi

echo "== launcher ancestry: a shell wrapper carrying the session id is not a duplicate"
reset; S7=$(U); sh -c "\"$L\" --model claude-sonnet-5-5 --session-id $S7" >/dev/null 2>&1; r=$?
ck "launch under an 'sh -c ... --session-id <id>' wrapper (tmux/systemd style) runs (not 73)" '[ $r = 0 ] && jq -e ".sessions[\"$S7\"].state==\"clean\"" $T/lanes/sessions.json >/dev/null'
reset; S8=$(U); python3 -I -c 'import time; time.sleep(30)' --session-id $S8 & decp=$!
run --model claude-sonnet-5-5 --session-id $S8; ck "a genuinely unrelated process carrying the id is still refused (73)" '[ "$(rc)" = 73 ] && [ ! -s $SPYLOG ]'; builtin kill $decp 2>/dev/null
echo "== isolation"
ck "no live HOME state written by this file" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
