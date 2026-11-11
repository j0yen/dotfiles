#!/usr/bin/env bash
# Nonfable stream-json has NO weaker stdout fallback. After the observed-shape/SID/exit gate refuses a terminal event, nothing from stdout may record
# exhaustion (review14 probes A-C: missing pinned SID, no status/terminal_reason, status 500 used to be recorded by the older stream path). Refusals leave
# state AND audit untouched and print one consistent diagnostic; an accepted envelope prints one classification line. The stream form itself is
# UNOBSERVED (only the json fixture is real): every stream event here is SYNTHETIC, derived from native-nonfable-429-observed.json. Fresh per-run UUIDs
# (the launcher's duplicate check scans the whole host). Fake native child; temp HOME/state, dummy credentials; no provider call. AL_ROOT=<tree> replays.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/account-lanes/native-nonfable-429-observed.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/child" <<'S'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]; sid = ""
for i, x in enumerate(a):
    if x in ("--session-id", "--resume") and i + 1 < len(a): sid = a[i + 1]
    elif x.startswith("--session-id="): sid = x.split("=", 1)[1]
data = open(os.environ["FAKE_STDOUT_FILE"], "rb").read().replace(b"@SID@", sid.encode())
sys.stdout.buffer.write(data); sys.stdout.flush()
if os.environ.get("FAKE_ERR"): sys.stderr.write(os.environ["FAKE_ERR"] + "\n")
if os.environ.get("FAKE_KILL"): os.kill(os.getpid(), 9)
sys.exit(int(os.environ.get("FAKE_RC", "1")))
S
chmod +x "$T/child"
cat > "$T/mut.py" <<'G'
import json, sys
mode, out, fix = sys.argv[1:4]
o = json.load(open(fix)); d = json.dumps
init = d({"type": "system", "subtype": "init"}); asst = d({"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}]}})
def stream(t, tail=""): return "\n".join([init, asst, d(t)]) + "\n" + tail
if mode == "ok": pass
elif mode == "sid_echo": o["session_id"] = "@SID@"
elif mode == "sid_missing": pass
elif mode == "sid_null": o["session_id"] = None
elif mode == "sid_empty": o["session_id"] = ""
elif mode == "sid_other": o["session_id"] = "99999999-9999-4999-8999-999999999999"
elif mode == "no_status": del o["api_error_status"]
elif mode == "no_tr": del o["terminal_reason"]
elif mode == "no_both": del o["api_error_status"]; del o["terminal_reason"]
elif mode == "st_500": o["api_error_status"] = 500
elif mode == "st_str": o["api_error_status"] = "429"
elif mode == "st_bool": o["api_error_status"] = True
elif mode == "tr_other": o["terminal_reason"] = "completed"
elif mode == "type_other": o["type"] = "assistant"
elif mode == "err_false": o["is_error"] = False
elif mode == "err_missing": del o["is_error"]
elif mode == "subtype_error_only": o["is_error"] = False; o["subtype"] = "error"
elif mode == "quoted": o["result"] = "Sure. " + o["result"]
elif mode == "not_last": open(out, "w").write(stream(o, d({"type": "system", "subtype": "n"}) + "\n")); sys.exit(0)
elif mode == "bare_anchored":      # the OLD weaker shape: anchored message, no 429 / terminal_reason
    o = {"type": "result", "subtype": "error", "is_error": True, "result": "You've hit your usage limit"}
else: sys.exit("mode " + mode)
open(out, "w").write(stream(o))
G
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/child" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" FAKE_STDOUT_FILE="$T/out.bin"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
jex(){ jq -e '.exhausted["josephsyen|nonfable"]' <(lane status) >/dev/null 2>&1; }
noaudit(){ ! grep -q '"event": "exhausted"\|"event":"exhausted"\|native_envelope_limit\|native_fable_limit' "$T/lanes/events.jsonl" 2>/dev/null; }
go() { local m="$1"; shift; rm -rf "$T/lanes"; python3 "$T/mut.py" "$m" "$T/out.bin" "$FIX"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
UU(){ cat /proc/sys/kernel/random/uuid; }
S1=$(UU)
SS=(--model claude-sonnet-5-5 -p hi --output-format stream-json --verbose)
NP=(--no-session-persistence)
refused(){ [ "$(nex)" = 0 ] && noaudit && ! grep -q "lane exhaustion recorded" "$T/err" && [ "$(grep -c 'failure classified' "$T/err")" -le 1 ]; }

echo "== review14 probes A-C against the stream-json fallback"
go sid_missing "${SS[@]}" --session-id $S1;  ck "A: explicit SID + stream terminal without session_id: refused, state+audit untouched" 'refused'
ck "A: diagnostic says not accepted and nothing contradicts it (no 'recorded')" 'grep -q "not accepted" $T/err && grep -q "failure classified unknown" $T/err'
go no_both "${SS[@]}" "${NP[@]}";             ck "B: anchored message but no status/terminal_reason (unpinned): refused" 'refused'
go st_500 "${SS[@]}" "${NP[@]}";              ck "C: status 500 + anchored message (unpinned): refused" 'refused'
go bare_anchored "${SS[@]}" "${NP[@]}";       ck "old weaker shape (is_error + anchored text only): refused for nonfable" 'refused'

echo "== explicit SID on stream-json"
for m in sid_missing sid_null sid_empty sid_other ok; do go $m "${SS[@]}" --session-id $S1; ck "synthetic $m with a passed id: refused" 'refused'; done
for m in sid_missing sid_null sid_empty sid_other; do go $m "${SS[@]}" "${NP[@]}" --session-id $S1; ck "synthetic $m + passed id + no-persistence: refused" 'refused'; done
go sid_missing "${SS[@]}" --session-id=$S1;    ck "--session-id=X form + missing: refused" 'refused'
go sid_other "${SS[@]}" "${NP[@]}" --resume $S1; ck "--resume X (unmapped) never reaches the CLI: blocked before launch, no state" '[ "$(nex)" = 0 ] && noaudit'
go sid_echo "${SS[@]}" --session-id $S1;       ck "exact-SID POSITIVE: result echoes the passed id: recorded" 'jex && [ "$(nex)" = 1 ]'
ck "positive prints ONE classification line (no duplicate) and the accepted-contract wording" '[ "$(grep -c "failure classified" $T/err)" = 1 ] && grep -q "observed non-Fable 429 envelope" $T/err'
ck "positive audit: matches; claimed session unknown-effect; nothing adopted" 'jq -e "select(.event==\"native_envelope_limit\")|.sid_correlation|test(\"matches\")" "$T/lanes/events.jsonl" >/dev/null && jq -e --arg s $S1 ".sessions[\$s].unknown_effect==true and .sessions[\$s].state!=\"clean\"" "$T/lanes/sessions.json" >/dev/null'
go sid_echo "${SS[@]}";                        ck "launcher-injected id echoed: recorded" 'jex'
go ok "${SS[@]}" "${NP[@]}";                   ck "unpinned run, observed shape (no session_id): recorded from owned output" 'jex && [ "$(grep -c "failure classified" $T/err)" = 1 ]'

echo "== shape gates on stream-json (synthetic)"
for m in no_status no_tr st_500 st_str st_bool tr_other type_other err_false err_missing subtype_error_only quoted not_last; do go $m "${SS[@]}" "${NP[@]}"; ck "synthetic $m: refused" 'refused'; done

echo "== exit gate"
for r in 0 124 137 143; do rm -rf "$T/lanes"; python3 "$T/mut.py" ok "$T/out.bin" "$FIX"; FAKE_RC=$r "$L" "${SS[@]}" "${NP[@]}" >/dev/null 2>"$T/err"; ck "rc $r: refused" 'refused'; done
rm -rf "$T/lanes"; python3 "$T/mut.py" ok "$T/out.bin" "$FIX"; FAKE_KILL=1 "$L" "${SS[@]}" "${NP[@]}" >/dev/null 2>"$T/err"; ck "child killed by a signal: refused" 'refused'

echo "== unchanged contracts"
rm -rf "$T/lanes"; python3 "$T/mut.py" no_both "$T/out.bin" "$FIX"; FAKE_ERR="You've hit your weekly limit" "$L" "${SS[@]}" "${NP[@]}" >/dev/null 2>"$T/err"
ck "trusted one-line stderr contract still records when the stdout terminal is refused" 'jex'
rm -rf "$T/lanes"; python3 "$T/mut.py" ok "$T/out.bin" "$FIX"; "$L" --model claude-sonnet-5-5 -p hi --output-format json "${NP[@]}" >/dev/null 2>&1; true
printf '%s\n' "$(cat "$FIX")" > "$T/out.bin"; rm -rf "$T/lanes"; "$L" --model claude-sonnet-5-5 -p hi --output-format json "${NP[@]}" >/dev/null 2>"$T/err"
ck "retained json fixture still accepted (observed contract)" 'jex && [ "$(grep -c "failure classified" $T/err)" = 1 ]'
rm -rf "$T/lanes"; printf '%s\n' '{"type":"result","subtype":"error","is_error":true,"result":"You'"'"'ve hit your usage limit"}' > "$T/out.bin"; "$L" --model claude-fable-5-1 -p hi --output-format stream-json "${NP[@]}" >/dev/null 2>"$T/err"
ck "Fable-lane stream-json anchored terminal: unchanged older path (documented limit, not part of this repair)" 'jq -e ".exhausted[\"jyen.pm|fable\"]" <(lane status) >/dev/null'

echo "== UUID isolation: independent per-run ids; concurrent copies must not collide"
ck "S1 is a fresh uuid (not a fixed literal)" '[[ "$S1" =~ ^[0-9a-f-]{36}$ ]] && [ "$S1" != ffffffff-2222-4333-8444-555555555551 ]'
echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
