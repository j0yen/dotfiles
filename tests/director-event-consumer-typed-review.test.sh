#!/usr/bin/env bash
# director-event-consumer-typed-review.test.sh (Wintermute Increment 1, A1296): the typed `review.changed-head` class in the EXISTING consumer.
# The canonical store is REAL: swarm-decide's wm-decide CLI (SWARM_DECIDE_SRC, default a sibling checkout) on a private WM_DECIDE_STATE. The action is
# produced by the real `build-result-ingest` adapter from a wm-build-shaped builder state (HARNESS: runs/steps schema copied from a real state.db).
# Stubs (HARNESS, never acceptance evidence): the reviewer launcher and probe, the hold gate, the legacy launcher (must never run for this class).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="${DIRECTOR_CONSUMER_UNDER_TEST:-$HERE/.local/bin/director-event-consumer.py}"
SD="${SWARM_DECIDE_SRC:-$(cd "$HERE/.." && pwd)/swarm-decide}"
[ -x "$SD/bin/wm-decide" ] || { echo "FAIL setup: SWARM_DECIDE_SRC=$SD has no bin/wm-decide (point it at a swarm-decide checkout with wm_decide/work_binding.py)"; exit 1; }
[ -f "$SD/wm_decide/work_binding.py" ] || { echo "FAIL setup: $SD lacks wm_decide/work_binding.py"; exit 1; }
mkdir -p "$HOME/.cache/director-scratch"; T="$(mktemp -d "$HOME/.cache/director-scratch/t.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fails=0; passes=0
ok(){ echo "PASS $1"; passes=$((passes+1)); }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
HOST="$(python3 -c 'import socket; print(socket.gethostname())')"
CLS=review.changed-head
HEAD1=$(printf 'e%.0s' $(seq 40)); HEAD2=$(printf 'f%.0s' $(seq 40))

# reviewer launcher stub: <unit> <root> <session> <prompt>; records the launch, creates the root with process.json (as the real wrapper does first)
cat > "$T/rlaunch" <<'SH'
#!/usr/bin/env bash
echo "$1 $3" >> "$STUB/rlaunch.log"; mkdir -p "$2"; cp "$4" "$STUB/last-review-prompt.md"; cp "$4" "$STUB/prompt-$1.md"
[ -e "$STUB/rlaunch-fail" ] && exit 1
echo '{"pid": 4242}' > "$2/process.json"; echo "$1" > "$STUB/live-$1"
if [ -e "$STUB/auto-verdict" ]; then
  head=$(cat "$STUB/auto-verdict"); printf '{"verdict":"FIX","reviewed_head":"%s","reviewer_session":"%s","findings":[{"id":"F1","severity":"major","text":"needs a discriminating test"}]}\n' "$head" "$3" > "$2/verdict.json"
fi
exit 0
SH
# reviewer probe stub: <unit> <root> -> JSON {unit: live|dead|absent|unknown, process, status, verdict_b64}
cat > "$T/rprobe" <<'PY'
#!/usr/bin/env python3
import base64, json, os, sys
S = os.environ["STUB"]; unit, root = sys.argv[1], sys.argv[2]
open(S + "/rprobe.log", "a").write(unit + "\n")
if os.path.exists(S + "/probe-unknown"): sys.exit(3)
st = "live" if os.path.exists(S + "/live-" + unit) else ("dead" if os.path.isdir(root) else "absent")
v = os.path.join(root, "verdict.json")
print(json.dumps({"unit": st, "process": os.path.exists(os.path.join(root, "process.json")), "status": None,
                  "verdict_b64": base64.b64encode(open(v, "rb").read()).decode() if os.path.exists(v) else None}))
PY
cat > "$T/legacy-launcher" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$STUB/legacy-launch.log"; exit 0
SH
cat > "$T/hold" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$STUB/hold.log"; [ -e "$STUB/hold" ] && exit 1; exit 0
SH
cat > "$T/active" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$T/wmd" <<SH
#!/usr/bin/env bash
exec python3 "$SD/bin/wm-decide" "\$@"
SH
chmod 755 "$T"/rlaunch "$T"/rprobe "$T"/legacy-launcher "$T"/hold "$T"/active "$T"/wmd

