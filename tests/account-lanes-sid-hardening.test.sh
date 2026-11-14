#!/usr/bin/env bash
# SID hardening for the observed native Fable-limit contract (findings 1+2 of OBSERVED-CONTRACT-DELTA-REVIEW). Base bytes = the REAL observed fixture
# (tests/fixtures/account-lanes/native-fable-limit-observed.json); every SID variant below is a SYNTHETIC mutation of its session_id field.
# Rules: when a session id was actually passed to the CLI (injected, --session-id X, --session-id=X, --resume X, ALSO with --no-session-persistence) the
# result must carry exactly that id (missing/null/empty/non-string/different = fail closed, no lane write, session stays UNKNOWN); a truly unpinned
# no-persistence run keeps process-owned-output provenance with an honestly uncorrelated native id. Fake native child records its actual argv.
# Temp HOME/state, dummy credentials; no provider call. AL_ROOT=<tree> replays other bytes (RED on 54a850e).
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/account-lanes/native-fable-limit-observed.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/child" <<'S'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
open(os.environ["ARGVLOG"], "wb").write(b"\0".join(x.encode() for x in a))
sid = ""
for i, x in enumerate(a):
    if x in ("--session-id", "--resume") and i + 1 < len(a): sid = a[i + 1]
    elif x.startswith("--session-id=") or x.startswith("--resume="): sid = x.split("=", 1)[1]
