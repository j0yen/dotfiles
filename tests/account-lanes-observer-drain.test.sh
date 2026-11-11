#!/usr/bin/env bash
# D1-N1: a stream observer / JSON-parse failure must never stop stdout draining. The review repro: a ~400 KB deeply nested JSON line raised
# RecursionError in the stdout pump thread, the thread died, the child blocked on a full pipe and the launcher hung. Required: the launcher exits
# with the child's original rc, forwards every stdout byte (length + sha256 equal to what the child wrote), prints no traceback, never retires a
# lane from a failed observer (unknown + a sanitized reason), and a real long valid stream is still detected. SYNTHETIC fixtures; temp HOME/state,
# dummy credentials, fake CLI; no real call. AL_ROOT=<tree> replays on other bytes (RED on fb9c074). Recursion limits are NOT raised anywhere.
# Watchdog: run.py kills ONLY the process group of the launcher it started (its own fake child) after WD seconds and reports HANG.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env python3
import os, sys
out = sys.stdout.buffer
data = open(os.environ["FAKE_STREAM_FILE"], "rb").read()
for i in range(0, len(data), 4096):
    out.write(data[i:i + 4096]); out.flush()
if os.environ.get("FAKE_KILL"):
    os.kill(os.getpid(), 9)
sys.exit(int(os.environ.get("FAKE_RC", "0")))
S
chmod +x "$T/claude"
cat > "$T/run.py" <<'S'
import os, signal, subprocess, sys
outf, errf, wd = sys.argv[1], sys.argv[2], float(sys.argv[3]); cmd = sys.argv[4:]
with open(outf, "wb") as o, open(errf, "wb") as e:
    p = subprocess.Popen(cmd, stdout=o, stderr=e, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        sys.exit(p.wait(timeout=wd))
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.wait(); print("HANG", file=sys.stderr); sys.exit(999)
S
cat > "$T/gen.py" <<'G'
import json, sys
mode, out = sys.argv[1:3]
Q = "You've hit your usage limit"
term = json.dumps({"type": "result", "subtype": "error", "is_error": True, "terminal_reason": "api_error", "api_error_status": 429, "result": Q})
def ev(i): return json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "e%d " % i + "x" * 240}]}})
many = lambda n: [ev(i) for i in range(n)]
raw = None
if mode == "review":      deep = "[" * 200000 + "]" * 200000;                    lines = many(5) + [deep] + many(2000) + [term]
elif mode == "deepobj":   deep = '{"a":' * 100000 + "1" + "}" * 100000;           lines = many(5) + [deep] + many(2000) + [term]
elif mode == "deepshort": deep = "[" * 200000 + "]" * 200000;                    lines = many(5) + [deep] + [term]
elif mode == "malformed": lines = many(5) + ['{"type":"assist'] + many(2000) + [term]
elif mode == "badutf8":   lines = many(5); raw = ("\n".join(lines) + "\n").encode() + b'{"type":"assistant","x":"\xff\xfe"}\n' + ("\n".join(many(2000) + [term]) + "\n").encode()
elif mode == "valid":     lines = many(2000) + [term]
elif mode == "validdeep_ok": lines = many(5) + ["[" * 500 + "]" * 500] + many(2000) + [term]   # 500 deep: parses fine, but is a non-object line => untrusted
else: sys.exit("mode")
open(out, "wb").write(raw if raw is not None else ("\n".join(lines) + "\n").encode())
G
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
rec(){ jq -e '.exhausted["josephsyen|nonfable"]' <(lane status) >/dev/null 2>&1; }
SJ="--output-format stream-json --verbose --no-session-persistence"
# go <mode> <rc> [extra env assignments via env prefix by caller] : RC = launcher rc (999 = watchdog HANG)
go() { local m="$1" rcode="$2"; shift 2; rm -rf "$T/lanes"; : > "$SPYLOG"; python3 "$T/gen.py" "$m" "$T/stream.bin"
  FAKE_STREAM_FILE="$T/stream.bin" FAKE_RC="$rcode" python3 "$T/run.py" "$T/out" "$T/err" 25 "$L" -p hi --model claude-sonnet-5-5 "$@"; RC=$?; }