# builder world (HARNESS): wm-build state dir + PRD home; gate <head> <step_id> writes a new ended gate step + gate.result.json + prov heads
builder(){ python3 - "$@" <<'PY'
import json, os, sqlite3, sys
B = os.environ["BUILDER"]; cmd = sys.argv[1]; HOST = os.environ["HOST"]; rid = 577
sd = os.path.join(B, "wmb-state"); rdir = os.path.join(sd, "runs", str(rid))
if cmd == "init":
    os.makedirs(os.path.join(rdir, "gate-receipts"), exist_ok=True); os.makedirs(os.path.join(B, "PRDs", "build-queue"), exist_ok=True)
    open(os.path.join(B, "PRDs", "build-queue", "PRD-synthorg-x.md"), "w").write("# PRD — synthorg-x\n\n- Status: queued\n")
    db = sqlite3.connect(os.path.join(sd, "state.db")); db.executescript(open(os.environ["SCHEMA"]).read())
    db.execute("INSERT INTO runs (id, slug, stage, branch, worktree, base_sha, driver_host, attempt) VALUES (?,?,?,?,?,?,?,1)",
               (rid, "synthorg-x", "land", "wm-build/synthorg-x", os.path.join(sd, "wt", "synthorg-x"), "0" * 40, HOST)); db.commit()
    open(os.path.join(rdir, "coder.stream.log"), "w").write('{"session_id":"coder-sess-1"}\n')
elif cmd == "gate":
    head, sid = sys.argv[2], int(sys.argv[3])
    db = sqlite3.connect(os.path.join(sd, "state.db"))
    db.execute("INSERT INTO steps (id, run_id, kind, started, ended, outcome) VALUES (?,?,'gate','2026-11-22T20:10:01+00:00','2026-11-22T20:12:00+00:00','done')", (sid, rid)); db.commit()
    json.dump({"kind": "gate", "slug": "synthorg-x", "run_id": str(rid), "outcome": "done", "started": "2026-11-22T20:10:02+00:00", "ended": "2026-11-22T20:12:00+00:00",
               "detail": {"base": "0" * 40, "outcome": "pass", "sha": head}}, open(os.path.join(rdir, "gate.result.json"), "w"))
    for i in range(2):
        json.dump({"head": head, "producer": "p%d" % i}, open(os.path.join(rdir, "gate-receipts", "p%d.prov.json" % i), "w"))
PY
}
blob(){ git hash-object "$BUILDER/PRDs/build-queue/PRD-synthorg-x.md"; }
digest(){ wmd intake prd-digest --file "$BUILDER/PRDs/build-queue/PRD-synthorg-x.md" | jget 'd["prd_req_digest"]'; }
wmd(){ "$T/wmd" "$@"; }
jget(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
sq(){ sqlite3 "$WM_DECIDE_STATE/decisions.sqlite" "$1"; }

fresh(){ # one private world: canonical store, builder, consumer state, stubs
  export STUB="$T/s$1" WM_DECIDE_STATE="$T/decide$1" DIRECTOR_STATE="$T/st$1" DIRECTOR_EVENTS_LOG="$T/ev$1.log" BUILDER="$T/b$1" HOST SCHEMA="$SD/tests/fixtures/wmbuild-state-schema.sql"
  rm -rf "$STUB" "$WM_DECIDE_STATE" "$DIRECTOR_STATE" "$BUILDER"; mkdir -p "$STUB" "$WM_DECIDE_STATE" "$BUILDER"; : > "$DIRECTOR_EVENTS_LOG"
  export WM_ASKS_CMD="$T/wmd" HOLD_GATE="$T/hold" DIRECTOR_ACTIVE_CMD="$T/active" DIRECTOR_LAUNCH_CMD="$T/legacy-launcher" DIRECTOR_HERMES_CMD=/bin/false
  export DIRECTOR_REVIEW_LAUNCH_CMD="$T/rlaunch" DIRECTOR_REVIEW_PROBE_CMD="$T/rprobe" DIRECTOR_REVIEW_ROOT="$T/reviews$1" WM_INGEST_WMBUILD_BIN="$T/active"
  unset DIRECTOR_CRASH_AT DIRECTOR_CONSUMER
  builder init; builder gate "$HEAD1" 901
  OB=$(wmd asks add --owner hermes --due 2026-11-23T09:00 --what "build PRD-synthorg-x" --check "test -n x" --by hermes | grep -o 'A[0-9]*' | head -1)
  OBREV=$(sq "SELECT rev FROM asks WHERE ask_id='$OB'")
  ENVL="{\"authorized_by\":\"hermes\",\"obligation_id\":\"$OB\",\"requirement_rev\":$OBREV,\"authority_ref\":\"ledger:A1296\",\"origin\":\"adopted:ledger:A1296\",\"target\":\"synthorg\",\"prd_repo\":\"j0yen/PRDs\",\"prd_path\":\"build-queue/PRD-synthorg-x.md\",\"prd_home\":\"$BUILDER/PRDs\",\"prd_blob\":\"$(blob)\",\"prd_req_digest\":\"$(digest)\",\"builder_host\":\"$HOST\",\"builder_state_dir\":\"$BUILDER/wmb-state\",\"run_id\":577,\"author_lineage\":[\"wm-build:$HOST:run/577\"]}"
  BID=$(wmd intake bind --envelope "$ENVL" | jget 'd["binding_id"]')
}
cutover(){ wmd intake class-owner --class $CLS --set director-event-consumer --by hermes --expect-epoch "${1:-0}" --evidence "test cutover" >/dev/null; }
ingest(){ wmd intake ingest --binding "$BID" 2>/dev/null; }
run(){ python3 "$C" "${1:-consume}" >"$T/out.txt" 2>&1; }
cnt(){ local n; n="$(grep -c -- "${2:-.}" "$STUB/$1" 2>/dev/null)"; echo "${n:-0}"; }
state_of(){ sq "SELECT state FROM asks WHERE ask_id='$1'"; }
act(){ sq "SELECT ask_id FROM action_meta ORDER BY rowid DESC LIMIT 1"; }
rec(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$DIRECTOR_STATE/typed/typed-$1.json" "$2" 2>/dev/null; }
blk(){ python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("blocked") or {}).get("why"))' "$DIRECTOR_STATE/typed/typed-$1.json" 2>/dev/null; }
gate_open(){ python3 - "$@" <<'PY'
import os, sqlite3, sys
B = os.environ["BUILDER"]; db = sqlite3.connect(os.path.join(B, "wmb-state", "state.db"))
db.execute("INSERT INTO steps (id, run_id, kind, started, ended, outcome) VALUES (?,577,'gate','2026-11-22T21:00:00+00:00',NULL,NULL)", (int(sys.argv[1]),)); db.commit()
PY
}
gate_close(){ python3 - "$@" <<'PY'
import json, os, sqlite3, sys
B = os.environ["BUILDER"]; sid, head = int(sys.argv[1]), sys.argv[2]; rdir = os.path.join(B, "wmb-state", "runs", "577")
db = sqlite3.connect(os.path.join(B, "wmb-state", "state.db"))
db.execute("UPDATE steps SET ended='2026-11-22T21:05:00+00:00', outcome='done' WHERE id=?", (sid,)); db.commit()
json.dump({"kind": "gate", "slug": "synthorg-x", "run_id": "577", "outcome": "done", "started": "2026-11-22T21:00:01+00:00", "ended": "2026-11-22T21:05:00+00:00",
           "detail": {"base": "0" * 40, "outcome": "pass", "sha": head}}, open(os.path.join(rdir, "gate.result.json"), "w"))
PY
}
gate_infra(){ python3 - "$@" <<'PY'
import os, sqlite3, sys
B = os.environ["BUILDER"]; db = sqlite3.connect(os.path.join(B, "wmb-state", "state.db"))
db.execute("INSERT INTO steps (id, run_id, kind, started, ended, outcome) VALUES (?,577,'gate','2026-11-22T21:00:00+00:00','2026-11-22T21:01:00+00:00','infra')", (int(sys.argv[1]),)); db.commit()
PY
}
set_run(){ python3 - "$@" <<'PY'
import os, sqlite3, sys
B = os.environ["BUILDER"]; db = sqlite3.connect(os.path.join(B, "wmb-state", "state.db"))
db.execute("UPDATE runs SET %s = ? WHERE id = 577" % sys.argv[1], (None if sys.argv[2] == "NULL" else sys.argv[2],)); db.commit()
PY
}

echo "== T1 happy path: real producer -> one claim, one launch, review result -> verifying, receipt; later ticks add nothing"
fresh 1; cutover; ingest >/dev/null; A=$(act)
chk "T1 action is ready before the tick" '[ "$(state_of $A)" = ready ]'
run
chk "T1 exactly one reviewer launch" '[ "$(cnt rlaunch.log)" = 1 ]'
chk "T1 action running under the typed claim" '[ "$(state_of $A)" = running ] && [ "$(sq "SELECT claim FROM asks WHERE ask_id='"'"'$A'"'"'" | cut -d@ -f1)" = "director-typed-$A" ]'
chk "T1 launch effect done with the reviewer session" '[ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = done ] && sq "SELECT readback FROM effects WHERE ask_id='"'"'$A'"'"'" | grep -q "$(rec $A session)"'
chk "T1 legacy launcher never ran" '[ "$(cnt legacy-launch.log)" = 0 ]'
chk "T1 prompt names the exact head and binding" 'grep -q "$HEAD1" "$STUB/last-review-prompt.md" && grep -q "$BID" "$STUB/last-review-prompt.md"'
S1=$(rec $A session); U1=$(rec $A unit); R1=$(rec $A root)
printf '{"verdict":"FIX","reviewed_head":"%s","reviewer_session":"%s","findings":[{"id":"F1","severity":"major","text":"x"}]}\n' "$HEAD1" "$S1" > "$R1/verdict.json"; rm -f "$STUB/live-$U1"
run
chk "T1 review result recorded: verifying" '[ "$(state_of $A)" = verifying ]'
chk "T1 one review-result event naming the reviewer session" '[ "$(sq "SELECT COUNT(*) FROM ask_events WHERE ask_id='"'"'$A'"'"' AND op='"'"'review-result'"'"' AND detail LIKE '"'"'%$S1%'"'"'")" = 1 ]'
chk "T1 run record completed with a receipt" '[ "$(rec $A state)" = completed ] && [ -s "$DIRECTOR_STATE/typed/typed-$A.receipt.json" ]'
run; run
chk "T1 later ticks: still one launch, one result" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM ask_events WHERE ask_id='"'"'$A'"'"' AND op='"'"'review-result'"'"'")" = 1 ]'
chk "T1 the typed wake was ACKed only after the claim" '[ "$(sq "SELECT COUNT(*) FROM outbox_acks WHERE consumer='"'"'hermes'"'"'")" = 1 ]'
chk "T1 never accepted" '[ "$(state_of $A)" != accepted ]'

