#!/usr/bin/env bash
# ctl-event-route fixture test (A1148): stubs only (tmux, waiter, claude spy), temp HOME, no real pane, no real model.
# RED: with routing off (BR_ROUTE=0, the pre-change path) a routine event is typed into the Fable pane.
# GREEN: routine events cost zero Fable deliveries, judgment events reach the pane with reason=, every id acks exactly once.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
BR="$root/.local/bin/ctl-event-bridge.sh"; RTS="$root/.local/bin/ctl-event-route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; f=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
mkdir -p "$T/home" "$T/av"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\nif [ "$1" = list-panes ]; then echo claude; fi\nexit 0\n' "$T" > "$T/tmux"
printf '#!/bin/sh\nl=$(head -n1 %s/ev 2>/dev/null)\nif [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo "{\\"event\\":\\"timeout\\"}"; fi\nexit 0\n' "$T" "$T" > "$T/ew"
# claude spy: records every invocation (args + prompt head), replies with $T/reply
printf '#!/bin/sh\necho "$*" >> %s/calls.log\ncat > %s/last-prompt\ncat %s/reply\n' "$T" "$T" "$T" > "$T/claude"
chmod +x "$T/tmux" "$T/ew" "$T/claude"
reply() { python3 -I -c 'import json,sys; print(json.dumps({"type":"result","session_id":"spy-sess-1","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.0001,"result":sys.argv[1]}))' "$1" > "$T/reply"; }
env_() { env -i HOME="$T/home" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 RETRY_SEC=1 WAIT_MAX_SEC=1 \
  BR_ROUTE="${BR_ROUTE:-1}" RT_BIN="${XRT_BIN:-$RTS}" RT_DIR="$T/rt" RT_STATE="$T/rt/state.json" RT_CLAUDE_BIN="${XCLAUDE:-$T/claude}" "$@"; }
