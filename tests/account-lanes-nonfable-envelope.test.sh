#!/usr/bin/env bash
# Observed NON-Fable terminal envelope (real Sonnet 5.5 headless json 429, sanitized fixture native-nonfable-429-observed.json). Unpinned run + trusted nonfable
# metadata + plain non-zero exit + type=result/is_error true/terminal_reason api_error/numeric 429/anchored session|usage|weekly message exhausts ONLY the selected
# account's nonfable lane. An explicit session id passed to the CLI needs the exact id back (the retained fixture has none -> blocked when pinned).
# Mutations are SYNTHETIC. Fake native child replays bytes; temp HOME/state, dummy credentials; no provider call. AL_ROOT=<tree> replays other bytes.
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
data = open(os.environ["FAKE_STDOUT_FILE"], "rb").read()
if os.environ.get("FAKE_SID") == "echo": data = data.replace(b"@SID@", sid.encode())
sys.stdout.buffer.write(data); sys.stdout.flush(); sys.exit(int(os.environ.get("FAKE_RC", "1")))
S
chmod +x "$T/child"
cat > "$T/mut.py" <<'G'
import json, sys
mode, out, fix = sys.argv[1:4]
o = json.load(open(fix)); M = o["result"]; raw = None
def d(x): return json.dumps(x)
if mode == "real": raw = open(fix).read()
elif mode == "stream": raw = d({"type": "system", "subtype": "init"}) + "\n" + d(o) + "\n"
elif mode == "stream_notlast": raw = d(o) + "\n" + d({"type": "system", "subtype": "n"}) + "\n"
elif mode == "not_error": o["is_error"] = False; raw = d(o)
elif mode == "err_str": o["is_error"] = "true"; raw = d(o)
elif mode == "err_missing": del o["is_error"]; raw = d(o)
elif mode == "st_500": o["api_error_status"] = 500; raw = d(o)
elif mode == "st_str": o["api_error_status"] = "429"; raw = d(o)
elif mode == "st_bool": o["api_error_status"] = True; raw = d(o)
elif mode == "st_float": o["api_error_status"] = 429.0; raw = d(o)
elif mode == "st_missing": del o["api_error_status"]; raw = d(o)
elif mode == "type_other": o["type"] = "assistant"; raw = d(o)
elif mode == "tr_other": o["terminal_reason"] = "completed"; raw = d(o)
elif mode == "tr_missing": del o["terminal_reason"]; raw = d(o)
elif mode == "quoted": o["result"] = "Sure. " + M; raw = d(o)
elif mode == "suffix": o["result"] = "You've hit your weekly limit. Please retry."; raw = d(o)
elif mode == "other_text": o["result"] = "Rate limited, try again"; raw = d(o)
elif mode == "auth": o["result"] = "You've hit your weekly limit. 401 unauthorized, please /login"; raw = d(o)
elif mode == "net": o["result"] = "network error: ECONNRESET while contacting the service"; raw = d(o)
elif mode == "spend": o["result"] = "You've hit your monthly spend limit. Purchase more credits."; raw = d(o)
elif mode == "result_int": o["result"] = 7; raw = d(o)
elif mode == "malformed": raw = d(o)[:-15]
elif mode == "prefixed": raw = "log line\n" + d(o) + "\n"
elif mode == "two": raw = d(o) + "\n" + d(o) + "\n"
elif mode == "array": raw = d([o])
elif mode == "badutf8": open(out, "wb").write(d(o).encode()[:-1] + b'\xff}'); sys.exit(0)
elif mode == "sid_echo": o["session_id"] = "@SID@"; raw = d(o)
elif mode == "sid_other": o["session_id"] = "99999999-9999-4999-8999-999999999999"; raw = d(o)
elif mode == "sid_null": o["session_id"] = None; raw = d(o)
elif mode == "sid_empty": o["session_id"] = ""; raw = d(o)
elif mode == "sid_present_unpinned": o["session_id"] = "99999999-9999-4999-8999-999999999999"; raw = d(o)
else: sys.exit("mode " + mode)
open(out, "w").write(raw)
G
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/child" SKILL_ROUTING_DECISIONS="$T/dec.jsonl" FAKE_STDOUT_FILE="$T/out.bin"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
jex(){ jq -e '.exhausted["josephsyen|nonfable"]' <(lane status) >/dev/null 2>&1; }
go() { local m="$1"; shift; rm -rf "$T/lanes"; python3 "$T/mut.py" "$m" "$T/out.bin" "$FIX"; FAKE_SID="${SIDMODE:-}" "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
NJ=(--model claude-sonnet-5-5 -p hi --output-format json)
S1=$(cat /proc/sys/kernel/random/uuid)   # fresh per run: the launcher duplicate check scans the whole host for a live process carrying the id

echo "== retained observed envelope, unpinned nonfable run"
go real "${NJ[@]}" --no-session-persistence
ck "fixture is the observed shape (no session_id, 429, api_error, weekly)" 'jq -e ".is_error==true and .api_error_status==429 and .terminal_reason==\"api_error\" and (has(\"session_id\")|not) and (.result|test(\"hit your weekly limit\"))" "$FIX" >/dev/null'
ck "exhausts josephsyen|nonfable and ONLY that" 'jex && [ "$(nex)" = 1 ]'
ck "stdout forwarded byte-for-byte, rc 1" 'cmp -s "$T/out" "$FIX" && [ "$(cat $T/rc)" = 1 ]'
ck "stderr names the observed non-Fable envelope" 'grep -q "observed non-Fable 429 envelope" $T/err'
ck "audit: unpinned owned-output provenance, no invented session correlation" 'jq -e "select(.event==\"native_envelope_limit\")|(.sid_correlation|startswith(\"none\")) and .native_session_id==\"\"" "$T/lanes/events.jsonl" >/dev/null'
ck "claimed session stays unknown-effect (never clean), nothing adopted" 'jq -e ".sessions|length==1 and (to_entries[0].value.unknown_effect==true) and (to_entries[0].value.state!=\"clean\")" "$T/lanes/sessions.json" >/dev/null'
ck "reset parsed from the anchored text by the ordinary classifier (not invented)" 'jq -e ".exhausted[\"josephsyen|nonfable\"]|has(\"reset_at\")" <(lane status) >/dev/null'
"$L" --model claude-sonnet-5-5 -p hi >/dev/null 2>"$T/e2"; ck "next fresh nonfable launch skips josephsyen (jyen.tech), never jyen.pm/mcphost.dev" 'grep -q "account=jyen.tech" $T/e2'
"$L" --model claude-fable-5-1 -p hi >/dev/null 2>"$T/e3"; ck "Fable lane unaffected (jyen.pm)" 'grep -q "account=jyen.pm" $T/e3'
go real "${NJ[@]}";   ck "same without --no-session-persistence is still unpinned? (launcher injects an id: result has none -> blocked)" '[ "$(nex)" = 0 ]'

echo "== other trusted channel / formats"
go stream --model claude-sonnet-5-5 -p hi --output-format stream-json --verbose --no-session-persistence; ck "stream-json terminal envelope last, unpinned: recorded" 'jex'
go stream_notlast --model claude-sonnet-5-5 -p hi --output-format stream-json --no-session-persistence; ck "synthetic: terminal not last: no state" '[ "$(nex)" = 0 ]'
go real --model claude-sonnet-5-5 -p hi --no-session-persistence;                 ck "plain output (no --output-format): stdout never judged: no state" '[ "$(nex)" = 0 ]'
go real --model claude-sonnet-5-5 -p hi --output-format text --no-session-persistence; ck "text format: no state" '[ "$(nex)" = 0 ]'

echo "== wrong lane / metadata"
go real --model claude-fable-5-1 -p hi --output-format json --no-session-persistence; ck "fable launch emitting the same bytes: nonfable envelope is no authority for Fable: no state" '[ "$(nex)" = 0 ]'
go real --model claude-haiku-5-5 -p hi --output-format json --no-session-persistence;  ck "haiku (nonfable lane) is the nonfable lane: recorded for its account" 'jex'

echo "== synthetic envelope negatives (unpinned, json, rc 1): none may retire a lane"
for m in not_error err_str err_missing st_500 st_str st_bool st_float st_missing type_other tr_other tr_missing quoted suffix other_text auth net spend result_int malformed prefixed two array badutf8; do
  go $m "${NJ[@]}" --no-session-persistence; ck "synthetic $m: no state" '[ "$(nex)" = 0 ]'
done
go not_error "${NJ[@]}" --no-session-persistence; ck "same phrase with is_error=false never exhausts" '[ "$(nex)" = 0 ] && grep -q "weekly limit" $T/out'
for r in 0 124 137 143; do rm -rf "$T/lanes"; python3 "$T/mut.py" real "$T/out.bin" "$FIX"; FAKE_RC=$r "$L" "${NJ[@]}" --no-session-persistence >/dev/null 2>&1; ck "rc $r with the real bytes: no state" '[ "$(nex)" = 0 ]'; done

echo "== explicit SID protections (fixture has no session_id)"
go real "${NJ[@]}" --session-id $S1 --no-session-persistence;  ck "explicit --session-id X + retained fixture (no id): blocked" '[ "$(nex)" = 0 ] && grep -q "carries no usable session_id" $T/err'
go real "${NJ[@]}" --session-id=$S1;                            ck "--session-id=X + no id in result: blocked" '[ "$(nex)" = 0 ]'
SIDMODE=echo go sid_echo "${NJ[@]}" --session-id $S1 --no-session-persistence; ck "synthetic: result echoes the passed id: recorded, audit matches" 'jex && jq -e "select(.event==\"native_envelope_limit\")|.sid_correlation|test(\"matches\")" "$T/lanes/events.jsonl" >/dev/null'
for m in sid_other sid_null sid_empty; do go $m "${NJ[@]}" --session-id $S1 --no-session-persistence; ck "synthetic $m with a passed id: blocked" '[ "$(nex)" = 0 ]'; done
SIDMODE=echo go sid_echo "${NJ[@]}"; ck "launcher-injected id echoed: recorded" 'jex'
go sid_present_unpinned "${NJ[@]}" --no-session-persistence; ck "synthetic: unpinned run whose result carries some native id: recorded, uncorrelated (never adopted)" 'jex && jq -e "select(.event==\"native_envelope_limit\")|(.sid_correlation|startswith(\"none\")) and .native_session_id!=\"\" and .claimed_session!=.native_session_id" "$T/lanes/events.jsonl" >/dev/null && ! jq -e ".sessions|has(\"99999999-9999-4999-8999-999999999999\")" "$T/lanes/sessions.json" >/dev/null'
go sid_other "${NJ[@]}" --session-id $S1; ck "blocked run leaves the session unknown (not clean) and writes no native_envelope_limit audit" 'jq -e --arg s $S1 ".sessions[\$s].state!=\"clean\" and .sessions[\$s].unknown_effect==true" "$T/lanes/sessions.json" >/dev/null && ! grep -q native_envelope_limit "$T/lanes/events.jsonl"'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
