#!/usr/bin/env bash
# seat-model-rollout.test.sh: A1300 model/effort rollout (rb/r7 default sonnet-5-5 medium, helper isolation, audit set).
# Harmless fakes only: temp dirs, fake token store, spy claude. No real claude, no provider call, no /etc, no live seat state.
# Run alone: bash tests/seat-model-rollout.test.sh
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
SL="$R/.local/bin/seat-relaunch.sh"
TAB="$R/.claude/state/controller-model-required"
SEED="$R/.config/wm-decide/seat-model-hold.rb-r7.json"
printf 'rb\trb\t11111111-1111-1111-1111-111111111111\t20\t3000\tgoal\t-\t80\nr7\tr7\t22222222-2222-2222-2222-222222222222\t20\t3000\tgoal\t-\t80\nctl\tcontroller\t33333333-3333-3333-3333-333333333333\t20\t3000\tgoal\t-\t60\n' >"$T/seats.tsv"
dry(){ env -u SEAT_MODEL -u SEAT_EFFORT SEAT_MODEL_TABLE="${TBL:-$TAB}" SEATS_TABLE="$T/seats.tsv" SEAT_MODEL_HOLD="${HOLD:-$SEED}" SEAT_DRY_RUN=1 "$@" "$SL" ${SEATS:-rb r7} 2>"$T/err"; }

# AC1 positive
out="$(dry env)"; rc=$?
ck "AC1 rb dry-run = sonnet-5-5 medium" '[ $rc = 0 ] && grep -E "^rb: " <<<"$out" | grep -q -- "--model claude-sonnet-5-5 --effort medium"'
ck "AC1 r7 dry-run = sonnet-5-5 medium" 'grep -E "^r7: " <<<"$out" | grep -q -- "--model claude-sonnet-5-5 --effort medium"'
ck "AC1 table rb/r7 rows are sonnet-5-5, controller row untouched" '[ "$(awk "\$1==\"rb\"{print \$2}" "$TAB")" = claude-sonnet-5-5 ] && [ "$(awk "\$1==\"r7\"{print \$2}" "$TAB")" = claude-sonnet-5-5 ] && [ "$(awk "\$1==\"controller\"{print \$2}" "$TAB")" = claude-opus-5-5 ]'
ck "E5 seed hold rows match the table (model) and carry effort medium, by joe-20261112, expiry" 'jq -e ".rb.model==\"claude-sonnet-5-5\" and .r7.model==\"claude-sonnet-5-5\" and .rb.effort==\"medium\" and .r7.effort==\"medium\" and (.rb.by|test(\"joe-20261112\")) and (.r7.expires|test(\"^20\"))" "$SEED" >/dev/null'
out="$(SEATS=ctl dry env)"; ck "ctl dry-run unchanged (no --effort flag)" '! grep -q -- "--effort" <<<"$out" && grep -q -- "--model claude-opus-5-5" <<<"$out"'

# AC2 negatives
SEATS=rb dry env SEAT_MODEL=wrong >/dev/null; ck "AC2 wrong model refused" '[ $? != 0 ]'
SEATS=rb dry env SEAT_EFFORT=bogus >/dev/null; ck "AC2 wrong effort refused" '[ $? != 0 ]'
SEATS=nosuch dry env >/dev/null; ck "AC2 unknown seat refused (dry-run too)" '[ $? = 2 ]'
jq '.rb.effort="bogus"' "$SEED" >"$T/hold-bad.json"; HOLD="$T/hold-bad.json" SEATS=rb dry env >/dev/null; ck "AC2 invalid hold effort refused" '[ $? != 0 ]'
dd_(){ env -u SEAT_MODEL SEAT_MODEL_TABLE="$1" SEATS_TABLE="$T/seats.tsv" SEAT_MODEL_HOLD="$2" "$SL" --drift-test 2>&1; }
dd_ "$TAB" "$SEED" >"$T/dd-ok"; ck "drift test passes on the shipped table + seed" 'tail -1 "$T/dd-ok" | grep -q "DRIFT-TEST PASS"'
sed 's/^rb .*/rb claude-opus-5-5/' "$TAB" >"$T/tab-diff"; dd_ "$T/tab-diff" "$SEED" >"$T/dd-bad"; ck "AC2 table row differing from hold row fails the drift test" 'tail -1 "$T/dd-bad" | grep -q "DRIFT-TEST FAIL" && grep -q "hold" "$T/dd-bad"'

# AC3 escalation
out="$(SEATS=rb dry env SEAT_MODEL=claude-opus-5-5)"; ck "AC3 explicit SEAT_MODEL=opus resolves with effort high" 'grep -q -- "--model claude-opus-5-5 --effort high" <<<"$out"'
out="$(SEATS=rb dry env SEAT_MODEL=claude-opus-5-5 SEAT_EFFORT=xhigh)"; ck "AC3 explicit SEAT_EFFORT honoured" 'grep -q -- "--model claude-opus-5-5 --effort xhigh" <<<"$out"'