echo "== T2 replayed producer, duplicate wakes and repeated ticks create no second action or launch"
fresh 2; cutover; ingest >/dev/null; ingest >/dev/null; A=$(act); run; ingest >/dev/null; run; run
chk "T2 one action" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ]'
chk "T2 one launch" '[ "$(cnt rlaunch.log)" = 1 ]'

echo "== T3 class not cut over: the consumer executes nothing; after the epoch it executes once"
fresh 3; ingest >/dev/null; A=$(act); run
chk "T3 no launch before cutover" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(state_of $A)" = ready ]'
chk "T3 not cut over: the consumer does not even open a typed run record" '[ ! -e "$DIRECTOR_STATE/typed/typed-$A.json" ]'
cutover; run
chk "T3 one launch after cutover" '[ "$(cnt rlaunch.log)" = 1 ]'

echo "== T4 held: no claim, no launch; released hold -> one launch"
fresh 4; cutover; ingest >/dev/null; A=$(act); touch "$STUB/hold"; run
chk "T4 held: action still ready, no launch" '[ "$(state_of $A)" = ready ] && [ "$(cnt rlaunch.log)" = 0 ] && [ "$(rec $A state)" = held ]'
chk "T4 held: the task_ready bell is not ACKed before a claim" '[ "$(sq "SELECT COUNT(*) FROM outbox_acks WHERE consumer='"'"'hermes'"'"'")" = 0 ]'
rm -f "$STUB/hold"; run
chk "T4 after release: one launch" '[ "$(cnt rlaunch.log)" = 1 ]'

echo "== T5 UNKNOWN effect: crash after the launch intent, probe cannot answer -> reconcile-required, nothing launched; reconcile absent -> one launch"
fresh 5; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-begin run
chk "T5 crash left the intent, no launch" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = intended ]'
touch "$STUB/probe-unknown"; run
chk "T5 UNKNOWN recorded, run held for reconciliation, no launch" '[ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = unknown ] && [ "$(rec $A state)" = reconcile-required ] && [ "$(cnt rlaunch.log)" = 0 ]'
run
chk "T5 while the probe still cannot answer: nothing settles, nothing launches" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(rec $A state)" = reconcile-required ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = unknown ]'
rm -f "$STUB/probe-unknown"; run
chk "T5 a later answering probe (absent) settles the UNKNOWN effect failed and relaunches exactly once" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"' ORDER BY created LIMIT 1")" = failed ] && [ "$(rec $A state)" = launched ]'

echo "== T5b UNKNOWN that the probe never answers: only the owner readback (reconcile-typed) releases it"
fresh 5b; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-begin run; touch "$STUB/probe-unknown"; run; run
chk "T5b held for reconciliation, no launch" '[ "$(rec $A state)" = reconcile-required ] && [ "$(cnt rlaunch.log)" = 0 ]'
python3 "$C" reconcile-typed "typed-$A" --verdict absent --by test-owner >/dev/null 2>&1; rm -f "$STUB/probe-unknown"; run
chk "T5b after reconcile absent: exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ]'

echo "== T6 consumer death after the launcher returned: recovery reads back, no second launch"
fresh 6; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-launch run
chk "T6 one launch, effect still intended" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = intended ]'
run
chk "T6 recovery: effect done by readback, still one launch" '[ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = done ] && [ "$(cnt rlaunch.log)" = 1 ] && [ "$(rec $A state)" = launched ]'

