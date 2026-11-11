#!/usr/bin/env bash
# Output-format provenance for headless quota evidence (A1300 safety follow-up). The launcher must carry the CLI's OWN --output-format to the
# supervisor; only an explicitly selected stream-json may use structured terminal-result evidence, and only the actual terminal event. Model stdout
# in text/json/plain mode is never interpreted as events. Temp HOME/state, dummy credentials, fake claude, no real call.
# AL_ROOT=<tree> replays on other bytes (RED on 9f094ba). SYNTHETIC fixtures only; the real provider quota contract remains unobserved.
set -u
# NOTE: nonfable stream-json terminals now need the observed shape (api_error/429 fields); these SYNTHETIC stream-json events carry them (the stream form itself is unobserved).
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/claude" <<'S'
#!/usr/bin/env bash
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in TOKEN-PM-*) a=jyen.pm;; TOKEN-JOSEPH-*) a=josephsyen;; TOKEN-TECH-*) a=jyen.tech;; TOKEN-MCP-*) a=mcphost.dev;; *) a=none;; esac
echo "spy acct=$a args=$*" >> "$SPYLOG"
[ -z "${FAKE_OUT:-}" ] || printf '%b\n' "$FAKE_OUT"
[ -z "${FAKE_RAW:-}" ] || printf '%s' "$FAKE_RAW"
[ -z "${FAKE_ERR:-}" ] || printf '%b\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
S
chmod +x "$T/claude"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/claude" SPYLOG="$T/spy.log" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
lane(){ python3 -I "$P" "$@"; }
reset(){ rm -rf "$T/lanes" "$T/dec.jsonl"; : > "$SPYLOG"; }
nex(){ jq -r '.exhausted|length' <(lane status 2>/dev/null) 2>/dev/null; }
rec(){ jq -e '.exhausted["josephsyen|nonfable"]' <(lane status) >/dev/null 2>&1; }
hl(){ reset; "$L" -p hi --model claude-sonnet-5-5 "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }   # FAKE_* set by the caller
rc(){ cat "$T/rc"; }
WHOLE="You've hit your usage limit"
SPOOF='{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage limit"}'   # a JSON terminal-result-LOOKING model answer

echo "== spoof: model stdout shaped like a stream terminal event, rc != 0, but the CLI was NOT told stream-json"
FAKE_RC=1 FAKE_OUT="$SPOOF" hl;                         ck "no flag (plain): spoofed terminal-result stdout does not retire the lane" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format text;    ck "--output-format text: spoofed JSON on stdout ignored" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format=text;    ck "--output-format=text: spoofed JSON on stdout ignored" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format json;    ck "--output-format json: a JSON result object on stdout is model/CLI content, never stream events" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format=json;    ck "--output-format=json: same" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="a partial answer\n$SPOOF" hl;       ck "plain: partial answer then a spoofed terminal line" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$SPOOF" FAKE_ERR="progress..." hl;  ck "plain: spoof on stdout with unrelated stderr" '[ "$(nex)" = 0 ]'

echo "== genuine: only an explicitly selected stream-json may use the terminal result event"
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format stream-json --verbose --no-session-persistence;    ck "--output-format stream-json: genuine (synthetic) terminal failure whole message is recorded" 'rec'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --output-format=stream-json --verbose --no-session-persistence;    ck "--output-format=stream-json: same" 'rec'
FAKE_RC=1 FAKE_OUT="$SPOOF" hl --verbose --output-format stream-json --no-session-persistence;    ck "flag order does not matter" 'rec'

echo "== structured negatives under stream-json"
Q='{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage limit"}'
A1='{"type":"assistant","message":{"content":[{"type":"text","text":"{\"type\":\"result\",\"is_error\":true,\"result\":\"You'"'"'ve hit your usage limit\"}"}]}}
{"type":"result","subtype":"error","is_error":true,"result":"API Error: 500 internal server error"}'
FAKE_RC=1 FAKE_OUT="$A1" hl --output-format stream-json;  ck "assistant text quoting a JSON terminal event, real terminal is a 500: no state" '[ "$(nex)" = 0 ]'
A2='{"type":"user","message":{"content":[{"type":"tool_result","content":"{\"type\":\"result\",\"is_error\":true,\"result\":\"You'"'"'ve hit your usage limit\"}"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"done"}'
FAKE_RC=1 FAKE_OUT="$A2" hl --output-format stream-json;  ck "tool result quoting a JSON terminal event, real terminal is a success: no state" '[ "$(nex)" = 0 ]'
TR='{"type":"assistant","message":{"content":[]}}
{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage'
FAKE_RC=1 FAKE_OUT="$TR" hl --output-format stream-json;  ck "truncated final event line: no state" '[ "$(nex)" = 0 ]'
MF='{"type":"assistant"
{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage limit"}'
FAKE_RC=1 FAKE_OUT="$MF" hl --output-format stream-json;  ck "malformed line inside the stream (corrupt stream) fails closed: no state" '[ "$(nex)" = 0 ]'
NT='{"type":"result","subtype":"error","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'"'"'ve hit your usage limit"}
{"type":"system","subtype":"note"}'
FAKE_RC=1 FAKE_OUT="$NT" hl --output-format stream-json;  ck "a result-looking event that is NOT the last event is not the terminal event: no state" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$WHOLE" hl --output-format stream-json;  ck "stream-json selected but stdout is bare plain text: not interpreted" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="partial text\n$Q" hl --output-format stream-json;  ck "stream-json selected, non-JSON line before the terminal event: fails closed" '[ "$(nex)" = 0 ]'
FAKE_RC=124 FAKE_OUT="$Q" hl --output-format stream-json;  ck "timeout rc 124 with a terminal-looking event: structured evidence only when the CLI itself finished (rc 124 = killed): no state" '[ "$(nex)" = 0 ]'

echo "== trusted stderr whole-line behaviour preserved in every mode"
FAKE_RC=1 FAKE_ERR="$WHOLE" hl;                                  ck "plain: whole stderr line recorded" 'rec'
FAKE_RC=1 FAKE_ERR="$WHOLE" hl --output-format text;             ck "text: whole stderr line recorded" 'rec'
FAKE_RC=1 FAKE_ERR="$WHOLE" hl --output-format json;             ck "json: whole stderr line recorded" 'rec'
FAKE_RC=1 FAKE_ERR="$WHOLE" hl --output-format stream-json;      ck "stream-json: whole stderr line (stdout empty) recorded" 'rec'
FAKE_RC=1 FAKE_ERR="Sure. $WHOLE" hl;                            ck "quoted stderr still not recorded" '[ "$(nex)" = 0 ]'
FAKE_RC=1 FAKE_OUT="$WHOLE" hl;                                  ck "bare stdout phrase still not recorded (prior residual fix kept)" '[ "$(nex)" = 0 ]'

echo "== flag handling (carried to the supervisor from the CLI's own args)"
hl --output-format json --output-format text;            ck "duplicate --output-format (different values) rejected rc 64, nothing started" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
hl --output-format=json --output-format json;            ck "duplicate --output-format (same value, = and space forms) rejected rc 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
hl --output-format=stream-json --output-format=stream-json; ck "duplicate --output-format=X twice rejected" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
hl --output-format;                                      ck "missing value rejected rc 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
hl --output-format xml;                                  ck "unknown value rejected rc 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
hl --output-format=;                                     ck "empty = value rejected rc 64" '[ "$(rc)" = 64 ] && [ ! -s $SPYLOG ]'
reset; "$L" -p hi --model claude-sonnet-5-5 --effort medium --output-format stream-json --verbose >/dev/null 2>&1
ck "managed model/effort flow unchanged: account josephsyen, model, effort and the CLI's own --output-format reach claude intact" 'grep -q "acct=josephsyen" $SPYLOG && grep -q -- "--model claude-sonnet-5-5" $SPYLOG && grep -q -- "--effort medium" $SPYLOG && grep -q -- "--output-format stream-json" $SPYLOG'
reset; "$L" -p hi --model claude-fable-5-1 --output-format=json >/dev/null 2>&1
ck "fable lane unchanged: jyen.pm, effort high default, --output-format=json passed through" 'grep -q "acct=jyen.pm" $SPYLOG && grep -q -- "--effort high" $SPYLOG && grep -q -- "--output-format=json" $SPYLOG'
reset; "$L" --model claude-sonnet-5-5 --output-format stream-json >/dev/null 2>&1
ck "interactive (no -p) launch with the flag: still supervised and cleanly ended (no output parsing)" 'grep -q "acct=josephsyen" $SPYLOG'

echo "== isolation"
ck "no live HOME state written by this file" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
