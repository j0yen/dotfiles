#!/usr/bin/env bash
# Installed-compatibility regressions (A1300/A1301 vs installed A1221/f8fe). The installed launcher round-robins fresh non-Fable launches over
# josephsyen/jyen.tech, parses --session-id=<id>, pins a resumed SID, fails closed on a missing credential WITHOUT rotating, and installed
# fable-review/native-agent-guard carry text/default changes. The lane extension must keep all of it while keeping lane exhaustion, unknown-effect,
# output-provenance and drain protections. SYNTHETIC; temp HOME/state, dummy credentials, fake CLI; no real call. AL_ROOT=<tree> replays other bytes.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
export ACCOUNT_LANE_POLICY="${ACCOUNT_LANE_POLICY:-$D/tests/fixtures/account-lanes/policy.test.json}"  # source-policy fixture; the live policy is host config, not in this repo
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home" "$T/rr"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a args=$*" >> "$SPYLOG"
S
chmod +x "$T/claude"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" FABLE_RR_DIR="$T/rr"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
reset(){ rm -rf "$T/lanes" "$T/dec.jsonl" "$T/rr"; mkdir -p "$T/rr"; : > "$SPYLOG"; }
run(){ : > "$SPYLOG"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
acct(){ sed -n 's/^spy acct=\([^ ]*\).*/\1/p' "$SPYLOG" | tail -1; }
rc(){ cat "$T/rc"; }
exh(){ lane record-structured --account "$1" --lane "$2" --source seat-tick-quota-wait --reset-epoch $((ACCOUNT_LANE_NOW+90000)) >/dev/null 2>&1; }
NF="--model claude-sonnet-5-5"

echo "== round-robin over the non-Fable primaries (installed A1221)"
reset; seq=""; for i in 1 2 3 4; do run $NF; seq="$seq $(acct)"; done
ck "fresh non-Fable launches alternate josephsyen, jyen.tech, josephsyen, jyen.tech" '[ "$seq" = " josephsyen jyen.tech josephsyen jyen.tech" ]'
reset; run --model claude-fable-5-1; run $NF; ck "a Fable launch does not advance the non-Fable slot" '[ "$(acct)" = josephsyen ]'
reset; exh jyen.tech nonfable; seq=""; for i in 1 2 3; do run $NF; seq="$seq $(acct)"; done
ck "jyen.tech non-Fable exhausted: every launch skips to josephsyen" '[ "$seq" = " josephsyen josephsyen josephsyen" ]'
reset; exh josephsyen nonfable; seq=""; for i in 1 2; do run $NF; seq="$seq $(acct)"; done
ck "josephsyen non-Fable exhausted: jyen.tech serves" '[ "$seq" = " jyen.tech jyen.tech" ]'
exh jyen.tech nonfable; run $NF; ck "both primaries exhausted: jyen.pm reserve non-Fable" '[ "$(acct)" = jyen.pm ]'
reset; exh jyen.pm fable; run $NF; ck "jyen.pm Fable exhaustion alone does not disable its non-Fable lane or the primaries" '[ "$(acct)" = josephsyen ]'
reset; rm -f "$T/store/jyen.tech"; run $NF; a1=$(acct); run $NF; r2=$(rc); a2=$(acct); run $NF; r3=$(rc)
ck "missing credential on the chosen slot: exit 66, nothing started, no fallback to the other account" '[ "$a1" = josephsyen ] && [ "$r2" = 66 ] && [ -z "$a2" ] && [ "$r3" = 66 ]'
ck "the slot is given back (not rotated): jyen.tech stays the next slot until restored" 'jq -e ".rr.nonfable==1" "$T/lanes/rr.json" >/dev/null'
printf 'TOKEN-TECH-dummy0000' > "$T/store/jyen.tech"; run $NF; ck "credential restored: jyen.tech serves next" '[ "$(acct)" = jyen.tech ]'
reset; for i in 1 2 3 4 5 6; do ( "$L" $NF >/dev/null 2>&1; true ) & done; wait
n1=$(grep -c "acct=josephsyen" "$SPYLOG"); n2=$(grep -c "acct=jyen.tech" "$SPYLOG"); ck "6 concurrent fresh launches split 3/3 (counter advanced atomically under the lane lock)" '[ "$n1" = 3 ] && [ "$n2" = 3 ]'

echo "== --session-id=<id> form (installed) and resume pin"
reset; S1=aaaaaaaa-2222-3333-4444-555555555551; run $NF --session-id=$S1; ck "--session-id=<id> reaches claude and the session is mapped" 'grep -q -- "--session-id=$S1" $SPYLOG && jq -e --arg s $S1 ".sessions[\$s].account==\"josephsyen\"" $T/lanes/sessions.json >/dev/null'
S2=aaaaaaaa-2222-3333-4444-555555555552; run $NF --session-id=$S2; ck "second fresh session lands on jyen.tech" '[ "$(acct)" = jyen.tech ]'
run $NF --session-id=$S2 ; ck "reusing a mapped id as a fresh --session-id=<id> is refused" '[ "$(rc)" != 0 ] && [ -z "$(acct)" ]'
run $NF --resume $S2; ck "resume stays pinned to the recorded account (jyen.tech) although the next slot is josephsyen" '[ "$(acct)" = jyen.tech ]'
run $NF --resume=$S1; ck "--resume=<id> form pinned to josephsyen" '[ "$(acct)" = josephsyen ]'

echo "== installed sid-map offered as the audited adoption for a pre-lane SID"
reset; S3=bbbbbbbb-2222-3333-4444-555555555553
run $NF --resume $S3; ck "no sid-map record: unmapped resume blocks (75), nothing started" '[ "$(rc)" = 75 ] && [ -z "$(acct)" ]'
printf '%s jyen.tech\n' $S3 > "$T/rr/sid-map"
run $NF --resume $S3; ck "sid-map record but no prior launch row in the evidence log: adoption unverified, blocks (75)" '[ "$(rc)" = 75 ] && [ -z "$(acct)" ]'
printf '{"decision":"launch","session":"%s","account":"jyen.tech"}\n' $S3 > "$T/dec.jsonl"
run $NF --resume $S3; ck "verified record but unknown effect: blocks 77 until acked" '[ "$(rc)" = 77 ] && [ -z "$(acct)" ]'
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="inspected, nothing mutating" run $NF --resume $S3; ck "verified + acked: resumes on the recorded jyen.tech" '[ "$(rc)" = 0 ] && [ "$(acct)" = jyen.tech ]'
S4=bbbbbbbb-2222-3333-4444-555555555554; printf '%s mcphost.dev\n' $S4 > "$T/rr/sid-map"; printf '{"decision":"launch","session":"%s","account":"mcphost.dev"}\n' $S4 >> "$T/dec.jsonl"
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT="x inspected" run $NF --resume $S4; ck "sid-map naming a non-permitted account for the lane (mcphost.dev non-Fable) is refused" '[ "$(rc)" != 0 ] && [ -z "$(acct)" ]'
S5=bbbbbbbb-2222-3333-4444-555555555555; printf '%s jyen.pm\n' $S5 > "$T/rr/sid-map"
run --model claude-fable-5-1 --resume $S5; ck "Fable resume never uses the sid-map (non-Fable pool record only): blocks" '[ "$(rc)" = 75 ] && [ -z "$(acct)" ]'

echo "== production overrides and header/duplicate behaviour"
: > "$SPYLOG"; env -u ACCOUNT_LANE_STATE FABLE_LAUNCH_TEST=0 FABLE_RR_DIR=/tmp/x "$L" $NF >/dev/null 2>&1; r=$?; ck "production FABLE_RR_DIR override refused (64), nothing started" '[ $r = 64 ] && [ ! -s $SPYLOG ]'

echo "== installed fable-native-agent-guard text and lane behaviour"
G="$D/.claude/hooks/fable-native-agent-guard.sh"
gin(){ printf '{"tool_name":"Agent","tool_input":{"model":"%s"}}' "$1"; }
o=$(gin sonnet | FABLE_LAUNCH_ACCOUNT=jyen.pm bash "$G"); ck "jyen.pm parent: non-Fable child denied with the round-robin helper wording (installed)" 'grep -q "josephsyen or jyen.tech, chosen by the launcher" <<<"$o" && grep -q deny <<<"$o"'
o=$(gin sonnet | FABLE_LAUNCH_ACCOUNT=mcphost.dev bash "$G"); ck "mcphost.dev parent: non-Fable child denied (lane extension)" 'grep -q deny <<<"$o"'
o=$(gin claude-fable-5-1 | FABLE_LAUNCH_ACCOUNT=jyen.tech bash "$G"); ck "jyen.tech parent (installed pool): Fable child denied" 'grep -q deny <<<"$o"'
ck "guard header documents the pool (installed A1221 text)" 'grep -q "non-Fable = {josephsyen, jyen.tech}" "$G"'

echo "== installed fable-review default launcher (f8fe) kept"
R="$D/.local/bin/fable-review.sh"
ck "default is \$HOME/.local/bin/fable-launch.sh when installed there" 'grep -q "FABLE_REVIEW_CLAUDE:-\$HOME/.local/bin/fable-launch.sh" "$R"'
mkdir -p "$T/home/.local/bin"; printf '#!/usr/bin/env bash\necho INSTALLED-LAUNCHER "$@" >> "$SPYLOG"\nprintf "VERDICT: ok\\n"\n' > "$T/home/.local/bin/fable-launch.sh"; chmod +x "$T/home/.local/bin/fable-launch.sh"
printf 'page\n' > "$T/page.md"; : > "$SPYLOG"
FABLE_REVIEW_LAUNCH=env WM_DECIDE_BIN=true FABLE_REVIEW_OUT="$T/rev.txt" bash "$R" "$T/page.md" >/dev/null 2>&1
ck "installed ~/.local/bin/fable-launch.sh is the review's launcher" 'grep -q INSTALLED-LAUNCHER "$SPYLOG"'
rm -f "$T/home/.local/bin/fable-launch.sh"; : > "$SPYLOG"
FABLE_REVIEW_LAUNCH=env WM_DECIDE_BIN=true FABLE_REVIEW_OUT="$T/rev.txt" FABLE_LAUNCH_TEST=1 bash "$R" "$T/page.md" >/dev/null 2>&1
ck "not installed: falls back to the sibling fable-launch.sh (still the lane router)" 'grep -q "spy acct=jyen.pm" "$SPYLOG"'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