echo "== T7 reviewer ended without a result: same action relaunched with a new session; the old session cannot record"
fresh 7; cutover; ingest >/dev/null; A=$(act); run
S1=$(rec $A session); U1=$(rec $A unit); rm -f "$STUB/live-$U1"; run
chk "T7 second launch, same action, new session" '[ "$(cnt rlaunch.log)" = 2 ] && [ "$(rec $A session)" != "$S1" ] && [ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ]'
S2=$(rec $A session); R2=$(rec $A root); U2=$(rec $A unit)
printf '{"verdict":"APPROVE","reviewed_head":"%s","reviewer_session":"%s","findings":[]}\n' "$HEAD1" "$S1" > "$R2/verdict.json"; rm -f "$STUB/live-$U2"; run
chk "T7 a verdict carrying the stale session is not recorded" '[ "$(state_of $A)" = running ]'
printf '{"verdict":"APPROVE","reviewed_head":"%s","reviewer_session":"%s","findings":[]}\n' "$HEAD1" "$(rec $A session)" > "$(rec $A root)/verdict.json"; rm -f "$STUB/live-$(rec $A unit)"; run
chk "T7 the current session's verdict is recorded" '[ "$(state_of $A)" = verifying ]'

echo "== T8 superseded: a newer gated head cancels the older ready action; only the newer one launches"
fresh 8; cutover; ingest >/dev/null; OLD=$(act); builder gate "$HEAD2" 902; ingest >/dev/null; NEW=$(act); run
chk "T8 older cancelled, newer running, one launch" '[ "$(state_of $OLD)" = cancelled ] && [ "$(state_of $NEW)" = running ] && [ "$(cnt rlaunch.log)" = 1 ]'

echo "== T9 stale terminal at execution: the builder gated a newer head not yet ingested -> refused, no launch"
fresh 9; cutover; ingest >/dev/null; A=$(act); builder gate "$HEAD2" 903; run
chk "T9 stale-terminal: no claim, no launch, the run waits (not terminal)" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(state_of $A)" = ready ] && [ "$(rec $A code)" = stale-terminal ] && [ "$(rec $A state)" = builder-wait ]'
ingest >/dev/null; B=$(act); run; run
chk "T9 once the newer head is ingested: the older run ends superseded, the newer action launches once" '[ "$(rec $A state)" = superseded ] && [ "$B" != "$A" ] && [ "$(cnt rlaunch.log)" = 1 ] && grep -q "$HEAD2" "$STUB/last-review-prompt.md"'

echo "== T10 fence mid-flight: epoch moved to none -> the result is not recorded, no relaunch"
fresh 10; cutover; ingest >/dev/null; A=$(act); run
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback fence" >/dev/null
printf '{"verdict":"FIX","reviewed_head":"%s","reviewer_session":"%s","findings":[]}\n' "$HEAD1" "$(rec $A session)" > "$(rec $A root)/verdict.json"; rm -f "$STUB/live-$(rec $A unit)"; run
chk "T10 fenced: still running, one launch, no review result" '[ "$(state_of $A)" = running ] && [ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM ask_events WHERE op='"'"'review-result'"'"'")" = 0 ]'

echo "== T11 known-bad controls: a passive inbox file, a bare outbox bell and a hand-authored typed task execute nothing"
fresh 11; cutover; mkdir -p "$DIRECTOR_STATE/inbox"; echo "please review head $HEAD1 for $BID" > "$DIRECTOR_STATE/inbox/001-review.md"
HAND=$(wmd intake submit --envelope '{"authorized_by":"hermes","text":"review it","request_type":"new","source_event_id":"hand-1"}' --change '{"owner":"hermes","due":"2026-11-23T09:00","what":"review head","check":"test -n x"}' | jget 'd["ask_id"]')
run; run
chk "T11 no launch, no claim of the hand task" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(cnt legacy-launch.log)" = 0 ] && [ "$(state_of $HAND)" = ready ]'

echo "== T12 legacy path refuses a typed action named by a DIRECTOR-ACTION log line (one channel per class)"
fresh 12; ingest >/dev/null; A=$(act)
echo "2026-11-22T21:00:00-08:00 | hermes | DIRECTOR-ACTION ask=$A event=evt-typed-1 please run" >> "$DIRECTOR_EVENTS_LOG"; run
chk "T12 no legacy launch, no claim, action still ready" '[ "$(cnt legacy-launch.log)" = 0 ] && [ "$(state_of $A)" = ready ] && [ -z "$(sq "SELECT claim FROM asks WHERE ask_id='"'"'$A'"'"'")" ]'
chk "T12 the legacy path itself recognised the typed row (decision typed-action-not-legacy), not only the store trigger" 'grep -q "\"decision\": \"typed-action-not-legacy\"" "$DIRECTOR_STATE/decisions.jsonl"'

echo "== T13 two consumer identities ticking at once: exactly one launch"
fresh 13; cutover; ingest >/dev/null; A=$(act)
( DIRECTOR_CONSUMER=c0 python3 "$C" consume >"$T/o0" 2>&1 & DIRECTOR_CONSUMER=c1 python3 "$C" consume >"$T/o1" 2>&1 & wait )
DIRECTOR_CONSUMER=c1 run; DIRECTOR_CONSUMER=c0 run
chk "T13 one launch across two consumers" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ]'

echo "== T14 wrong origin: a binding whose host is not the builder produces no action and nothing runs"
fresh 14; cutover
OB2=$(wmd asks add --owner hermes --due 2026-11-23T09:00 --what "other" --check "test -n x" --by hermes | grep -o 'A[0-9]*' | head -1)
B2=$(wmd intake bind --envelope "{\"authorized_by\":\"hermes\",\"obligation_id\":\"$OB2\",\"requirement_rev\":$(sq "SELECT rev FROM asks WHERE ask_id='$OB2'"),\"authority_ref\":\"ledger:A1296\",\"origin\":\"adopted:ledger:A1296\",\"target\":\"synthorg\",\"prd_repo\":\"j0yen/PRDs\",\"prd_path\":\"build-queue/PRD-synthorg-x.md\",\"prd_home\":\"$BUILDER/PRDs\",\"prd_blob\":\"$(blob)\",\"prd_req_digest\":\"$(digest)\",\"builder_host\":\"$HOST-other\",\"builder_state_dir\":\"$BUILDER/wmb-state\",\"run_id\":578,\"author_lineage\":[\"x\"]}" | jget 'd["binding_id"]')
WM_INGEST_SSH="$SD/tests/fake_builder_ssh.py" wmd intake ingest --binding "$B2" >"$T/wo.json" 2>/dev/null; rc=$?
chk "T14 refused wrong-origin (exit 66), no action" '[ "$rc" = 66 ] && grep -q wrong-origin "$T/wo.json" && [ "$(sq "SELECT COUNT(*) FROM action_meta")" = 0 ]'

