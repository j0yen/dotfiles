#!/usr/bin/env bash
# One named test file for A1169: account routing by selected model, with a spy claude that records only the account NAME and a token fingerprint check.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"; L="$D/.local/bin/fable-launch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/store"; printf 'TOKEN-JOSEPH-xxxxxxxx' > "$T/store/josephsyen"; printf 'TOKEN-PM-yyyyyyyy' > "$T/store/jyen.pm"; chmod 600 "$T/store"/*
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; *) a=none;; esac
echo "spy acct=$a name=${FABLE_LAUNCH_ACCOUNT:-} args=$*" >> "$SPYLOG"
S
chmod +x "$T/claude"
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
run(){ : > "$SPYLOG"; "$L" "$@" 2>"$T/err"; echo $? > "$T/rc"; }
export FABLE_LAUNCH_EFFORT_REASON="ledger:A1300 named reasoning gap"; run --model claude-fable-5-1 --effort xhigh; unset FABLE_LAUNCH_EFFORT_REASON; ck "fable -> jyen.pm xhigh with reason" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--effort xhigh" $SPYLOG'
run --model fable; ck "fable alias, effort defaults high" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--effort high" $SPYLOG'
run --model=claude-fable-5-1 --effort max; ck "fable max without reason refused" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
for m in claude-sonnet-5-5 sonnet claude-haiku-5-5 haiku claude-opus-5-5 opus; do run --model $m --effort medium; ck "$m -> josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'; done
run --model claude-fable-9-9-9-9; ck "unknown fable-like refused" '[ "$(cat $T/rc)" = 64 ]'
run; ck "no model refused" '[ "$(cat $T/rc)" = 64 ]'
# helper isolation: parent env (Fable on jyen.pm) must not decide a helper's account
: > "$SPYLOG"; CLAUDE_CODE_OAUTH_TOKEN=TOKEN-PM-yyyyyyyy "$L" --helper --model claude-sonnet-5-5 2>/dev/null; ck "helper under PM parent env -> josephsyen" 'grep -q "acct=josephsyen" $SPYLOG'
run --helper --model fable; ck "helper cannot be fable" '[ "$(cat $T/rc)" = 64 ]'
# native child inherits parent env (documents the blocker for in-process Agent helpers)
: > "$SPYLOG"; FABLE_CLAUDE_BIN=/usr/bin/env CLAUDE_CODE_OAUTH_TOKEN=x true; ( export CLAUDE_CODE_OAUTH_TOKEN="TOKEN-PM-yyyyyyyy"; "$T/claude" --model sonnet ); ck "native child inherits PM token (isolation needs --helper)" 'grep -q "acct=jyen.pm" $SPYLOG'
# generic failures never switch: no fallback path exists; missing fable credential fails closed instead of using josephsyen
mv "$T/store/jyen.pm" "$T/store/x"; run --model fable; ck "missing PM cred fails closed (66), no josephsyen" '[ "$(cat $T/rc)" = 66 ] && [ ! -s $SPYLOG ]'; mv "$T/store/x" "$T/store/jyen.pm"
# no token in stderr or spy args
run --model fable; ck "no token in stderr/args" '! grep -q "TOKEN-" "$T/err" && ! grep -q "TOKEN-" $SPYLOG'
# duplicate resume guard
SID=11111111-2222-3333-4444-555555555555; sleep 30 --x-$SID 2>/dev/null & sp=$!; bash -c "exec -a 'claude --resume $SID' sleep 20" & dp=$!; sleep 0.3
run --model fable --resume $SID; ck "duplicate resume refused (73)" '[ "$(cat $T/rc)" = 73 ] && [ ! -s $SPYLOG ]'
kill $dp $sp 2>/dev/null; wait 2>/dev/null
run --model fable --resume 99999999-2222-3333-4444-555555555555; ck "no duplicate -> resume proceeds" 'grep -q "acct=jyen.pm" $SPYLOG'
run --model fable --model sonnet; ck "duplicate --model refused" '[ "$(cat $T/rc)" = 64 ] && [ ! -s $SPYLOG ]'
run --model sonnet --effort low --effort=high; ck "duplicate --effort refused" '[ "$(cat $T/rc)" = 64 ]'
: > "$SPYLOG"; FABLE_LAUNCH_TEST=0 FABLE_ACCOUNT=josephsyen "$L" --model fable 2>"$T/err"; rc=$?; ck "production FABLE_ACCOUNT override refused" '[ $rc = 64 ] && [ ! -s $SPYLOG ]'
: > "$SPYLOG"; FABLE_LAUNCH_TEST=0 FABLE_BASE_ACCOUNT=jyen.pm "$L" --model sonnet 2>"$T/err"; rc=$?; ck "production FABLE_BASE_ACCOUNT override refused" '[ $rc = 64 ] && [ ! -s $SPYLOG ]'
run --model fable; ck "marker exports account+model" 'grep -q "name=jyen.pm" $SPYLOG'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
