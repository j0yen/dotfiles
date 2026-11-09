#!/usr/bin/env bash
# ctl-event-route fixture test (A1148, with Hermes acceptance corrections 11:12 PM): stubs only (tmux, waiter, claude spy), temp HOME,
# no real pane, no real model. NOTE: never put $(...) in a chk message ($? would be reset and the check would always pass).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
BR="$root/.local/bin/ctl-event-bridge.sh"; RTS="$root/.local/bin/ctl-event-route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; f=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
mkdir -p "$T/home" "$T/av"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\nif [ "$1" = list-panes ]; then echo claude; fi\nexit 0\n' "$T" > "$T/tmux"
printf '#!/bin/sh\nl=$(head -n1 %s/ev 2>/dev/null)\nif [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo "{\\"event\\":\\"timeout\\"}"; fi\nexit 0\n' "$T" "$T" > "$T/ew"
# claude spy: logs "<role> <model>" per call; role cls (classifier prompt) or exe (executor prompt); replies reply.<role>.<n> or reply.<role>;
# rc.<role> forces a failing exit; prompt text kept in last-prompt.<role>
cat > "$T/claude" <<SPY
#!/bin/sh
p=\$(cat)
model=""; while [ \$# -gt 0 ]; do [ "\$1" = --model ] && model="\$2"; shift; done
case "\$p" in *"You classify ONE"*) role=cls;; *) role=exe;; esac
printf '%s' "\$p" > $T/last-prompt.\$role
echo "\$role \$model" >> $T/calls.log
n=\$(grep -c "^\$role " $T/calls.log)
[ -f $T/rc.\$role ] && exit \$(cat $T/rc.\$role)
r=$T/reply.\$role.\$n; [ -f \$r ] || r=$T/reply.\$role
cat \$r
SPY
# wm-asks stub (A1255 canonical ledger): "asks query --json --status all --text M | --ids I" and "asks add --owner --due --key --check --what --by"; store = $T/asks.jsonl, ids continue from A1149
cat > "$T/wma" <<'WMA'
#!/usr/bin/env python3
import json, sys, os
a = sys.argv[1:]; st = os.environ["ASKS_STORE"]
rows = [json.loads(l) for l in open(st)] if os.path.exists(st) else []
if a[:2] == ["asks", "query"]:
    o = a[2:]; txt = o[o.index("--text") + 1] if "--text" in o else None; ids = o[o.index("--ids") + 1] if "--ids" in o else None
    print(json.dumps([r for r in rows if (txt is None or txt in r["what"]) and (ids is None or r["ask_id"] == ids)])); sys.exit(0)
if a[:2] == ["asks", "add"]:
    o = a[2:]; g = lambda k: o[o.index(k) + 1]
    r = {"ask_id": "A%d" % (1149 + len(rows)), "owner": g("--owner"), "due": g("--due"), "key": g("--key"), "check": g("--check"), "what": g("--what"), "by": g("--by")}
    open(st, "a").write(json.dumps(r) + "\n"); print(r["ask_id"]); sys.exit(0)