echo "== T15 a newer head arrives while the older review runs: the older one finishes against its own head (labelled); the newer one launches once"
fresh 15; cutover; ingest >/dev/null; OLD=$(act); run
chk "T15 older launched" '[ "$(state_of $OLD)" = running ] && [ "$(cnt rlaunch.log)" = 1 ]'
builder gate "$HEAD2" 904; ingest >/dev/null; NEW=$(act); run
chk "T15 older still running (never cancelled under its consumer), newer launched" '[ "$(state_of $OLD)" = running ] && [ "$(state_of $NEW)" = running ] && [ "$(cnt rlaunch.log)" = 2 ]'
printf '{"verdict":"FIX","reviewed_head":"%s","reviewer_session":"%s","findings":[]}\n' "$HEAD1" "$(rec $OLD session)" > "$(rec $OLD root)/verdict.json"; rm -f "$STUB/live-$(rec $OLD unit)"; run
chk "T15 older review result recorded for its own head" '[ "$(state_of $OLD)" = verifying ] && [ "$(sq "SELECT COUNT(*) FROM ask_events WHERE ask_id='"'"'$OLD'"'"' AND op='"'"'review-result'"'"' AND detail LIKE '"'"'%$HEAD1%'"'"'")" = 1 ]'
chk "T15 no relaunch of either" '[ "$(cnt rlaunch.log)" = 2 ]'

echo "== T16 consumer died after claiming the older action, then a newer head arrived: recovery finishes the older one (labelled), never orphans it"
fresh 16; cutover; ingest >/dev/null; OLD=$(act)
DIRECTOR_CRASH_AT=typed-after-claim run
chk "T16 crash left the older action claimed, no launch" '[ "$(state_of $OLD)" = claimed ] && [ "$(cnt rlaunch.log)" = 0 ]'
builder gate "$HEAD2" 905; ingest >/dev/null; NEW=$(act); run
chk "T16 older recovered and launched against its own head" '[ "$(state_of $OLD)" = running ] && [ "$(rec $OLD state)" = launched ] && grep -q "$HEAD1" "$STUB/prompt-$(rec $OLD unit).md" && ! grep -q "$HEAD2" "$STUB/prompt-$(rec $OLD unit).md"'
chk "T16 older run record labelled superseded_by the newer action" '[ "$(rec $OLD superseded_by)" = "$NEW" ]'
chk "T16 newer launched too, two launches total" '[ "$(state_of $NEW)" = running ] && [ "$(cnt rlaunch.log)" = 2 ]'
U=$(rec $OLD unit); rm -f "$STUB/live-$U"; run
chk "T16 older reviewer ended without a result: the older action relaunches (same action, own head)" '[ "$(cnt rlaunch.log)" = 3 ] && [ "$(rec $OLD attempt)" = 2 ] && [ "$(state_of $OLD)" = running ]'

# consumes 2026-11-22-wintermute-increment1-review-action-wwhtbt.md#mechanism:13 (with T22: the route is always remote; the route file values are the installer's)
echo "== T17 real route transport: no launch stub; the route file names a remote host -> the argv goes to that host over ssh, no local model process"
fresh 17; cutover; ingest >/dev/null; A=$(act)
cat > "$T/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/ssh-argv.log"; cat > "$STUB/ssh-stdin-$(date +%s%N).txt"; exit 0
SH
chmod 755 "$T/fake-ssh"
printf '{"host":"reviewhost.invalid","root":"%s","launcher":["/home/jsy/.local/bin/fable-launch.sh","--helper"],"model":"claude-opus-5-5","effort":"high","ssh":["%s"]}\n' "$T/rroot17" "$T/fake-ssh" > "$T/route17.json"
env -u DIRECTOR_REVIEW_LAUNCH_CMD DIRECTOR_REVIEW_ROUTE="$T/route17.json" DIRECTOR_REVIEW_ROOT= python3 "$C" consume >"$T/out.txt" 2>&1
chk "T17 one ssh launch to the route host" '[ "$(grep -c "^reviewhost.invalid bash -s$" "$STUB/ssh-argv.log")" = 1 ]'
chk "T17 the launch script starts a transient user unit running the route launcher with the route model/effort and the recorded session" 'f=$(ls "$STUB"/ssh-stdin-*.txt | head -1); grep -q "systemd-run --user --unit wm-review-" "$f" && grep -q "printf %s .* | base64 -d > run.sh" "$f" && s=$(grep -o "printf %s [A-Za-z0-9+/=]* | base64 -d > run.sh" "$f" | cut -d" " -f3 | base64 -d) && echo "$s" | grep -q -- "fable-launch.sh --helper --model claude-opus-5-5 --effort high --session-id $(rec $A session)"'
chk "T17 no local reviewer process, no legacy launch, effect done" '[ "$(pgrep -c -f -- "--session-id $(rec $A session)" || true)" = 0 ] && [ "$(cnt legacy-launch.log)" = 0 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = done ] && [ "$(rec $A state)" = launched ]'
chk "T17 the reviewer envelope (prompt) carries head, base and PRD blob" 'f=$(ls "$STUB"/ssh-stdin-*.txt | head -1); p=$(grep -o "printf %s [A-Za-z0-9+/=]* | base64 -d > prompt.md" "$f" | cut -d" " -f3 | base64 -d); echo "$p" | grep -q "reviewed_head: $HEAD1" && echo "$p" | grep -q "base: 0000000000" && echo "$p" | grep -q "blob $(blob)"'

