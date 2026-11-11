#!/usr/bin/env bash
# D1 stream-tail correctness (A1300 output provenance follow-up). A genuine stream-json terminal quota failure must be detected however much
# valid event output precedes it, however the bytes are chunked, while every provenance rule holds: format from the CLI's own --output-format,
# whole-message quota text, last event = terminal result, corrupt/mixed/killed streams = no evidence, model stdout in text/json/plain = no evidence.
# Bounds under test: per-event-line cap (default 8 MiB; ACCOUNT_LANE_MAX_EVENT_LINE honoured ONLY with ACCOUNT_LANE_TEST=1 so the boundary is testable at 2000 bytes).
# SYNTHETIC fixtures; temp HOME/state, dummy credentials, fake CLI; no real call. AL_ROOT=<tree> replays on other bytes (RED on 02eb918).
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env python3
import os, sys, time, json
sys.stdout.flush()
open(os.environ["SPYLOG"], "a").write("spy args=%s\n" % " ".join(sys.argv[1:]))
data = open(os.environ["FAKE_STREAM_FILE"], "rb").read() if os.environ.get("FAKE_STREAM_FILE") else b""
sizes = json.load(open(os.environ["FAKE_CHUNKS_FILE"])) if os.environ.get("FAKE_CHUNKS_FILE") else []
out = sys.stdout.buffer; pos = 0
for n in sizes:
    out.write(data[pos:pos + n]); out.flush(); pos += n; time.sleep(0.005)
out.write(data[pos:]); out.flush()
if os.environ.get("FAKE_ERR"):
    sys.stderr.write(os.environ["FAKE_ERR"] + "\n"); sys.stderr.flush()
if os.environ.get("FAKE_KILL"):
    os.kill(os.getpid(), 9)
sys.exit(int(os.environ.get("FAKE_RC", "0")))
S
chmod +x "$T/claude"
cat > "$T/gen.py" <<'G'
# gen.py <mode> <outfile> <chunksfile> : writes a SYNTHETIC stream and a chunk-size plan
import json, sys
mode, out, chunks = sys.argv[1:4]
Q = "You've hit your usage limit"
def term(pad=0, text=Q):
    o = {"type": "result", "subtype": "error", "is_error": True, "terminal_reason": "api_error", "api_error_status": 429, "result": text}
    if pad: o["pad"] = ""
    s = json.dumps(o, ensure_ascii=False)
    if pad: s = s.replace('"pad": ""', '"pad": "%s"' % ("p" * (pad - len(s.encode()))))
    return s
def asst(i): return json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "event %d " % i + "x" * 100}]}})
init = json.dumps({"type": "system", "subtype": "init", "tools": ["Read", "Bash"], "session_id": "s", "cwd": "/tmp"})
tool = json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": "t" * 300}]}})
def many(n): return [asst(i) if i % 3 else (tool if i % 2 else init) for i in range(n)]
lines = []; plan = []
CAP = 2000
if mode == "long300": lines = many(300) + [term()]
elif mode == "long20000": lines = many(20000) + [term()]
elif mode == "short": lines = many(3) + [term()]
elif mode == "boundary_nl":      # a chunk ends exactly after a newline and the next chunk starts the terminal line
    lines = many(300); pre = ("\n".join(lines) + "\n").encode(); lines = lines + [term()]; plan = [len(pre)]
elif mode == "split_before_nl":  # chunk boundary falls between the last byte of the terminal line and its newline
    lines = many(300); pre = ("\n".join(lines) + "\n").encode(); lines = lines + [term()]; plan = [len(pre) + len(term().encode())]
elif mode == "crlf_split":       # CRLF line ends, split between CR and LF
    lines = many(300); lines = [l + "\r" for l in lines] + [term() + "\r"]; pre = ("\n".join(lines[:-1]) + "\n").encode(); plan = [len(pre) - 1, 1]
elif mode == "midjson_split":    # terminal line cut into three chunks inside the JSON
    lines = many(300); pre = ("\n".join(lines) + "\n").encode(); t = term().encode(); lines = lines + [term()]; plan = [len(pre) + 10, 20]
elif mode == "multibyte_split":  # a multibyte character in an earlier event is cut between its bytes
    mb = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "é" * 50}]}}, ensure_ascii=False)
    lines = many(300) + [mb] + [term()]; pre = ("\n".join(lines[:300]) + "\n").encode(); plan = [len(pre) + mb.encode().index("é".encode()) + 1]
elif mode == "tiny_chunks":      # many 1..7-byte chunks across the end of the stream
    lines = many(60) + [term()]; total = len(("\n".join(lines) + "\n").encode()); plan = [1, 2, 3, 5, 7] * 40
elif mode == "cap_exact":        # terminal line exactly CAP bytes
    lines = many(300) + [term(pad=CAP)]
elif mode == "cap_plus1":        # terminal line CAP+1 bytes: oversized FINAL line
    lines = many(300) + [term(pad=CAP + 1)]