sys.exit(2)
WMA
printf '#!/bin/sh\ncat %s/asks.jsonl 2>/dev/null\n' "$T" > "$T/asksview"   # asks-view stub: the bridge greps it for the event marker before acking
chmod +x "$T/tmux" "$T/ew" "$T/claude" "$T/wma" "$T/asksview"
wrap() { python3 -I -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"session_id":"spy-sess","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.0001,"result":sys.argv[1]}))' "$2" > "$T/$1"; }
cls() { wrap "reply.cls${2:+.$2}" "$1"; }
exe() { wrap "reply.exe${2:+.$2}" "$1"; }
env_() { env -i HOME="$T/home" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 RETRY_SEC=1 WAIT_MAX_SEC=1 \
  BR_ROUTE="${BR_ROUTE:-1}" RT_BIN="${XRT_BIN:-$RTS}" RT_DIR="$T/rt" RT_STATE="$T/rt/state.json" WM_ASKS_CMD="$T/wma" ASKS_VIEW_BIN="$T/asksview" ASKS_STORE="$T/asks.jsonl" \
  RT_CLAUDE_BIN="${XCLAUDE:-$T/claude}" "$@"; }
br() { env_ BR_CYCLES="${BR_CYCLES:-3}" bash "$BR" "$@"; }
fresh() { rm -rf "$T/br" "$T/rt" "$T"/reply.* "$T"/rc.* "$T"/last-prompt.*; : > "$T/tmux.log"; : > "$T/calls.log"; : > "$T/ev"
  printf '# header\nA7\t2026-10-31T10:35\trb\t2026-11-03T09:30\tx\ty\tz\nA1148\t2026-11-06T23:06\tctl\t2026-11-07T00:06\tx\ty\tz\n# CLOSED\nA5\tdone row\n' > "$T/oa.tsv"; : > "$T/asks.jsonl"; }
calls() { grep -c . "$T/calls.log"; }
rolecalls() { grep -c "^$1 " "$T/calls.log"; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
q() { ls "$T/br/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$T/br/done"/*.json 2>/dev/null | wc -l; }
acks() { grep -c ' ack ' "$T/br/deliveries.log"; }
rows() { grep -c 'event:' "$T/asks.jsonl"; }
jf() { python3 -I -c 'import json,sys; v=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$1" "$2"; }
only() { ls "$1"/*.json | head -1; }
verif() { python3 -I -c 'import json,sys; json.dump({"type":"result","subtype":sys.argv[2],"is_error":sys.argv[2]!="success","stop_reason":"end_turn","session_id":"abc","result":sys.argv[3]},open(sys.argv[1],"w"))' "$@"; }

verif "$T/av/pass.json" success $'Checked the bundle.\nLOG: /x/bundle.log\nCONFIRM 3299862 PASS\nVERDICT: d-20261106-aide-1111'
verif "$T/av/fail.json" success $'Suite ran.\nFAIL tests/foo 2 failing\nVERDICT: d-20261106-aide-2222'
verif "$T/av/err.json" error_during_execution 'boom'
verif "$T/av/none.json" success $'Looked at it. Nothing conclusive.\nVERDICT: d-1'
EV_PASS="{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/pass.json\"]}}"
EV_FAIL="{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/fail.json\"]}}"
EV_ERR="{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/err.json\"]}}"
EV_NONE="{\"event\":\"verifier\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/av/none.json\"]}}"
EV_TOKSTR='{"event":"verifier","ts":"t","detail":{"files":["/nonexistent/result.json"],"note":"PASS 3299862fa"}}'
EV_ALARM='{"event":"alarm","ts":"t","detail":{"new":["ask-overdue #","decision-unverdicted #"]}}'
EV_SIMPLE='{"event":"inbox","ts":"t","detail":{"lines":["t | rb | rb-info nightly lint finished, run the cleanup script"]}}'
EV_JUDG='{"event":"inbox","ts":"t","detail":{"lines":["t | hermes-urgent | should the prod deploy be cancelled?"]}}'
printf 'TASK: write the weekly summary into ~/Notes/x.md (authorized)\n' > "$T/task.md"
EV_TASK="{\"event\":\"taskfile\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/task.md\"]}}"
EXE_OK='did it
OUTCOME: DONE wrote the summary'
CLS_EXEC='{"route":"execute","summary":"routine","reason":"ordinary task"}'
CLS_FABLE='{"route":"fable","summary":"deploy question","reason":"asks for a prod decision"}'

# ---- RED cases
fresh; echo "$EV_PASS" > "$T/ev"; BR_ROUTE=0 br run
[ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ]; chk "RED: pre-change path (routing off) delivers a routine judge completion to the pane" $?
# RED: a summary-only router (cache + mechanical.log, no results/row) must NOT be acked by the bridge
fresh; echo "$EV_SIMPLE" > "$T/ev"
cat > "$T/stub-router" <<'STUB'
#!/bin/sh
id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[2]))["id"])' "$1" "$2")
mkdir -p "$RT_DIR/routed"; echo "{\"id\":\"$id\",\"summary\":\"handled\"}" >> "$RT_DIR/mechanical.log"
echo "{\"id\":\"$id\",\"route\":\"haiku\",\"model\":\"haiku\",\"reason\":\"x\",\"result\":\"handled\",\"row\":\"\"}" > "$RT_DIR/routed/$id.json"
STUB
chmod +x "$T/stub-router"; XRT_BIN="$T/stub-router" br run
[ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(sends)" = 0 ] && grep -q 'ack-refused' "$T/br/deliveries.log"; chk "RED: summary-only mechanical.log handling is refused ack (stays queued, not sent to the pane)" $?

# ---- deterministic: verifier artifacts are opened and parsed
fresh; echo "$EV_PASS" > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(a) real-shape verifier artifact (detail.files) CONFIRM/PASS: 0 model calls, 0 pane deliveries, acked once" $?
r="$(only "$T/rt/routed")"; [ "$(jf "$r" route)" = deterministic ] && [ "$(jf "$r" result)" = record ] && [ "$(jf "$T/rt/results/$(basename "$r")" exit)" = 0 ]; chk "(a) route=deterministic result=record, results/<id>.json exit 0" $?
[ "$(rows)" = 0 ]; chk "(a) a pass outcome opens no row" $?
fresh; echo "$EV_FAIL" > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(d)" = 1 ] && [ "$(rows)" = 1 ]; chk "(a2) verifier FAIL in the artifact: surfaced as an owned open-asks row, 0 calls, acked after the row" $?
row="$(grep 'event:' "$T/asks.jsonl")"; printf '%s' "$row" | grep -q '"owner": "ctl"' && printf '%s' "$row" | grep -q 'waits-on=' && printf '%s' "$row" | grep -qP '"ask_id": "A1149".*"due": "\d{4}-\d\d-\d\dT\d\d:\d\d"'; chk "(a2) row: next A id, owner ctl, date -d due, waits-on= stated" $?
grep -q '"check": "test -e ' "$T/asks.jsonl"; chk "(a2) row carries a done-check on the handled receipt" $?
fresh; echo "$EV_ERR" > "$T/ev"; br run
[ "$(rows)" = 1 ] && [ "$(d)" = 1 ] && [ "$(calls)" = 0 ]; chk "(a3) errored verifier run (is_error): owned row, acked, 0 calls" $?
fresh; echo "$EV_TOKSTR" > "$T/ev"; br run
[ "$(jf "$(only "$T/rt/routed")" result)" = row-created ] && [ "$(rows)" = 1 ]; chk "(a4) a PASS+sha string in the detail with an unreadable artifact is NOT a record (no terminal-token grep)" $?
fresh; echo "$EV_NONE" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls cls)" = 1 ] && [ "$(rolecalls exe)" = 1 ] && [ "$(sends)" = 0 ] && [ "$(d)" = 1 ]; chk "(a5) artifact with no terminal token goes to the haiku path (classify + execute), not Fable" $?
grep -q 'Nothing conclusive' "$T/last-prompt.cls"; chk "(a5) the classifier prompt carries the artifact content" $?

fresh; mkdir -p "$T/rt"; echo '{"alarms":["ask-overdue #","decision-unverdicted #"]}' > "$T/rt/state.json"; echo "$EV_ALARM" > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(d)" = 1 ]; chk "(b) unchanged alarm set: 0 calls, 0 deliveries, acked" $?
[ "$(jf "$(only "$T/rt/routed")" result)" = unchanged ]; chk "(b) result=unchanged" $?
fresh; mkdir -p "$T/rt"; echo '{"alarms":["other #"]}' > "$T/rt/state.json"; echo "$EV_ALARM" > "$T/ev"; br run
[ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ] && [ "$(calls)" = 0 ]; chk "(b2) changed alarm set: explicit judgment, delivered to the pane, 0 model calls" $?

# ---- ordinary inbox: haiku classifies, a separate captured haiku executor does the work, ack only after
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls cls)" = 1 ] && [ "$(rolecalls exe)" = 1 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(c) simple inbox: 1 classifier + 1 executor call, 0 pane deliveries, acked once" $?
! grep -qi fable "$T/calls.log"; chk "(c) no call targets any fable model" $?
grep -q 'claude-haiku-5-5' "$T/calls.log"; chk "(c) calls ran on claude-haiku-5-5" $?
r="$(only "$T/rt/results")"; [ "$(jf "$r" exit)" = 0 ] && [ "$(jf "$r" result)" = executed ] && [ "$(jf "$r" outcome)" = "wrote the summary" ]; chk "(c) results/<id>.json holds exit 0 + the executor outcome" $?
[ "$(jf "$T/rt/model-calls.log" model_calls)" != "" ] && [ "$(python3 -I -c 'import json,sys; v=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print([c["role"] for c in v["model_calls"]], v["model_calls"][0]["response_id"], v["model_calls"][0]["usage"]["output_tokens"])' "$T/rt/model-calls.log")" = "['classify', 'execute'] spy-sess 7" ]; chk "(c) model-calls.log: roles classify+execute, response_id and usage recorded" $?
grep -q 'run the cleanup script' "$T/last-prompt.exe"; chk "(c) executor received the event text" $?
# summary-only executor (no OUTCOME line) is not completion: owned row, results exit 2, acked only because the row exists
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "I think this is fine."; br run
r="$(only "$T/rt/results")"; [ "$(jf "$r" exit)" = 2 ] && [ "$(rows)" = 1 ] && [ "$(d)" = 1 ] && [ "$(sends)" = 0 ]; chk "(c2) executor with no OUTCOME: owned row created, exit 2 recorded, acked after the row" $?
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe 'cannot
OUTCOME: BLOCKED gate denied'; br run
[ "$(rows)" = 1 ] && grep 'event:' "$T/asks.jsonl" | grep -q 'gate denied'; chk "(c2) OUTCOME: BLOCKED opens an owned row naming the reason" $?
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; echo 1 > "$T/rc.exe"; br run
[ "$(rows)" = 1 ] && [ "$(d)" = 1 ] && [ "$(jf "$(only "$T/rt/results")" exit)" = 2 ]; chk "(c3) failure before completion (executor exits 1): obligation preserved as an owned row" $?

# ---- ordinary taskfile: haiku, ONE rule; only an explicit judgment reason reaches Fable
fresh; echo "$EV_TASK" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(sends)" = 0 ] && [ "$(rolecalls exe)" = 1 ] && [ "$(d)" = 1 ]; chk "(d0) ordinary task file: haiku classify + execute, 0 pane deliveries" $?
grep -q 'write the weekly summary' "$T/last-prompt.exe"; chk "(d0) executor prompt carries the task file text" $?
fresh; echo "$EV_TASK" > "$T/ev"; cls "$CLS_FABLE"; br run
[ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ] && [ "$(rolecalls exe)" = 0 ]; chk "(d0b) task file whose classifier gives an explicit judgment reason: delivered, not executed" $?

fresh; echo "$EV_JUDG" > "$T/ev"; cls "$CLS_FABLE"; br run
id="$(ls "$T/br/queue"/*.json | xargs -n1 basename | sed 's/\.json$//')"
[ "$(calls)" = 1 ] && [ "$(sends)" -ge 1 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "(d) judgment inbox: 1 classifier call, delivered, still queued (unacked)" $?
grep -- '-l ctl-event' "$T/tmux.log" | grep -q "$id" && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=classifier:asks for a prod decision'; chk "(d) pane line contains the id and reason=" $?
[ "$(jf "$T/rt/model-calls.log" route)" = fable ] && [ "$(python3 -I -c 'import json,sys; v=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(v["model_calls"][0]["role"], v["model_calls"][0]["model"])' "$T/rt/model-calls.log")" = "classify claude-haiku-5-5" ]; chk "(d) model-calls.log: route=fable with the classifier call recorded" $?
br ack "$id" >/dev/null; [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(d) per-id consumer ack moves it to done/ exactly once" $?
fresh; echo '{"event":"inbox","ts":"t","detail":{"lines":["t | joe-direct | what is the status?"]}}' > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(sends)" -ge 1 ]; chk "(d2) joe line: no model call, delivered" $?
fresh; echo '{"event":"hold","ts":"t","detail":{"hold":"abc"}}' > "$T/ev"; br run
[ "$(calls)" = 0 ] && [ "$(q)" = 1 ] && grep -- '-l ctl-event' "$T/tmux.log" | grep -q 'reason=hold-event-is-judgment'; chk "(d3) hold event: delivered with reason" $?

# ---- classifier failure never auto-wakes Fable
fresh; echo "$EV_SIMPLE" > "$T/ev"; echo 'not json' > "$T/reply.cls.1"; wrap reply.cls.2 "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls cls)" = 2 ] && [ "$(rolecalls exe)" = 1 ] && [ "$(sends)" = 0 ] && [ "$(d)" = 1 ]; chk "(e) one malformed classifier reply: haiku retry succeeds, work executes, 0 pane deliveries" $?
fresh; echo "$EV_SIMPLE" > "$T/ev"; echo 'bad' > "$T/reply.cls.1"; echo 'bad' > "$T/reply.cls.2"; wrap reply.cls.3 "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls cls)" = 3 ] && grep -q '^cls claude-sonnet-5-5' "$T/calls.log" && [ "$(d)" = 1 ] && [ "$(sends)" = 0 ]; chk "(e2) two malformed haiku replies: ONE Sonnet recovery call (claude-sonnet-5-5) resolves it" $?
fresh; echo "$EV_SIMPLE" > "$T/ev"; echo 'bad' > "$T/reply.cls"; br run
r="$(only "$T/rt/routed")"
[ "$(jf "$r" route)" = error ] && [ "$(rolecalls cls)" = 3 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(rows)" = 1 ]; chk "(e3) still malformed after retry + Sonnet: route=error, owned row, queue item pending, NOT sent to Fable" $?
BR_CYCLES=2 br run
[ "$(rolecalls cls)" = 3 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 1 ] && [ "$(rows)" = 1 ]; chk "(e3) later cycles/restart: no more model calls, no pane delivery, no second row, item still pending" $?
fresh; echo "$EV_SIMPLE" > "$T/ev"; echo 3 > "$T/rc.cls"; br run
[ "$(jf "$(only "$T/rt/routed")" route)" = error ] && [ "$(sends)" = 0 ] && [ "$(q)" = 1 ]; chk "(e4) classifier binary failing: route=error, pending, not dropped, not sent to Fable" $?

# ---- restart / replay
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; BR_CYCLES=3 br run
c1="$(calls)"; BR_CYCLES=2 br run
[ "$c1" = 2 ] && [ "$(calls)" = 2 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(f) restart after completion: no new model call, acked exactly once" $?
# crash between route (cache+results written) and ack
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"
BR_CYCLES=1 BR_ROUTE=0 br run
qf="$(only "$T/br/queue")"; env_ bash "$RTS" route "$qf" >/dev/null; c2="$(calls)"
BR_CYCLES=2 br run
[ "$(calls)" = "$c2" ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(f2) crash between route and ack: restart acks from the cache, no new model call, acked once" $?
# crash after the executor ran but before the cache was written: results/stage reused, executor NOT re-run, no duplicate row
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "I think this is fine."
BR_CYCLES=1 BR_ROUTE=0 br run
qf="$(only "$T/br/queue")"; env_ bash "$RTS" route "$qf" >/dev/null; rm -f "$T/rt/routed"/*.json; c3="$(calls)"
BR_CYCLES=2 br run
[ "$(calls)" = "$c3" ] && [ "$(rows)" = 1 ] && [ "$(d)" = 1 ] && [ "$(acks)" = 1 ]; chk "(f3) restart between completion and cache: no re-execution, no duplicate row, acked once" $?
# delayed second event after the first turn ended
fresh; echo "$EV_SIMPLE" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; BR_CYCLES=3 br run
echo "$EV_PASS" > "$T/ev"; BR_CYCLES=3 br run
[ "$(d)" = 2 ] && [ "$(acks)" = 2 ] && [ "$(q)" = 0 ] && [ "$(sends)" = 0 ]; chk "(g) delayed second event after the first was handled: both acked once each, 0 pane deliveries" $?
# fail-safe: a missing router leaves everything queued and delivered, nothing acked unseen
fresh; echo "$EV_PASS" > "$T/ev"; XRT_BIN="$T/nonexistent" br run
[ "$(q)" = 1 ] && [ "$(sends)" -ge 1 ]; chk "missing router: nothing acked, event still delivered (fail-safe)" $?

# ---- W20: a Dispatch: ctl task file has one route (ctl-dispatch-claim.sh); the bridge executes nothing and makes no model call
printf 'Dispatch: ctl\nTASK: write the weekly summary\n' > "$T/dtask.md"
EV_DTASK="{\"event\":\"taskfile\",\"ts\":\"t\",\"detail\":{\"files\":[\"$T/dtask.md\"]}}"
fresh; echo "$EV_DTASK" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls exe)" = 0 ] && [ "$(calls)" = 0 ] && [ "$(sends)" = 0 ] && [ "$(q)" = 0 ]; chk "(w20) Dispatch: ctl task file: no executor, no classifier call, no pane delivery, acked" $?
fresh; echo "$EV_TASK" > "$T/ev"; cls "$CLS_EXEC"; exe "$EXE_OK"; br run
[ "$(rolecalls exe)" = 1 ]; chk "(w20) a task file without the marker still takes the haiku route" $?

echo "ctl-event-route test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"
exit $f