# consumes 2026-11-22-wintermute-increment1-review-action-wwhtbt.md#mechanism:9 (with T27 and T29: the recover tick is the producer trigger; a failed scan is one typed-scan incident per fault)
echo "== T18 the supervised recover tick runs the producer scan: a real-shaped gate terminal becomes one action and one launch with no other caller"
fresh 18; cutover
run consume
chk "T18 the event tick alone ingests nothing" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 0 ] && [ "$(cnt rlaunch.log)" = 0 ]'
run recover; A=$(act)
chk "T18 recover tick: one action by build-result-ingest, one launch" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ] && [ "$(sq "SELECT producer_actor FROM action_meta")" = build-result-ingest ] && [ "$(cnt rlaunch.log)" = 1 ]'
run recover; run recover
chk "T18 repeated recover ticks: still one action, one launch" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ] && [ "$(cnt rlaunch.log)" = 1 ]'
chk "T18 a stale-revision claim is refused by the store" '! wmd intake claim --ask "$A" --worker director-typed-x --by director-event-consumer --expect-rev 1 >/dev/null 2>&1 && [ "$(sq "SELECT claim FROM asks WHERE ask_id='"'"'$A'"'"'" | cut -d@ -f1)" = "director-typed-$A" ]'

echo "== T19 isolation: a review launcher outside the scratch root is refused for the typed class only (blocked, nothing launched, no effect)"
fresh 19; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_REVIEW_LAUNCH_CMD=/bin/true run
chk "T19 no launch, no effect, typed record blocked isolation-refused" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = isolation-refused ]'
run
chk "T19 with the scratch launcher back: one launch" '[ "$(cnt rlaunch.log)" = 1 ]'

echo "== T20 a refused legacy launch does not stop the typed class (the recover tick still scans and executes; exit stays EX_CONFIG)"
fresh 20; cutover
L=$(wmd asks add --owner hermes --due 2026-11-23T09:00 --what "legacy director work" --check "test -n x" --by hermes | grep -o 'A[0-9]*' | head -1)
echo "2026-11-22T21:00:00-08:00 | hermes | DIRECTOR-ACTION ask=$L event=evt-legacy-20 please run" >> "$DIRECTOR_EVENTS_LOG"
DIRECTOR_LAUNCH_CMD=/bin/true python3 "$C" consume >"$T/out.txt" 2>&1; rc1=$?
DIRECTOR_LAUNCH_CMD=/bin/true python3 "$C" recover >"$T/out2.txt" 2>&1; rc2=$?
chk "T20 the legacy launch was refused (EX_CONFIG 78), nothing legacy launched" '[ "$rc1" = 78 ] && [ "$(cnt legacy-launch.log)" = 0 ]'
chk "T20 the recover tick still scanned and launched the typed review once" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ] && [ "$(cnt rlaunch.log)" = 1 ]'

# consumes 2026-11-22-wintermute-increment1-review-action-wwhtbt.md#mechanism:4 (no drift: every refusal code the consumer branches on is in REFUSAL_CODES)
echo "== T21 no drift: every refusal code the consumer branches on is in the store's one REFUSAL_CODES set"
cat > "$T/nodrift.py" <<'PY'
import ast, sys
src = open(sys.argv[1]).read(); sys.path.insert(0, sys.argv[2])
from wm_decide import work_binding as wb
names = {"SUPERSEDED_CODES", "FENCE_CODES", "RETRY_RESULT_CODES", "BUILDER_WAIT_CODES"}
got = {}
for node in ast.parse(src).body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", None) in names:
        got[node.targets[0].id] = ast.literal_eval(node.value)
used = set(c for v in got.values() for c in v) | {"unknown-effect", "held", "needs-readback", "target-busy"}
missing = sorted(used - set(wb.REFUSAL_CODES))
print("missing:", missing, "groups:", sorted(got))
sys.exit(1 if set(got) != names or missing else 0)
PY
chk "T21 consumer code groups are a subset of work_binding.REFUSAL_CODES" 'python3 "$T/nodrift.py" "$C" "$SD" >/dev/null'

echo "== T22 a route naming the consumer's own host is refused (no local model process): blocked, nothing launched, no effect"
fresh 22; cutover; ingest >/dev/null; A=$(act)
printf '{"host":"%s","root":"%s","launcher":["/home/jsy/.local/bin/fable-launch.sh","--helper"],"model":"claude-opus-5-5","effort":"high"}\n' "$HOST" "$T/rroot22" > "$T/route22.json"
env -u DIRECTOR_REVIEW_LAUNCH_CMD DIRECTOR_REVIEW_ROUTE="$T/route22.json" DIRECTOR_REVIEW_ROOT= python3 "$C" consume >"$T/out.txt" 2>&1
chk "T22 route-local-refused (hostname), no effect, no reviewer root" '[ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && [ ! -e "$T/rroot22" ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = route-local-refused ]'
FQDN="$(python3 -c 'import socket; print(socket.getfqdn())')"
i=0
for h in localhost 127.0.0.1 "$FQDN" ::1 "[::1]" LOCALHOST. 127.0.0.2 "jsy@localhost" "jsy@$HOST" 127.1 0.0.0.0 0 :: "::ffff:127.0.0.1" 2130706433; do
  i=$((i+1)); fresh "22-$i"; cutover; ingest >/dev/null; A=$(act); rm -rf "$T/rroot22"     # one world per form, so one form that slips through cannot mask or fail the others
  printf '{"host":"%s","root":"%s","launcher":["/home/jsy/.local/bin/fable-launch.sh","--helper"],"model":"claude-opus-5-5","effort":"high"}\n' "$h" "$T/rroot22" > "$T/route22-x.json"
  env -u DIRECTOR_REVIEW_LAUNCH_CMD DIRECTOR_REVIEW_ROUTE="$T/route22-x.json" DIRECTOR_REVIEW_ROOT= python3 "$C" consume >"$T/out.txt" 2>&1
  chk "T22 route-local-refused for host $h, no effect, no reviewer root" '[ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && [ ! -e "$T/rroot22" ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = route-local-refused ]'
done
chk "T22 control: remote hosts are not refused (redbaron, jsy@redbaron, 100.64.1.2, 10.0.0.5, 1.2.3.4)" 'python3 -c "import importlib.util as u,sys; s=u.spec_from_file_location(\"c\", sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m); sys.exit(1 if any(m.route_is_local({\"host\": h}) for h in (\"redbaron\", \"jsy@redbaron\", \"100.64.1.2\", \"10.0.0.5\", \"1.2.3.4\")) else 0)" "$C"'