elif mode == "oversized_mid":    # a valid but oversized NON-final event, then a genuine terminal
    lines = many(50) + [json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": "z" * (CAP + 500)}]}})] + many(50) + [term()]
elif mode == "oversized_mid_noncap":  # same big line but under the cap: fine
    lines = many(50) + [json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": "z" * (CAP - 400)}]}})] + many(50) + [term()]
elif mode == "leading_corrupt":  # an ACTUAL corrupt first line far from the tail
    lines = ['{"type":"assist'] + many(300) + [term()]
elif mode == "mid_corrupt":
    ev = many(300); ev[150] = '{"type": "assistant", "message": {'; lines = ev + [term()]
elif mode == "mixed_plain":      # a plain-text line in the middle of the stream
    ev = many(300); ev[100] = "Sure here is some prose"; lines = ev + [term()]
elif mode == "result_not_last":
    lines = many(300) + [term(), json.dumps({"type": "system", "subtype": "note"})]
elif mode == "nonresult_last":
    lines = many(300) + [json.dumps({"type": "assistant", "message": {"content": []}})]
elif mode == "result_success_last":
    lines = many(300) + [json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "done"})]
elif mode == "quote_not_whole":
    lines = many(300) + [term(text="Sure. " + Q)]
elif mode == "spoof_plain":      # model stdout (NOT told stream-json): long output ending in a spoofed terminal event
    lines = many(300) + [term()]
elif mode == "no_trailing_nl":
    lines = many(300) + [term()]; open(out, "wb").write("\n".join(lines).encode()); json.dump(plan, open(chunks, "w")); sys.exit(0)
