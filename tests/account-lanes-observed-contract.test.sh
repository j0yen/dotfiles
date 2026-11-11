#!/usr/bin/env bash
# Observed native Fable-limit contract (A1300). The base fixture is REAL saved native output (tests/fixtures/account-lanes/native-fable-limit-observed.json);
# every negative/variant below is a SYNTHETIC mutation of it, labelled "synthetic". Authority = trusted launch metadata (lane fable from the selected model)
# + the CLI's own --output-format json / stream-json terminal envelope with the exact observed shape. Fake native child replays bytes; temp HOME/state,
# dummy credentials; no provider call. AL_ROOT=<tree> replays other bytes (RED on 60c161b).
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
FIXDIR="$(cd "$(dirname "$0")" && pwd)/fixtures/account-lanes"; FIX="$FIXDIR/native-fable-limit-observed.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/child" <<'S'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
data = open(os.environ["FAKE_STDOUT_FILE"], "rb").read()
if os.environ.get("FAKE_SID") == "echo":          # SYNTHETIC: make the envelope carry the session id this child was given
    sid = ""
    for i, x in enumerate(a):
        if x in ("--session-id", "--resume") and i + 1 < len(a): sid = a[i + 1]
    data = data.replace(b"7cf6c47b-eea4-4fce-a0ce-a50834a43921", sid.encode())
sys.stdout.buffer.write(data); sys.stdout.flush()
sys.exit(int(os.environ.get("FAKE_RC", "1")))
S
chmod +x "$T/child"
cat > "$T/mut.py" <<'G'
import json, sys
mode, out = sys.argv[1:3]
o = json.load(open(sys.argv[3])); raw = None
def stream(term, extra=True):
    ev = [json.dumps({"type": "system", "subtype": "init", "session_id": o["session_id"]}), json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}]}})]
    return "\n".join(ev + [json.dumps(term)]) + "\n"