# names 2026-11-22-wintermute-increment1-review-action-wwhtbt.md#mechanism:12 (the consumer side of the class-owner fence, with T1, T3, T10, T23b, T23c, T30)
echo "== T23 rollback while a review is in flight and the reviewer then dies with no result: nothing is relaunched (check before every relaunch)"
fresh 23; cutover; ingest >/dev/null; A=$(act); run
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback fence" >/dev/null
rm -f "$STUB/live-$(rec $A unit)"; run; run
chk "T23 fenced: one launch only, one launch effect, record blocked fenced" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM effects WHERE ask_id='"'"'$A'"'"'")" = 1 ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = fenced ]'

echo "== T23b rollback after a crash between the launch intent and the launcher: the intent is read back under the fence, nothing launches; re-cutover launches once"
fresh 23b; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-begin run
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback fence" >/dev/null
run; run
chk "T23b fenced: intent settled failed by readback, no launch, record blocked fenced" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = failed ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = fenced ]'
wmd intake class-owner --class $CLS --set director-event-consumer --by hermes --expect-epoch 2 --evidence "re-cutover" >/dev/null; run; run
chk "T23b after re-cutover (epoch 3): exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ]'

echo "== T24 a launching record whose intent was never begun re-enters through the hold gate and the store check (no launch while held)"
fresh 24; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-launching-saved run
chk "T24 crash left launching with no effect" '[ "$(rec $A state)" = launching ] && [ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && [ "$(cnt rlaunch.log)" = 0 ]'
touch "$STUB/hold"; run
chk "T24 held: no effect begun, no launch" '[ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && [ "$(cnt rlaunch.log)" = 0 ]'
rm -f "$STUB/hold"; run
chk "T24 released: exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM effects")" = 1 ]'

echo "== T25 a typed review launcher outside the scratch root blocks only the typed class; the legacy launcher list is unchanged"
fresh 25; cutover
L=$(wmd asks add --owner hermes --due 2026-11-23T09:00 --what "legacy director work" --check "test -n x" --by hermes | grep -o 'A[0-9]*' | head -1)
echo "2026-11-22T21:00:00-08:00 | hermes | DIRECTOR-ACTION ask=$L event=evt-legacy-25 please run" >> "$DIRECTOR_EVENTS_LOG"
DIRECTOR_REVIEW_LAUNCH_CMD=/bin/true python3 "$C" consume >"$T/out.txt" 2>&1; rc=$?
chk "T25 legacy launch not refused by the typed variables (rc 0, one legacy launch)" '[ "$rc" = 0 ] && [ "$(cnt legacy-launch.log)" = 1 ]'

# consumes 2026-11-22-wintermute-increment1-review-action-5whys.md#mechanism:4 (kills mutant D10; mutants carry their AC and finding in mutants/mutant-tags.tsv)
echo "== T26 the binding is superseded while a review runs and the reviewer then dies with no result: nothing is relaunched (store check before every relaunch)"
fresh 26; cutover; ingest >/dev/null; A=$(act); run
wmd intake supersede --envelope "$(python3 -c 'import json,sys; e=json.loads(sys.argv[1]); e.update(supersedes=sys.argv[2], supersede_reason="successor requirement revision", author_lineage=e["author_lineage"]+["dream:r2"]); print(json.dumps(e))' "$ENVL" "$BID")" >/dev/null
rm -f "$STUB/live-$(rec $A unit)"; run; run
chk "T26 one launch, one launch effect, record ended superseded" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM effects WHERE ask_id='"'"'$A'"'"'")" = 1 ] && [ "$(rec $A state)" = superseded ] && [ "$(rec $A code)" = binding-superseded ]'

echo "== T27 installed but not cut over: the recover tick writes nothing (no scan, no action); after the cutover the same tick records one action"
fresh 27; run recover
chk "T27 before cutover: no action, no scan mark" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 0 ] && [ ! -e "$DIRECTOR_STATE/typed/scan.json" ]'
cutover; run recover
chk "T27 after cutover: one action by build-result-ingest" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ] && [ -e "$DIRECTOR_STATE/typed/scan.json" ]'

echo "== T28 live state dir: a typed launcher/probe seam variable is refused (no stub replaces the remote route outside isolation); legacy work is unaffected"
fresh 28; cutover; ingest >/dev/null; A=$(act)
H28="$T/h28"; mkdir -p "$H28/.local/state"
HOME="$H28" DIRECTOR_STATE="$H28/.local/state/director-consumer" python3 "$C" consume >"$T/out.txt" 2>&1
chk "T28 live: nothing launched, no effect, record blocked isolation-refused naming the seam" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(sq "SELECT COUNT(*) FROM effects")" = 0 ] && python3 -c "import json,sys; b=json.load(open(sys.argv[1])).get(\"blocked\") or {}; sys.exit(0 if b.get(\"why\") == \"isolation-refused\" and \"DIRECTOR_REVIEW_LAUNCH_CMD\" in b.get(\"vars\", []) else 1)" "$H28/.local/state/director-consumer/typed/typed-$A.json"'

echo "== T29 a failed producer scan is one typed-scan incident per fault (not per tick); a later healthy scan records its results"
fresh 29; cutover
cat > "$T/wmd-scanfail" <<SH
#!/usr/bin/env bash
case " \$* " in *" intake scan "*) echo "scan unavailable" >&2; exit 1;; esac
exec "$T/wmd" "\$@"
SH
chmod 755 "$T/wmd-scanfail"
WM_ASKS_CMD="$T/wmd-scanfail" run recover; WM_ASKS_CMD="$T/wmd-scanfail" run recover
chk "T29 two failing ticks: exactly one typed-scan incident, no action" '[ "$(grep -c "\"kind\": \"typed-scan\"" "$DIRECTOR_STATE/incidents.jsonl" 2>/dev/null)" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM action_meta")" = 0 ]'
run recover
chk "T29 healthy tick: one action, scan mark carries results" '[ "$(sq "SELECT COUNT(*) FROM action_meta")" = 1 ] && python3 -c "import json,sys; sys.exit(0 if \"results\" in json.load(open(sys.argv[1])) else 1)" "$DIRECTOR_STATE/typed/scan.json"'