else: sys.exit("unknown mode " + mode)
open(out, "wb").write(("\n".join(lines) + "\n").encode()); json.dump(plan, open(chunks, "w"))
G
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000 ACCOUNT_LANE_MAX_EVENT_LINE=2000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
rec(){ jq -e '.exhausted["josephsyen|nonfable"]' <(lane status) >/dev/null 2>&1; }
# sr <mode> <rc> [launcher args...] : generate the stream, run it through the REAL launcher/supervisor with the fake CLI
sr() { local m="$1" rcode="$2"; shift 2; rm -rf "$T/lanes"; : > "$SPYLOG"; python3 -I "$T/gen.py" "$m" "$T/stream.bin" "$T/chunks.json"
  FAKE_STREAM_FILE="$T/stream.bin" FAKE_CHUNKS_FILE="$T/chunks.json" FAKE_RC="$rcode" "$L" -p hi --model claude-sonnet-5-5 "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
SJ="--output-format stream-json --verbose --no-session-persistence"
W=$(stat -c %s /dev/null)

echo "== D1: long preceding valid stream then a genuine terminal quota result (explicit stream-json, rc 1)"
sr long300 1 $SJ;            ck "300 valid events (>16 KiB) then genuine terminal: recorded" 'rec'
ck "the stream really exceeded the old 16 KiB tail" '[ "$(stat -c %s $T/stream.bin)" -gt 30000 ]'
sr long300 1 --output-format=stream-json --verbose --no-session-persistence; ck "same with --output-format=stream-json" 'rec'
sr long20000 1 $SJ;          ck "20000 events (~4 MB total, many chunks): recorded; memory is per-line bounded, not per-stream" 'rec && [ "$(stat -c %s $T/stream.bin)" -gt 4000000 ]'
sr short 1 $SJ;              ck "short stream control still recorded" 'rec'

echo "== chunking: boundaries and splits"
sr boundary_nl 1 $SJ;        ck "chunk ends exactly at a newline, terminal line starts the next chunk" 'rec'
sr split_before_nl 1 $SJ;    ck "chunk boundary between the terminal line's last byte and its newline" 'rec'
sr crlf_split 1 $SJ;         ck "CRLF line ends split between CR and LF" 'rec'
sr midjson_split 1 $SJ;      ck "terminal line cut into three chunks inside the JSON" 'rec'
sr multibyte_split 1 $SJ;    ck "a multibyte character cut between its bytes in an earlier event" 'rec'
sr tiny_chunks 1 $SJ;        ck "1..7-byte chunks across the whole tail" 'rec'
sr no_trailing_nl 1 $SJ;     ck "terminal line without a trailing newline" 'rec'

echo "== per-event-line cap (test cap 2000 bytes; production default 8 MiB)"
sr cap_exact 1 $SJ;          ck "terminal line exactly at the cap: validated, recorded" 'rec'
sr cap_plus1 1 $SJ;          ck "oversized FINAL terminal line (cap+1): unknown, no state change" '[ "$(nex)" = 0 ]'
ck "oversized final line is reported with an explicit reason, not silently dropped" 'grep -q "stream evidence: .*exceeds" $T/err'
sr oversized_mid 1 $SJ;      ck "a valid-but-oversized NON-final event cannot be verified: whole stream fails closed (no state)" '[ "$(nex)" = 0 ]'
ck "reason names the cap" 'grep -q "stream evidence: .*exceeds" $T/err'
sr oversized_mid_noncap 1 $SJ; ck "a large event under the cap is validated normally: recorded" 'rec'

echo "== corrupt / mixed / not-last stay fail-closed (provenance preserved)"
sr leading_corrupt 1 $SJ;    ck "an ACTUAL corrupt first line far from the tail is not discarded as 'buffer truncation': no state" '[ "$(nex)" = 0 ]'
sr mid_corrupt 1 $SJ;        ck "a corrupt line in the middle of a long stream: no state" '[ "$(nex)" = 0 ]'
ck "corruption reason is reported" 'grep -q "stream evidence: .*corrupt" $T/err'
sr mixed_plain 1 $SJ;        ck "a plain-text line in the middle of a stream-json stream: not interpreted, no state" '[ "$(nex)" = 0 ]'
sr result_not_last 1 $SJ;    ck "terminal-looking result followed by another event: no state" '[ "$(nex)" = 0 ]'
sr nonresult_last 1 $SJ;     ck "long stream whose last event is not a result: no state" '[ "$(nex)" = 0 ]'
sr result_success_last 1 $SJ; ck "long stream ending in a SUCCESS result with rc 1: no state" '[ "$(nex)" = 0 ]'
sr quote_not_whole 1 $SJ;    ck "terminal error whose text only quotes the phrase: no state" '[ "$(nex)" = 0 ]'

echo "== killed runs"
for r in 124 137 143; do sr long300 $r $SJ; ck "rc $r with a genuine-looking long stream: no state" '[ "$(nex)" = 0 ]'; done
rm -rf "$T/lanes"; python3 -I "$T/gen.py" long300 "$T/stream.bin" "$T/chunks.json"; : > "$SPYLOG"
FAKE_STREAM_FILE="$T/stream.bin" FAKE_CHUNKS_FILE="$T/chunks.json" FAKE_KILL=1 "$L" -p hi --model claude-sonnet-5-5 $SJ >/dev/null 2>&1
ck "child killed by a signal after writing a genuine-looking long stream: no state" '[ "$(nex)" = 0 ]'
sr long300 0 $SJ;            ck "rc 0 (no failure) never classifies" '[ "$(nex)" = 0 ]'

echo "== model stdout in text/json/plain is still never evidence (long output)"
sr spoof_plain 1;                         ck "plain: long output ending in a spoofed terminal event" '[ "$(nex)" = 0 ]'
sr spoof_plain 1 --output-format text;    ck "text: same" '[ "$(nex)" = 0 ]'
sr spoof_plain 1 --output-format json;    ck "json: same" '[ "$(nex)" = 0 ]'
sr spoof_plain 1 --output-format=json;    ck "=json: same" '[ "$(nex)" = 0 ]'

echo "== trusted stderr whole-line behaviour retained alongside long stdout"
rm -rf "$T/lanes"; python3 -I "$T/gen.py" mixed_plain "$T/stream.bin" "$T/chunks.json"
FAKE_STREAM_FILE="$T/stream.bin" FAKE_CHUNKS_FILE="$T/chunks.json" FAKE_RC=1 FAKE_ERR="You've hit your usage limit" "$L" -p hi --model claude-sonnet-5-5 >/dev/null 2>&1
ck "plain mode: long stdout + whole stderr quota line: recorded from stderr" 'rec'
rm -rf "$T/lanes"; FAKE_STREAM_FILE="$T/stream.bin" FAKE_CHUNKS_FILE="$T/chunks.json" FAKE_RC=1 FAKE_ERR="You've hit your usage limit" "$L" -p hi --model claude-sonnet-5-5 $SJ >/dev/null 2>&1
ck "stream-json mode, stdout has non-JSON lines (unusable), whole stderr quota line: recorded from stderr" 'rec'
rm -rf "$T/lanes"; FAKE_STREAM_FILE="$T/stream.bin" FAKE_CHUNKS_FILE="$T/chunks.json" FAKE_RC=1 FAKE_ERR="Sure. You've hit your usage limit" "$L" -p hi --model claude-sonnet-5-5 >/dev/null 2>&1
ck "quoted stderr still not recorded" '[ "$(nex)" = 0 ]'

echo "== unchanged managed flow and flags"
rm -rf "$T/lanes"; : > "$SPYLOG"; FAKE_RC=0 "$L" -p hi --model claude-sonnet-5-5 --effort medium $SJ >/dev/null 2>&1
ck "account, model, effort and --output-format still reach claude intact" 'grep -q -- "--model claude-sonnet-5-5" $SPYLOG && grep -q -- "--effort medium" $SPYLOG && grep -q -- "--output-format stream-json" $SPYLOG'
"$L" -p hi --model claude-sonnet-5-5 --output-format json --output-format text >/dev/null 2>&1; ck "duplicate --output-format still rejected (64)" '[ $? = 64 ]'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