# E1 one effort source shared by seat-tick and seat-relaunch
ck "E1 seat-tick resolves --effort through the shared seat-lean.sh helper" 'grep -q "seat_hold_effort" "$R/.local/bin/seat-tick.sh" && grep -q "seat_hold_effort" "$R/.local/bin/seat-lean.sh" && grep -q -- "--effort" "$R/.local/bin/seat-tick.sh"'
h="$(env SEAT_MODEL_HOLD="$SEED" bash -c '. "$1"; seat_hold_effort rb; seat_hold_effort r7; seat_hold_effort controller' _ "$R/.local/bin/seat-lean.sh" | tr '\n' ' ')"
ck "E1 seat_hold_effort: rb medium, r7 medium, controller empty" '[ "$h" = "medium medium " ]'

# AC4 helper isolation
ck "AC4 only the four Stop-obligation consumers read WM_HELPER" '[ "$(cd "$R/.claude/hooks" && grep -l WM_HELPER * 2>/dev/null | sort | tr "\n" " ")" = "aside-followup-stop.sh followup-stop-gate.sh owed-now.sh seat-owed-stop.sh " ]'
HH="$T/home"; mkdir -p "$HH"
for h in owed-now.sh:hook aside-followup-stop.sh: seat-owed-stop.sh: followup-stop-gate.sh:; do
  name="${h%%:*}"; arg="${h#*:}"
  out="$(HOME="$HH" WM_SEAT=ctl WM_HELPER=1 WM_PARENT_SID=p1 WM_TASK=t1 bash "$R/.claude/hooks/$name" $arg <<<'{"hook_event_name":"Stop","session_id":"zz","last_assistant_message":"this is a separate check, not investigated. I will do it later."}' 2>&1)"; rc=$?
  ck "AC4 $name silent exit 0 under helper env" '[ $rc = 0 ] && [ -z "$out" ]'
done
ck "AC4 helper env writes no ctl state dirs under HOME" '[ -z "$(find "$HH" -mindepth 1 | head -1)" ]'
# guards unchanged: model-role-check + secret-read-gate decisions identical with and without the helper marker
printf "ctl claude-fable-5-1\n" >"$T/mrc-table"; printf '{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n' >"$T/tr.jsonl"
g(){ MRC_TABLE="$T/mrc-table" MRC_SKIP_FALLBACK=1 HOME="$HH" WM_SEAT=ctl "$@" bash "$R/.claude/hooks/model-role-check.sh" <<<"{\"transcript_path\":\"$T/tr.jsonl\"}" 2>&1; }
a="$(g env)"; b="$(g env WM_HELPER=1)"; ck "AC4 model-role-check decision identical under helper env (and non-empty)" '[ -n "$a" ] && [ "$a" = "$b" ]'
s(){ HOME="$HH" WM_SEAT=ctl "$@" bash "$R/.claude/hooks/secret-read-gate.sh" <<<'{"tool_name":"Bash","tool_input":{"command":"cat /home/jsy/.config/environment.d/90-claude-oauth.conf"},"session_id":"zz"}' >/dev/null 2>&1; echo $?; }
a="$(s env)"; b="$(s env WM_HELPER=1)"; ck "AC4 secret-read-gate still refuses under helper env" '[ "$a" = 2 ] && [ "$b" = 2 ]'
# fable-launch --helper stamps the marker + provenance, keeps WM_SEAT, non-helper launches carry no marker
export ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$R/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
mkdir -p "$T/store"; for a in josephsyen jyen.tech jyen.pm; do printf 'FAKE-%s-xxxxxxxx' "$a" >"$T/store/$a"; done; chmod 600 "$T/store"/*
printf '#!/usr/bin/env bash\necho "spy seat=${WM_SEAT:-} helper=${WM_HELPER:-} parent=${WM_PARENT_SID:-} task=${WM_TASK:-}" >>"$SPYLOG"\n' >"$T/claude"; chmod +x "$T/claude"
export FABLE_RR_DIR="$T/rr" FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log"
: >"$SPYLOG"; WM_SEAT=ctl WM_PARENT_SID=par-sid-1 WM_TASK=task-9 "$R/.local/bin/fable-launch.sh" --helper --model claude-sonnet-5-5 --effort medium 2>/dev/null
ck "AC4 --helper child: WM_SEAT=ctl kept, WM_HELPER=1, parent + task provenance" 'grep -q "seat=ctl helper=1 parent=par-sid-1 task=task-9" "$SPYLOG"'
: >"$SPYLOG"; WM_SEAT=ctl "$R/.local/bin/fable-launch.sh" --model claude-sonnet-5-5 --effort medium 2>/dev/null
ck "AC4 non-helper launch carries no helper marker" 'grep -q "seat=ctl helper= " "$SPYLOG"'

# AC5 audit set
. "$R/.local/lib/skill-model-policy.sh"
want="$(jq -r '.skills|keys|sort|join(" ")' "$R/.config/skill-routing/policy.json")"; got="$(printf '%s\n' $SKILL_POLICY_SKILLS | sort | paste -sd' ' -)"
ck "AC5 skill-model-policy.sh set equals the routing policy's governed skills" '[ "$want" = "$got" ]'
ck "AC5 maxspeed listed" 'case " $SKILL_POLICY_SKILLS " in *" maxspeed "*) true;; *) false;; esac'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
[ $f = 0 ]