same(){ [ "$(stat -c %s "$T/out")" = "$(stat -c %s "$T/stream.bin")" ] && [ "$(sha256sum < "$T/out")" = "$(sha256sum < "$T/stream.bin")" ]; }
clean(){ ! grep -q "Traceback\|^  File \"\|maximum recursion" "$T/err"; }

echo "== exact review repro: 5 valid + array depth 200000 (~400 KB) + 2000 valid + terminal quota, rc 1"
go review 1 $SJ
ck "stream is ~980 KB as in the review" '[ "$(stat -c %s $T/stream.bin)" -gt 900000 ]'
ck "launcher exits with the original rc 1 (no hang)" '[ $RC = 1 ]'
ck "every stdout byte forwarded: length and sha256 equal to the child output" 'same'
ck "no traceback on stderr (only the sanitized reason names the class)" 'clean'
ck "lane unchanged (no wrong quota state from a failed observer)" '[ "$(nex)" = 0 ]'
ck "explicit sanitized reason printed (class name only, no event text)" 'grep -q "stream evidence: .*could not be parsed (RecursionError)" $T/err && ! grep -q "hit your" $T/err'
go deepshort 1 $SJ;  ck "deep line then only a short tail: rc 1, bytes equal, no traceback, no state" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ]'
go deepobj 1 $SJ;    ck "deep nested OBJECT (~600 KB): rc 1, bytes equal, no traceback, no state, reason" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ] && grep -q "stream evidence" $T/err'

echo "== malformed / invalid UTF-8 followed by a >64 KB tail"
go malformed 1 $SJ;  ck "malformed line: drained, rc 1, bytes equal, no state" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ] && grep -q "corrupt event line" $T/err'
go badutf8 1 $SJ;    ck "invalid UTF-8 event: drained, rc 1, bytes equal, no state" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ] && grep -q "stream evidence" $T/err'
ck "tail after the bad line exceeded the 64 KB pipe buffer" '[ "$(stat -c %s $T/stream.bin)" -gt 200000 ]'
go validdeep_ok 1 $SJ; ck "500-deep non-object line: untrusted (corrupt), drained, no state" '[ $RC = 1 ] && same && [ "$(nex)" = 0 ]'

echo "== injected ordinary exceptions at the observer boundary (test-only knob, honoured only with ACCOUNT_LANE_TEST=1)"
export ACCOUNT_LANE_INJECT=feed;   go valid 1 $SJ
ck "feed raises: drained, rc 1, bytes equal, no traceback, no state" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ]'
ck "feed failure reason is explicit and names only the exception class" 'grep -q "observer failure in feed (RuntimeError)" $T/err && ! grep -q injected $T/err'
export ACCOUNT_LANE_INJECT=finish; go valid 1 $SJ
ck "finish raises: rc 1, bytes equal, no traceback, no state" '[ $RC = 1 ] && same && clean && [ "$(nex)" = 0 ]'
ck "finish failure reason is explicit" 'grep -q "observer failure in finish (RuntimeError)" $T/err'
unset ACCOUNT_LANE_INJECT

echo "== original child return / signal handling preserved on a failing observer"
go review 3 $SJ;   ck "child rc 3 -> launcher rc 3, bytes equal" '[ $RC = 3 ] && same && [ "$(nex)" = 0 ]'
go review 0 $SJ;   ck "child rc 0 -> launcher rc 0, bytes equal" '[ $RC = 0 ] && same && [ "$(nex)" = 0 ]'
rm -rf "$T/lanes"; python3 "$T/gen.py" review "$T/stream.bin"
FAKE_STREAM_FILE="$T/stream.bin" FAKE_KILL=1 python3 "$T/run.py" "$T/out" "$T/err" 25 "$L" -p hi --model claude-sonnet-5-5 $SJ; RC=$?
ck "child SIGKILLed mid-failure: launcher exits 137 (128+9), no hang, no state" '[ $RC = 137 ] && [ "$(nex)" = 0 ]'

echo "== positive controls: provenance and real detection unchanged"
go valid 1 $SJ;                        ck "long VALID stream + genuine terminal quota event: still recorded, bytes equal" '[ $RC = 1 ] && same && rec'
go review 1 --output-format json;      ck "json mode: deep stdout is model content, drained, never judged" '[ $RC = 1 ] && same && [ "$(nex)" = 0 ]'
go valid 1;                            ck "plain mode: valid-looking stream never judged" '[ $RC = 1 ] && same && [ "$(nex)" = 0 ]'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
