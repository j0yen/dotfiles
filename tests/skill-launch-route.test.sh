#!/usr/bin/env bash
# skill-launch-route.test.sh: managed launcher (fable-launch.sh --route-request) for adaptive skill routing, ledger A1300.
# Spy claude; no provider call, no real credential. Run alone: bash tests/skill-launch-route.test.sh
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"; L="$D/.local/bin/fable-launch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/store"; printf 'TOKEN-JOSEPH-xxxxxxxx' >"$T/store/josephsyen"; printf 'TOKEN-TECH-zzzzzzzz' >"$T/store/jyen.tech"; printf 'TOKEN-PM-yyyyyyyy' >"$T/store/jyen.pm"; chmod 600 "$T/store"/*
cat >"$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; *) a=none;; esac
echo "spy acct=$a seat=${WM_SEAT:-} amodel=${ANTHROPIC_MODEL:-} task=${SKILL_ROUTE_TASK_ID:-} args=$*" >>"$SPYLOG"
S
chmod +x "$T/claude"
export FABLE_RR_DIR="$T/rr" FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
export SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"
printf 'A1300\n' >"$SKILL_ROUTE_LEDGER_IDS"; echo e >"$T/ev.md"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
req(){ printf '%s' "$1" >"$T/req.json"; }
run(){ : >"$SPYLOG"; "$L" --route-request "$T/req.json" "$@" 2>"$T/err"; echo $? >"$T/rc"; }
EVJ='["ledger:A1300","file:'"$T"'/ev.md"]'

req '{"task_id":"A1300","skill":"5whysandrhyme"}'; run -p hello
ck "5whys baseline -> jyen.pm fable high" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--model claude-fable-5-1" $SPYLOG && grep -q -- "--effort high" $SPYLOG'
ck "worker env drops ctl seat + model override" '! grep -q "seat=ctl" $SPYLOG && grep -q "task=A1300" $SPYLOG'
ck "decision row written (launch, task-linked, session)" '[ "$(jq -rs "last|[.decision,.task_id,.route,.account,(.session|length)]|join(\",\")" $SKILL_ROUTING_DECISIONS)" = "launch,A1300,fable-high,jyen.pm,36" ]'
ck "--session-id passed so the row links to the session" 'grep -q -- "--session-id " $SPYLOG'
WM_SEAT=ctl ANTHROPIC_MODEL=claude-opus-5-5 run -p x; ck "ctl markers in parent env are stripped" '! grep -q "seat=ctl" $SPYLOG && ! grep -q "amodel=claude-opus" $SPYLOG'

req '{"task_id":"B1","skill":"wwhtbt"}'; run -p hello
ck "wwhtbt baseline -> non-Fable pool sonnet medium" 'grep -qE "acct=(josephsyen|jyen.tech)" $SPYLOG && grep -q -- "--model claude-sonnet-5-5" $SPYLOG && grep -q -- "--effort medium" $SPYLOG'
ck "exactly one --model on the command line" '[ "$(grep -o -- "--model" $SPYLOG | wc -l)" = 1 ]'

req '{"task_id":"C1","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":'"$EVJ"'}}'; run -p hello
ck "evidence-authorized escalation -> fable xhigh on jyen.pm" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--effort xhigh" $SPYLOG'

for bad in '{"task_id":"D1","skill":"5whysandrhyme","escalation":{"reason":"complex","evidence":'"$EVJ"'}}' '{"task_id":"D2","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure"}}' '{"task_id":"D3","skill":"wwhtbt","decision_class":"nope"}' '{"skill":"wwhtbt"}' '{bad json'; do
  req "$bad"; run -p x; ck "denied route never starts: ${bad:0:60}" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
done
ck "denied route recorded as denied row" 'jq -es "map(select(.decision==\"denied\"))|length>=3" $SKILL_ROUTING_DECISIONS >/dev/null'
req '{"task_id":"E1","skill":"dream"}'; run -p x; ck "ungoverned skill refused by managed launcher (plain launch instead)" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
req '{"task_id":"E2","skill":"5whysandrhyme"}'; run --model claude-fable-5-1 --effort xhigh -p x; ck "conflicting --effort vs baseline refused" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
run --model claude-fable-5-1 --effort high -p x; ck "matching --model/--effort accepted" '[ "$(cat $T/rc)" = 0 ] && grep -q "acct=jyen.pm" $SPYLOG'
run --model claude-opus-5-5 -p x; ck "other model refused (no implicit fallback)" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
req '{"task_id":"E3","skill":"5whysandrhyme","requested":{"model":"claude-fable-5-1","effort":"max"}}'; run -p x; ck "fable max refused" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
mv "$T/store/jyen.pm" "$T/store/x"; req '{"task_id":"E4","skill":"5whysandrhyme"}'; run -p x; ck "missing PM cred fails closed, no josephsyen fallback" '[ "$(cat $T/rc)" = 66 ] && [ ! -s $SPYLOG ]'; mv "$T/store/x" "$T/store/jyen.pm"
ck "no token in stderr/args/decisions" '! grep -q TOKEN- "$T/err" "$SPYLOG" "$SKILL_ROUTING_DECISIONS"'
# injection: hostile task text is data
M="$T/pwned"; jq -cn --arg i '$(touch '"$M"')`touch '"$M"'`' '{task_id:"F1",skill:"wwhtbt",task_text:$i}' >"$T/req.json"; run -p x
ck "injection in request is inert" '[ ! -e "$M" ] && [ "$(cat $T/rc)" = 0 ]'
# same-session resume: same route ok, changed route refused
SID="$(jq -rs 'map(select(.task_id=="A1300" and .decision=="launch"))|first|.session' $SKILL_ROUTING_DECISIONS)"
req '{"task_id":"A1300","skill":"5whysandrhyme"}'; run --resume "$SID" -p again; ck "same-route resume proceeds and keeps the session id" '[ "$(cat $T/rc)" = 0 ] && grep -q -- "--resume $SID" $SPYLOG && ! grep -q -- "--session-id" $SPYLOG'
ck "resume row flagged resume=true" '[ "$(jq -rs "last|.resume" $SKILL_ROUTING_DECISIONS)" = true ]'
req '{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":'"$EVJ"'}}'; run --resume "$SID" -p again; ck "resume with a changed route refused" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
# duplicate dispatch: a live worker for the same task+skill blocks a second launch
DS=$(cat /proc/sys/kernel/random/uuid)   # unique per run: the duplicate guard greps the global process table, so a fixed id matched the 20 s sleep of a concurrent copy of this test
jq -nc --arg s "$DS" '{decision:"launch",task_id:"G1",skill:"wwhtbt",session:$s}' >>"$SKILL_ROUTING_DECISIONS"
bash -c "exec -a 'claude --resume $DS' sleep 20" & dp=$!; sleep 0.3
req '{"task_id":"G1","skill":"wwhtbt"}'; run -p x; ck "duplicate dispatch while worker live refused (73)" '[ "$(cat $T/rc)" = 73 ] && [ ! -s $SPYLOG ]'
kill $dp 2>/dev/null; wait 2>/dev/null
run -p x; ck "restart after worker exit proceeds" '[ "$(cat $T/rc)" = 0 ]'
# plain (non-route) launches unchanged
: >"$SPYLOG"; "$L" --model claude-fable-5-1 --effort high 2>"$T/err"; ck "plain Fable high accepted outside a managed route" '[ $? = 0 ] && grep -q -- "--effort high" $SPYLOG'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