echo "== T23c an UNKNOWN effect under a fence: an answering probe settles it, nothing launches; re-cutover launches once"
fresh 23c; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-begin run; touch "$STUB/probe-unknown"; run
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback fence" >/dev/null
rm -f "$STUB/probe-unknown"; run; run
chk "T23c fenced: UNKNOWN settled failed by the answering probe, no launch, record blocked fenced" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = failed ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$DIRECTOR_STATE/typed/typed-$A.json" 2>/dev/null)" = fenced ]'
wmd intake class-owner --class $CLS --set director-event-consumer --by hermes --expect-epoch 2 --evidence "re-cutover" >/dev/null; run; run
chk "T23c after re-cutover: exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ]'

echo "== T30 live state dir under a fence: the typed probe seam is refused there too (no stub probe runs, the UNKNOWN effect stays for a real probe or the owner)"
fresh 30; cutover; ingest >/dev/null; A=$(act)
DIRECTOR_CRASH_AT=typed-after-begin run; touch "$STUB/probe-unknown"; run
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback fence" >/dev/null
H30="$T/h30"; mkdir -p "$H30/.local/state"; cp -a "$DIRECTOR_STATE" "$H30/.local/state/director-consumer"
rm -f "$STUB/probe-unknown"; : > "$STUB/rprobe.log"
HOME="$H30" DIRECTOR_STATE="$H30/.local/state/director-consumer" python3 "$C" consume >"$T/out.txt" 2>&1
chk "T30 live fenced pass: no stub probe, effect still unknown, no launch, record blocked fenced" '[ "$(cnt rprobe.log)" = 0 ] && [ "$(sq "SELECT state FROM effects WHERE ask_id='"'"'$A'"'"'")" = unknown ] && [ "$(cnt rlaunch.log)" = 0 ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get(\"blocked\") or {}).get(\"why\"))" "$H30/.local/state/director-consumer/typed/typed-$A.json" 2>/dev/null)" = fenced ]'

# IR1-F1 (independent review 01, finding 1): a transient builder state is a wait, never a terminal refusal of a valid action
echo "== T32 a same-head re-gate in flight at execution: the run waits (not terminal); after the re-gate passes it launches exactly once"
fresh 32; cutover; ingest >/dev/null; A=$(act)
gate_open 950; run
chk "T32 while the re-gate runs: no launch, record waiting (not terminal), ask still ready" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(rec $A state)" = builder-wait ] && [ "$(state_of $A)" = ready ]'
gate_close 950 "$HEAD1"; ingest >/dev/null; run; run
chk "T32 after the same-head pass: exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(state_of $A)" = running ]'

echo "== T32b an infra gate result then a same-head pass: the run waits, then launches exactly once"
fresh 32b; cutover; ingest >/dev/null; A=$(act)
gate_infra 951; run
chk "T32b after the infra gate: no launch, record waiting, ask still ready" '[ "$(cnt rlaunch.log)" = 0 ] && [ "$(rec $A state)" = builder-wait ] && [ "$(state_of $A)" = ready ]'
gate_open 952; gate_close 952 "$HEAD1"; ingest >/dev/null; run; run
chk "T32b after the same-head pass: exactly one launch" '[ "$(cnt rlaunch.log)" = 1 ]'

echo "== T35 heads A -> B -> A before execution: head A is reviewed exactly once (no replay to the cancelled action)"
fresh 35; cutover; ingest >/dev/null; A=$(act)
builder gate "$HEAD2" 902; ingest >/dev/null; B=$(act)
builder gate "$HEAD1" 903; ingest >/dev/null; A2=$(act)
chk "T35 the return to head A records a new action; A and B are cancelled; one ready action" '[ "$A2" != "$A" ] && [ "$A2" != "$B" ] && [ "$(state_of $A)" = cancelled ] && [ "$(state_of $B)" = cancelled ] && [ "$(wmd intake ready-actions --class $CLS | jget "[a[\"ask_id\"] for a in d]")" = "['"'"'$A2'"'"']" ]'
run; run
chk "T35 exactly one launch, for head A" '[ "$(cnt rlaunch.log)" = 1 ] && grep -q "$HEAD1" "$STUB/last-review-prompt.md"'

# IR1-F3: a relaunch consults the builder's STOP state like the first launch does
echo "== T33 the builder run is paused / no_continue after the first launch and the reviewer dies: no relaunch until it is released"
fresh 33; cutover; ingest >/dev/null; A=$(act); run
set_run paused_at "2026-11-22T22:00:00+00:00"; set_run no_continue 1
rm -f "$STUB/live-$(rec $A unit)"; run
chk "T33 paused: one launch only, record blocked builder-held" '[ "$(cnt rlaunch.log)" = 1 ] && [ "$(blk $A)" = held ]'
set_run paused_at NULL; set_run no_continue 0; run
chk "T33 released: exactly one relaunch" '[ "$(cnt rlaunch.log)" = 2 ]'

# IR1-F2: rollback then re-cutover while a review is in flight: the same consumer re-adopts its own claim under the new epoch
echo "== T34 rollback (owner none) then re-cutover with a review in flight: the result is recorded under the new epoch"
fresh 34; cutover 0; ingest >/dev/null; A=$(act); run
S=$(rec $A session); U=$(rec $A unit); RT=$(rec $A root)
wmd intake class-owner --class $CLS --set none --by hermes --expect-epoch 1 --evidence "rollback" >/dev/null; run
chk "T34 fenced while rolled back" '[ "$(blk $A)" = fenced ]'
cutover 2
printf '{"verdict":"APPROVE","reviewed_head":"%s","reviewer_session":"%s","findings":[]}\n' "$HEAD1" "$S" > "$RT/verdict.json"; rm -f "$STUB/live-$U"; run; run
chk "T34 after re-cutover (epoch 3): result recorded, record re-adopted at epoch 3, one launch" '[ "$(state_of $A)" = verifying ] && [ "$(rec $A epoch)" = 3 ] && [ "$(cnt rlaunch.log)" = 1 ] && grep -q "\"decision\": \"re-adopted\"" "$DIRECTOR_STATE/decisions.jsonl" 2>/dev/null'

echo "COUNTS: pass=$passes fail=$fails"
[ "$fails" = 0 ]