br() { env_ BR_CYCLES="${BR_CYCLES:-3}" bash "$BR" "$@"; }
fresh() { rm -rf "$T/br" "$T/rt"; : > "$T/tmux.log"; : > "$T/calls.log"; : > "$T/ev"; }
calls() { grep -c . "$T/calls.log"; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
q() { ls "$T/br/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$T/br/done"/*.json 2>/dev/null | wc -l; }
acks() { grep -c ' ack ' "$T/br/deliveries.log"; }
jf() { python3 -I -c 'import json,sys; v=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$1" "$2"; }
echo '{"verdict":"CONFIRM","sha":"3299862fa"}' > "$T/av/result.json"
EV_JUDGE="{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/result.json\"]}}"
EV_ALARM='{"event":"alarm","ts":"t","detail":{"new":["ask-overdue #","decision-unverdicted #"]}}'
EV_SIMPLE='{"event":"inbox","ts":"t","detail":{"lines":["t | rb | rb-info nightly lint finished, nothing to do"]}}'
EV_JUDG='{"event":"inbox","ts":"t","detail":{"lines":["t | hermes-urgent | should the prod deploy be cancelled?"]}}'

# (g) RED: the pre-change path (routing off) types a routine judge completion into the Fable pane
fresh; echo "$EV_JUDGE" > "$T/ev"; reply '{"route":"handled","summary":"s","reason":"r"}'; BR_ROUTE=0 br run
[ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ]; chk "RED: pre-change path delivers a routine judge completion to the pane" $?

# (a) routine judge completion -> deterministic, 0 model calls, acked by the bridge, nothing to the pane
fresh; echo "$EV_JUDGE" > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ]; chk "(a) routine judge completion: 0 model calls, 0 pane deliveries, acked" $?
r="$(ls "$T/rt/routed"/*.json)"; [ "$(jf "$r" route)" = deterministic ] && [ "$(jf "$r" model)" = none ] && [ "$(jf "$r" result)" = record ]; chk "(a) route=deterministic model=none result=record" $?
grep -q '"result": "record"' "$T/rt/mechanical.log"; chk "(a) mechanical.log holds the record" $?

# (b) unchanged alarm status -> deterministic
fresh; mkdir -p "$T/rt"; echo '{"alarms":["ask-overdue #","decision-unverdicted #"]}' > "$T/rt/state.json"; echo "$EV_ALARM" > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(d)" = 1 ]; chk "(b) unchanged alarm set: 0 calls, 0 deliveries, acked" $?
[ "$(jf "$(ls "$T/rt/routed"/*.json)" result)" = unchanged ]; chk "(b) result=unchanged" $?
# a CHANGED alarm set is judgment: delivered
fresh; mkdir -p "$T/rt"; echo '{"alarms":["other #"]}' > "$T/rt/state.json"; echo "$EV_ALARM" > "$T/ev"; br run
[ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ] && [ "$(calls)" = 0 ]; chk "(b2) changed alarm set: delivered to pane, 0 haiku calls" $?

# (c) simple inbox task -> haiku handled: exactly 1 haiku call, 0 deliveries, acked once
fresh; echo "$EV_SIMPLE" > "$T/ev"; reply '{"route":"handled","summary":"lint finished","reason":"routine receipt"}'; br run
[ "$(calls)" = 1 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(c) simple inbox: 1 haiku call, 0 pane deliveries, acked once" $?
grep -q -- '--model claude-haiku-5-5 --output-format json' "$T/calls.log" && grep -q -- '^-p ' "$T/calls.log"; chk "(c) haiku invoked as claude -p --model claude-haiku-5-5 --output-format json" $?
[ "$(jf "$T/rt/model-calls.log" model_call.response_id)" = spy-sess-1 ] && [ -n "$(jf "$T/rt/model-calls.log" model_call.usage.output_tokens)" ]; chk "(c) model-calls.log carries response id + usage" $?
grep -q '"result": "handled"' "$T/rt/mechanical.log"; chk "(c) mechanical.log holds the handled summary" $?

# (d) judgment inbox -> haiku says fable: 1 call, pane line has id + reason=, acked only by the consumer ack
fresh; echo "$EV_JUDG" > "$T/ev"; reply '{"route":"fable","summary":"deploy question","reason":"asks for a prod decision"}'; br run
id="$(ls "$T/br/queue"/*.json | xargs -n1 basename | sed 's/\.json$//')"
[ "$(calls)" = 1 ] && [ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "(d) judgment inbox: 1 haiku call, delivered, still queued (unacked)" $?
grep -- '-l ctl-event' "$T/tmux.log" | grep -q "$id" && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=haiku:asks for a prod decision'; chk "(d) pane line contains the id and reason=" $?
[ "$(jf "$T/rt/model-calls.log" route)" = fable ] && [ "$(jf "$T/rt/model-calls.log" classified_by)" = haiku ]; chk "(d) model-calls.log: route=fable classified_by=haiku" $?
br ack "$id" >/dev/null; [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(d) per-id consumer ack moves it to done/ exactly once" $?

# (d2) a Joe line never goes to haiku
fresh; echo '{"event":"inbox","ts":"t","detail":{"lines":["t | joe-direct | what is the status?"]}}' > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" -ge 1 ]; chk "(d2) joe line: no haiku call, delivered" $?
# (d3) hold and taskfile events go to the pane with a reason
fresh; printf '%s\n' '{"event":"hold","ts":"t","detail":{"hold":"abc"}}' '{"event":"taskfile","ts":"t","detail":{"files":["x.md"]}}' > "$T/ev"; BR_CYCLES=4 br run
[ "$(calls)" = 0 ] && [ "$(q)" = 2 ] && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=hold-event-is-judgment' && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=taskfile-is-joe-hermes-direction'; chk "(d3) hold + taskfile: delivered with reasons, 0 haiku calls" $?

# (e) malformed haiku -> fable, not dropped
fresh; echo "$EV_SIMPLE" > "$T/ev"; echo 'not json at all' > "$T/reply"; br run
[ "$(calls)" = 1 ] && [ "$(q)" = 1 ] && [ "$(sends)" -ge 1 ] && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=haiku-unparseable'; chk "(e) malformed haiku: routed to fable (haiku-unparseable), still queued, delivered" $?
reply 'sure thing!'; fresh; echo "$EV_SIMPLE" > "$T/ev"; br run
[ "$(q)" = 1 ] && [ "$(sends)" -ge 1 ]; chk "(e2) valid wrapper but non-JSON verdict: routed to fable" $?
printf '#!/bin/sh\nexit 3\n' > "$T/claude-fail"; chmod +x "$T/claude-fail"; fresh; echo "$EV_SIMPLE" > "$T/ev"; XCLAUDE="$T/claude-fail" br run
[ "$(q)" = 1 ] && [ "$(sends)" -ge 1 ]; chk "(e3) failing haiku binary: routed to fable, not dropped" $?

# (f) restart: routed cache reused, no second model call, each id acked exactly once
fresh; printf '%s\n' "$EV_SIMPLE" "$EV_JUDG" > "$T/ev"; reply '{"route":"handled","summary":"s","reason":"r"}'
# second event gets the fable verdict: swap the reply after the first call via a counting spy
printf '#!/bin/sh\necho "$*" >> %s/calls.log\ncat > /dev/null\nif [ "$(grep -c . %s/calls.log)" = 1 ]; then cat %s/reply; else cat %s/reply2; fi\n' "$T" "$T" "$T" "$T" > "$T/claude"
python3 -I -c 'import json,sys; print(json.dumps({"session_id":"s2","usage":{"output_tokens":3},"result":"{\"route\":\"fable\",\"summary\":\"q\",\"reason\":\"needs decision\"}"}))' > "$T/reply2"
BR_CYCLES=4 br run
c1="$(calls)"; s1="$(sends)"; [ "$c1" = 2 ] && [ "$(d)" = 1 ] && [ "$(q)" = 1 ]; chk "(f) first run: 2 haiku calls, handled acked, judgment queued" $?
BR_CYCLES=2 br run
[ "$(calls)" = "$c1" ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(f) restart: routed cache reused, no double ack" $?
# crash window: router wrote its cache but the bridge died before acking -> restart acks from the cache, no model call
fresh; echo "$EV_SIMPLE" > "$T/ev"; reply '{"route":"handled","summary":"s","reason":"r"}'
BR_CYCLES=1 BR_ROUTE=0 br run   # queue it only (routing off, delivered, unacked)
qf="$(ls "$T/br/queue"/*.json)"; env_ bash "$RTS" route "$qf" >/dev/null; c2="$(calls)"
br ack nope >/dev/null 2>&1
BR_CYCLES=2 br run
[ "$(calls)" = "$c2" ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(f) crash between route and ack: restart acks from cache, no new model call, acked once" $?
# replaying the router on a cached id prints the cached line and makes no call and no second log line
l1="$(grep -c . "$T/rt/model-calls.log")"; env_ bash "$RTS" route "$qf" >/dev/null 2>&1; [ "$(grep -c . "$T/rt/model-calls.log")" = "$l1" ] && [ "$(calls)" = "$c2" ]; chk "(f) router replay on a cached id: no call, no second log record" $?

# never ack unseen ids: an id with no cache and a missing router stays queued and delivered
fresh; echo "$EV_JUDGE" > "$T/ev"; XRT_BIN="$T/nonexistent" br run
[ "$(q)" = 1 ] && [ "$(sends)" -ge 1 ]; chk "missing router: nothing acked, event still delivered (fail-safe)" $?

echo "ctl-event-route test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"
exit $f