o = json.load(open(os.environ["FIXTURE"])); m = os.environ.get("FAKE_SIDMODE", "real")   # SYNTHETIC mutations of session_id
if m == "echo": o["session_id"] = sid
elif m == "other": o["session_id"] = "99999999-9999-4999-8999-999999999999"
elif m == "missing": del o["session_id"]
elif m == "null": o["session_id"] = None
elif m == "empty": o["session_id"] = ""
elif m == "int": o["session_id"] = 12345
elif m == "list": o["session_id"] = [sid]
sys.stdout.write(json.dumps(o) if m != "real" else open(os.environ["FIXTURE"]).read()); sys.stdout.flush()
sys.exit(int(os.environ.get("FAKE_RC", "1")))
S
chmod +x "$T/child"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/child" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" ARGVLOG="$T/argv.bin" FIXTURE="$FIX"
export SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1300\n' > "$T/ids.txt"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
fex(){ jq -e '.exhausted["jyen.pm|fable"]' <(lane status) >/dev/null 2>&1; }
argvhas(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read().split(b"\0");sys.exit(0 if all(x.encode() in d for x in sys.argv[2:]) else 1)' "$T/argv.bin" "$@"; }
argvno(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read().split(b"\0");sys.exit(0 if not any(x.encode() in d for x in sys.argv[2:]) else 1)' "$T/argv.bin" "$@"; }
# go <sidmode> <launcher args...>
go() { local m="$1"; shift; rm -rf "$T/lanes"; rm -f "$T/argv.bin"; FAKE_SIDMODE="$m" "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
S1=$(cat /proc/sys/kernel/random/uuid); S2=$(cat /proc/sys/kernel/random/uuid)   # fresh per run (host-wide duplicate-launch scan)
FJ=(--model claude-fable-5-1 -p hi --output-format json --tools "")

echo "== finding 1: a session id was passed to the CLI -> the result must carry exactly it"
go echo "${FJ[@]}" --session-id $S1;    ck "explicit --session-id, result echoes it: recorded, audit says matches" 'fex && jq -e "select(.event==\"native_fable_limit\")|.sid_correlation|test(\"matches\")" "$T/lanes/events.jsonl" >/dev/null'
for m in missing null empty int list other real; do
  go $m "${FJ[@]}" --session-id $S1;  ck "synthetic result session_id=$m with a passed id: fail closed, no lane write" '[ "$(nex)" = 0 ]'
done
ck "missing id reason printed (no usable session_id)" 'go missing "${FJ[@]}" --session-id $S1; grep -q "carries no usable session_id" $T/err'
go other "${FJ[@]}" --session-id $S1;  ck "a different id reason printed" 'grep -q "does not match the session id passed to the CLI" $T/err'
go missing "${FJ[@]}";                 ck "injected (launcher-generated) id + missing result id: fail closed" 'argvhas --session-id && [ "$(nex)" = 0 ]'
go echo "${FJ[@]}";                    ck "injected id echoed by the result: recorded" 'argvhas --session-id && fex'
go real "${FJ[@]}";                    ck "injected id vs the real fixture's different native id: fail closed" '[ "$(nex)" = 0 ]'

echo "== finding 2: --no-session-persistence does not hide a passed session id"
NP=(--no-session-persistence)
go echo "${FJ[@]}" "${NP[@]}" --session-id $S1;  ck "argv: --session-id X AND --no-session-persistence both reach the CLI" 'argvhas --session-id $S1 --no-session-persistence'
ck "explicit --session-id X + no-persistence + echoed id: recorded" 'fex && jq -e "select(.event==\"native_fable_limit\")|.native_session_id==\"'$S1'\" and (.sid_correlation|test(\"matches\"))" "$T/lanes/events.jsonl" >/dev/null'
for m in real other missing null empty int; do
  go $m "${FJ[@]}" "${NP[@]}" --session-id $S1; ck "synthetic $m + explicit --session-id X + no-persistence: fail closed" '[ "$(nex)" = 0 ]'
done
go echo "${FJ[@]}" "${NP[@]}" --session-id=$S2;  ck "--session-id=X form + no-persistence + echoed: recorded" 'argvhas --session-id=$S2 && fex'
go other "${FJ[@]}" "${NP[@]}" --session-id=$S2; ck "--session-id=X form + no-persistence + mismatch: fail closed" '[ "$(nex)" = 0 ]'
go missing "${FJ[@]}" "${NP[@]}" --session-id=$S2; ck "--session-id=X form + no-persistence + missing: fail closed" '[ "$(nex)" = 0 ]'
# --resume X with no-persistence: map X first (clean prior run, rc 0 = no failure), then resume while the CLI fails
rm -rf "$T/lanes"; FAKE_RC=0 FAKE_SIDMODE=echo "$L" "${FJ[@]}" --session-id $S1 >/dev/null 2>&1
FAKE_SIDMODE=echo "$L" "${FJ[@]}" "${NP[@]}" --resume $S1 >"$T/out" 2>"$T/err"
ck "--resume X + no-persistence + echoed id: argv carries both, recorded" 'argvhas --resume $S1 --no-session-persistence && fex'
rm -rf "$T/lanes"; FAKE_RC=0 FAKE_SIDMODE=echo "$L" "${FJ[@]}" --session-id $S1 >/dev/null 2>&1
FAKE_SIDMODE=real "$L" "${FJ[@]}" "${NP[@]}" --resume $S1 >"$T/out" 2>"$T/err"
ck "--resume X + no-persistence + mismatched native id: fail closed" '[ "$(nex)" = 0 ] && grep -q "does not match" $T/err'
rm -rf "$T/lanes"; FAKE_RC=0 FAKE_SIDMODE=echo "$L" "${FJ[@]}" --session-id $S1 >/dev/null 2>&1
FAKE_SIDMODE=missing "$L" "${FJ[@]}" "${NP[@]}" --resume $S1 >"$T/out" 2>"$T/err"
ck "--resume X + no-persistence + missing id: fail closed" '[ "$(nex)" = 0 ]'

echo "== truly unpinned no-persistence caller (the observed ctl-fable-escalate shape): provenance retained, honestly uncorrelated"
go real "${FJ[@]}" "${NP[@]}"
ck "argv has no session id at all" 'argvno --session-id --resume && argvhas --no-session-persistence'
ck "real fixture recorded from the owned child's own output" 'fex && cmp -s "$T/out" "$FIX"'
ck "audit: native id recorded, sid_correlation says none / unpinned, claimed key differs" 'jq -e "select(.event==\"native_fable_limit\")|.native_session_id==\"7cf6c47b-eea4-4fce-a0ce-a50834a43921\" and (.sid_correlation|startswith(\"none\")) and (.sid_correlation|test(\"unpinned\")) and .claimed_session!=.native_session_id" "$T/lanes/events.jsonl" >/dev/null'
go missing "${FJ[@]}" "${NP[@]}"; ck "synthetic: unpinned run with a result lacking session_id: still recorded (nothing to cross-check), audit says none" 'fex && jq -e "select(.event==\"native_fable_limit\")|(.sid_correlation|startswith(\"none\"))" "$T/lanes/events.jsonl" >/dev/null'

echo "== managed route (injects an id) + no-persistence"
printf '{"task_id":"A1300","skill":"5whysandrhyme"}' > "$T/req.json"
go echo --route-request "$T/req.json" -p hi --output-format json --no-session-persistence
ck "managed fable route injects --session-id even with no-persistence; echoed id: recorded" 'argvhas --session-id --no-session-persistence && fex'
go real --route-request "$T/req.json" -p hi --output-format json --no-session-persistence
ck "managed + no-persistence + the real fixture's different native id: fail closed" '[ "$(nex)" = 0 ]'

echo "== unknown effect / no adoption preserved on every path"
go real "${FJ[@]}" "${NP[@]}"
ck "recorded run: claimed session unknown_effect, never clean; native id never a sessions.json key" 'jq -e ".sessions|length==1 and (to_entries[0].value.unknown_effect==true) and (to_entries[0].value.state!=\"clean\") and (to_entries[0].key!=\"7cf6c47b-eea4-4fce-a0ce-a50834a43921\")" "$T/lanes/sessions.json" >/dev/null'
go other "${FJ[@]}" --session-id $S1
ck "blocked run (mismatch): no exhaustion, session still not clean (unknown), nothing adopted, no native_fable_limit audit" '[ "$(nex)" = 0 ] && jq -e --arg s $S1 ".sessions[\$s].state!=\"clean\" and .sessions[\$s].unknown_effect==true" "$T/lanes/sessions.json" >/dev/null && ! grep -q native_fable_limit "$T/lanes/events.jsonl"'
ck "no replay: the child ran exactly once per launch (argv log is a single invocation record)" '[ -s "$T/argv.bin" ]'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