if mode == "real": raw = open(sys.argv[3]).read()
elif mode == "pretty": raw = json.dumps(o, indent=2) + "\n"
elif mode == "stream": raw = stream(o)
elif mode == "stream_notlast": raw = stream(o) + json.dumps({"type": "system", "subtype": "note"}) + "\n"
elif mode == "stream_mixed": raw = "prose line\n" + stream(o)
elif mode == "api_other": o["api_error"] = "rate_limit_error"; raw = json.dumps(o)
elif mode == "no_api_error": del o["api_error"]; raw = json.dumps(o)
elif mode == "status_500": o["api_error_status"] = 500; raw = json.dumps(o)
elif mode == "status_429_only": o["api_error"] = None; o["result"] = "Rate limited"; raw = json.dumps(o)
elif mode == "status_str": o["api_error_status"] = "429"; raw = json.dumps(o)
elif mode == "terminal_other": o["terminal_reason"] = "completed"; raw = json.dumps(o)
elif mode == "not_error": o["is_error"] = False; raw = json.dumps(o)
elif mode == "model_usage": o["modelUsage"] = {"claude-fable-5-1": {"inputTokens": 5}}; raw = json.dumps(o)
elif mode == "text_credits": o["result"] = "You've run out of usage credits. Manage usage credits at https://claude.ai/settings/usage."; raw = json.dumps(o)
elif mode == "text_embedded": o["result"] = "Sure. " + o["result"]; raw = json.dumps(o)
elif mode == "text_suffix": o["result"] = o["result"] + " Also retry."; raw = json.dumps(o)
elif mode == "text_sonnet": o["result"] = o["result"].replace("Fable", "Sonnet"); raw = json.dumps(o)
elif mode == "spoof_success_text": raw = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": json.dumps(o), "session_id": o["session_id"]})
elif mode == "assistant_quote": raw = "\n".join([json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": json.dumps(o)}]}}), json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "done"})]) + "\n"
elif mode == "two_objects": raw = json.dumps(o) + "\n" + json.dumps(o) + "\n"
elif mode == "prefixed": raw = "log line\n" + json.dumps(o) + "\n"
elif mode == "truncated": raw = json.dumps(o)[:-20]
elif mode == "array": raw = json.dumps([o])
elif mode == "badutf8": raw = None; open(out, "wb").write(json.dumps(o).encode()[:-1] + b'\xff}'); sys.exit(0)
else: sys.exit("mode " + mode)
open(out, "w").write(raw)
G
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/child" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" FAKE_STDOUT_FILE="$T/out.bin"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
fex(){ jq -e '.exhausted["jyen.pm|fable"]' <(lane status) >/dev/null 2>&1; }
# go <mutation> <launcher args...> : fresh lanes, replay the mutated native bytes through the REAL launcher/supervisor
go() { local m="$1"; shift; rm -rf "$T/lanes"; python3 "$T/mut.py" "$m" "$T/out.bin" "$FIX"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
F="--model claude-fable-5-1 -p hi"; J="--output-format json --tools \"\" --no-session-persistence"
FJ=(--model claude-fable-5-1 -p hi --output-format json --tools "" --no-session-persistence)
FS=(--model claude-fable-5-1 -p hi --output-format stream-json --verbose --no-session-persistence)

echo "== actual preserved native fixture (caller shape of ctl-fable-escalate: json, --tools \"\", --no-session-persistence, rc 1)"
go real "${FJ[@]}"
ck "fixture is the observed native output (shape check)" 'jq -e ".is_error==true and .api_error==\"model_requires_usage_credits\" and .api_error_status==429 and .terminal_reason==\"api_error\" and (.modelUsage|length)==0 and .session_id==\"7cf6c47b-eea4-4fce-a0ce-a50834a43921\"" "$FIX" >/dev/null'
ck "jyen.pm Fable lane exhausted from the observed native output" 'fex'
ck "only that lane: exactly one exhaustion, jyen.pm non-Fable untouched" '[ "$(nex)" = 1 ] && ! jq -e ".exhausted[\"jyen.pm|nonfable\"]" <(lane status) >/dev/null'
ck "native stdout forwarded byte-for-byte" 'cmp -s "$T/out" "$FIX"'
ck "launcher exit is the CLI rc (1)" '[ "$(cat $T/rc)" = 1 ]'
ck "stderr states the contract and that the native session id is NOT correlated" 'grep -q "observed native Fable-limit contract" $T/err && grep -q "not correlated" $T/err'
ck "audit records both ids and sid_correlation none (no silent adoption)" 'jq -e "select(.event==\"native_fable_limit\") | .native_session_id==\"7cf6c47b-eea4-4fce-a0ce-a50834a43921\" and (.claimed_session|test(\"^[0-9a-f-]{36}\$\")) and .claimed_session!=.native_session_id and (.sid_correlation|startswith(\"none\"))" "$T/lanes/events.jsonl" >/dev/null'
ck "the claimed supervisor session stays UNKNOWN (never marked clean), native id never mapped" 'jq -e ".sessions|to_entries|length==1 and (.[0].value.state!=\"clean\") and (.[0].value.unknown_effect==true) and (.[0].key!=\"7cf6c47b-eea4-4fce-a0ce-a50834a43921\")" "$T/lanes/sessions.json" >/dev/null'
ck "no reset time in the message: no invented reset (stays until audited clear)" 'jq -e ".exhausted[\"jyen.pm|fable\"].reset_at==null" <(lane status) >/dev/null'
: > "$T/spy"; FAKE_RC=0 python3 "$T/mut.py" real "$T/out.bin" "$FIX"
"$L" --model claude-fable-5-1 -p hi >/dev/null 2>"$T/err2"; ck "next FRESH Fable launch selects mcphost.dev (confirmed exhaustion only)" 'grep -q "account=mcphost.dev" $T/err2'
"$L" --model claude-sonnet-5-5 -p hi >/dev/null 2>"$T/err3"; ck "non-Fable launch unaffected (josephsyen, never mcphost.dev)" 'grep -q "account=josephsyen" $T/err3'

echo "== trusted formats"
go pretty "${FJ[@]}";    ck "json mode, pretty-printed single object: recorded" 'fex'
go stream "${FS[@]}";    ck "stream-json: clean stream with the observed terminal result LAST: recorded" 'fex'
go real "${FJ[@]}" -- "prompt after separator" "--model" "x"; ck "caller separator + payload kept; still recorded (argv order contract intact)" 'fex && [ "$(cat $T/rc)" = 1 ]'
go stream_notlast "${FS[@]}"; ck "synthetic: terminal-looking event not last: no state" '[ "$(nex)" = 0 ]'
go stream_mixed "${FS[@]}";   ck "synthetic: prose line inside stream-json: no state" '[ "$(nex)" = 0 ]'
go real --model claude-fable-5-1 -p hi;                      ck "plain text mode (no --output-format): stdout never judged: no state" '[ "$(nex)" = 0 ]'
go real --model claude-fable-5-1 -p hi --output-format text; ck "text mode: no state" '[ "$(nex)" = 0 ]'

echo "== wrong lane / account / metadata (synthetic: same real bytes, other launch metadata)"
go real --model claude-sonnet-5-5 -p hi --output-format json --no-session-persistence; ck "non-Fable launch (lane nonfable) emitting the same bytes: no state (lane comes from the selected model)" '[ "$(nex)" = 0 ]'
ck "reason printed" 'grep -q "only authority for the fable lane" $T/err'
go real --model claude-haiku-5-5 -p hi --output-format stream-json; ck "other model, stream-json: no state" '[ "$(nex)" = 0 ]'

echo "== session id: honest discrepancy, safe block on a mismatch the CLI should not have"
S1=$(cat /proc/sys/kernel/random/uuid)   # fresh per run (host-wide duplicate-launch scan)
go real --model claude-fable-5-1 -p hi --output-format json --session-id $S1
ck "persistent session passed to the CLI but the envelope carries a DIFFERENT id: safe block, no state" '[ "$(nex)" = 0 ] && grep -q "does not match the session id passed to the CLI" $T/err'
rm -rf "$T/lanes"; python3 "$T/mut.py" real "$T/out.bin" "$FIX"; FAKE_SID=echo "$L" --model claude-fable-5-1 -p hi --output-format json --session-id $S1 >/dev/null 2>"$T/err"
ck "synthetic: envelope id equals the id passed to the CLI: recorded and audited as matching" 'fex && jq -e "select(.event==\"native_fable_limit\")|.sid_correlation|test(\"matches\")" "$T/lanes/events.jsonl" >/dev/null'
ck "that session stays unknown-effect (exhaustion run is never clean)" 'jq -e --arg s $S1 ".sessions[\$s].unknown_effect==true and .sessions[\$s].state!=\"clean\"" "$T/lanes/sessions.json" >/dev/null'

echo "== synthetic negatives on the envelope (json mode, rc 1): none may retire a lane"
for m in api_other no_api_error status_500 status_429_only status_str terminal_other not_error model_usage text_credits text_embedded text_suffix text_sonnet spoof_success_text assistant_quote two_objects prefixed truncated array badutf8; do
  go $m "${FJ[@]}"; ck "synthetic $m: no state" '[ "$(nex)" = 0 ]'
done
go api_other "${FJ[@]}"; ck "ordinary transient (rate_limit_error 429-shaped): no state and not called a limit" '[ "$(nex)" = 0 ] && ! grep -q "observed native Fable-limit contract" $T/err'
go text_credits "${FJ[@]}"; ck "paid/credit wording never exhausts and never falls back" '[ "$(nex)" = 0 ] && ! grep -q "account=mcphost.dev" $T/err'
go real "${FJ[@]}"; rm -rf "$T/lanes"; FAKE_RC=0 "$L" "${FJ[@]}" >/dev/null 2>&1; ck "rc 0 with the same bytes: no state" '[ "$(nex)" = 0 ]'
for r in 124 137 143; do rm -rf "$T/lanes"; FAKE_RC=$r "$L" "${FJ[@]}" >/dev/null 2>&1; ck "rc $r (killed/timed out) with the same bytes: no state" '[ "$(nex)" = 0 ]'; done
rm -rf "$T/lanes"; ACCOUNT_LANE_INJECT=jsonfeed "$L" "${FJ[@]}" >"$T/out" 2>"$T/err"; ck "observer failure injected: no state, stdout still forwarded, sanitized reason" '[ "$(nex)" = 0 ] && cmp -s "$T/out" "$FIX" && grep -q "observer failure in feed (RuntimeError)" $T/err'
ck "unchanged: trusted non-native ordinary exhaustion path still works (stream-json anchored message)" '
 rm -rf "$T/lanes"; printf "%s\n" "{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"terminal_reason\":\"api_error\",\"api_error_status\":429,\"result\":\"You'"'"'ve hit your usage limit\"}" > "$T/out.bin"; "$L" --model claude-sonnet-5-5 -p hi --output-format stream-json --no-session-persistence >/dev/null 2>&1; jq -e ".exhausted[\"josephsyen|nonfable\"]" <(lane status) >/dev/null'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
