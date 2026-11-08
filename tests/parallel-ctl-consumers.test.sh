#!/usr/bin/env bash
# parallel-ctl-consumers.test.sh (parent A1296): N consumers share one state dir and one canonical ledger. Fixtures only:
# stubs for wm-asks (flock-atomic db with --expect-rev), launcher, hold gate and unit liveness. No real Hermes, no real data.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="$HERE/.local/bin/director-event-consumer.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
only="${1:-}"   # optional: run one named group, e.g. `race`

cat > "$T/wm-asks" <<'PY'
#!/usr/bin/env python3
import fcntl, json, os, sys
S = os.environ["STUB"]
a = sys.argv[1:]
lk = open(S + "/db.lock", "a"); fcntl.flock(lk, fcntl.LOCK_EX)
open(S + "/calls.log", "a").write(" ".join(a) + "\n")
if os.path.exists(S + "/down"): sys.exit(3)
db = json.load(open(S + "/db.json"))
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    rows = list(db.values())
    if "--ids" in a: rows = [db[a[a.index("--ids")+1]]] if a[a.index("--ids")+1] in db else []
    if "--ready" in a: rows = [r for r in rows if r.get("ready") and not r.get("claim") and r["owner"] == "hermes"]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker")+1]
    if "--expect-rev" in a and int(a[a.index("--expect-rev")+1]) != r["rev"]: sys.exit(1)
    stamp = os.path.exists(S + "/stamp")   # like real wm-asks: claim is stored as "<worker>@<timestamp>"
    if r.get("claim") and r["claim"].split("@")[0] != w: sys.exit(1)
    r["claim"] = (w + "@2026-11-08T04:00") if stamp else w; r["rev"] += 1; save(); sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append")+1]); r["rev"] += 1; save(); sys.exit(0)
sys.exit(2)
PY
cat > "$T/launcher" <<'SH'
#!/usr/bin/env bash
sleep "${LAUNCH_DELAY:-0}"
echo "$1" >> "$STUB/launch.log"
[ -e "$STUB/outage" ] && exit 75
[ -e "$STUB/launch-fail" ] && exit 1; exit 0
SH
cat > "$T/hold" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/hold" ] && exit 1; exit 0
SH
cat > "$T/active" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/inactive.$1" ] && exit 1
[ -e "$STUB/active.$1" ] || [ -e "$STUB/active.all" ]
SH
cat > "$T/reset" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$STUB/reset.log"
SH
chmod +x "$T"/wm-asks "$T"/launcher "$T"/hold "$T"/active "$T"/reset

row(){ # id rev ready claim scope
  printf '"%s":{"ask_id":"%s","rev":%s,"owner":"hermes","status":"open","claim":%s,"ready":%s,"what":"w","check":"c","scope":"%s"}' "$1" "$1" "$2" "${4:-null}" "${3:-false}" "${5:-}"
}
fresh(){ # new stub + state world; rows given as extra args
  export STUB="$T/s$1" DIRECTOR_STATE="$T/st$1" DIRECTOR_EVENTS_LOG="$T/ev$1.log"
  rm -rf "$STUB" "$DIRECTOR_STATE"; mkdir -p "$STUB"; : > "$DIRECTOR_EVENTS_LOG"
  shift; local IFS=,; echo "{$*}" > "$STUB/db.json"; unset IFS
  export WM_ASKS_CMD="$T/wm-asks" DIRECTOR_LAUNCH_CMD="$T/launcher" HOLD_GATE="$T/hold" DIRECTOR_ACTIVE_CMD="$T/active" DIRECTOR_RESET_CMD="$T/reset"
  export DIRECTOR_HERMES_CMD=/bin/false DIRECTOR_CONSUMER=c1
  unset DIRECTOR_CRASH_AT LAUNCH_DELAY
}
as(){ local who="$1"; shift; DIRECTOR_CONSUMER="$who" python3 "$C" "$@" >>"$T/out.txt" 2>&1; }
cnt(){ local n; n="$(grep -c -- "$1" "$STUB/$2" 2>/dev/null)"; echo "${n:-0}"; }
ev(){ echo "2026-11-08T01:00:00-08:00 | hermes | DIRECTOR-ACTION ask=$1 event=$2 do it" >> "$DIRECTOR_EVENTS_LOG"; }
st(){ python3 -c "import json,sys;print(json.load(open('$DIRECTOR_STATE/runs/$1.json'))['state'])" 2>/dev/null; }
want(){ [ "$only" = "" ] || [ "$only" = "$1" ]; }

if want distinct; then
fresh 1 "$(row A100 1)" "$(row A101 1)"; ev A100 evt-0100; ev A101 evt-0101; export LAUNCH_DELAY=0.4
as c1 consume & as c2 consume & as c3 recover & wait
chk "two consumers, distinct tasks: each ask claimed once" '[ "$(cnt "asks claim A100" calls.log)" = 1 ] && [ "$(cnt "asks claim A101" calls.log)" = 1 ]'
chk "two consumers, distinct tasks: each launched once, both launched" '[ "$(cnt director-run-evt-0100-a1 launch.log)" = 1 ] && [ "$(cnt director-run-evt-0101-a1 launch.log)" = 1 ]'
chk "claims name their owner identity" 'grep -q "\"claim\": \"director-evt-0100\.c[123]\"" $DIRECTOR_STATE/runs/evt-0100.json'
fi

if want race; then
fresh 2 "$(row A100 1 true)"; export LAUNCH_DELAY=0.3
for c in c1 c2 c3 c4 c5 c6; do as $c recover & done; wait
chk "same-task race x6: exactly one ledger claim write" '[ "$(cnt "asks claim A100" calls.log)" = 1 ]'
chk "same-task race x6: exactly one launch, one owner" '[ "$(wc -l < $STUB/launch.log)" = 1 ] && [ "$(ls $DIRECTOR_STATE/runs/*.owner | wc -l)" = 1 ]'
fresh 3 "$(row A100 1)"; ev A100 evt-race1; for c in c1 c2 c3 c4; do as $c consume & done; wait
chk "same log event read by 4 consumers: one claim, one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fresh 4 "$(row A100 1)"; ev A100 evt-first; as c1 consume; ev A100 evt-second; as c2 consume
chk "second event for a busy ask: ask-busy, no second claim or launch" '[ "$(st evt-second)" = ask-busy ] && [ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fi

if want crash; then
fresh 5 "$(row A100 1)"; ev A100 evt-0100; as c1 consume
as c2 recover
chk "owner dead before effect, unit gone: peer relaunches once under the same claim" '[ "$(cnt director-run-evt-0100-a2 launch.log)" = 1 ] && grep -q "\"claim\": \"director-evt-0100.c1\"" $DIRECTOR_STATE/runs/evt-0100.json && [ "$(cnt "asks claim" calls.log)" = 1 ]'
fresh 6 "$(row A100 1)"; ev A100 evt-0100; as c1 consume
printf 'STEP wrote-file\nDONE\n' > "$DIRECTOR_STATE/runs/evt-0100.effect"; as c2 recover
chk "crash after effect (DONE) before receipt: receipt written, NO relaunch" '[ "$(wc -l < $STUB/launch.log)" = 1 ] && [ "$(st evt-0100)" = completed ] && [ -s $DIRECTOR_STATE/runs/evt-0100.receipt.json ]'
fresh 7 "$(row A100 1)"; ev A100 evt-0100; as c1 consume
printf 'STEP one\n' > "$DIRECTOR_STATE/runs/evt-0100.effect"; as c2 recover
chk "partial effect ledger (no DONE): relaunch resumes, no receipt" '[ "$(wc -l < $STUB/launch.log)" = 2 ] && [ "$(st evt-0100)" = launched ] && [ ! -e $DIRECTOR_STATE/runs/evt-0100.receipt.json ]'
chk "relaunch resets a lingering failed unit first" '[ "$(cnt director-run-evt-0100-a2 reset.log)" = 1 ]'
fresh 8 "$(row A100 1)"; ev A100 evt-0100; export DIRECTOR_CRASH_AT=after-seen; as c1 consume; unset DIRECTOR_CRASH_AT
chk "crash after seen, before offset: record exists, nothing claimed, offset not moved" '[ "$(st evt-0100)" = seen ] && [ ! -s $DIRECTOR_STATE/offset ] && [ "$(cnt "asks claim" calls.log)" = 0 ]'
as c2 consume
chk "peer consume replays the log: one claim, one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fresh 9 "$(row A100 1)"; ev A100 evt-0100; export DIRECTOR_CRASH_AT=after-offset; as c1 consume; unset DIRECTOR_CRASH_AT
chk "crash after offset advance: event not lost (seen record)" '[ "$(st evt-0100)" = seen ] && [ -s $DIRECTOR_STATE/offset ]'
as c2 recover
chk "recover picks the seen record up: one claim, one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fi

if want outage; then
fresh 10 "$(row A100 1)"; ev A100 evt-0100; touch "$STUB/outage"; as c1 consume; as c2 recover; as c3 recover; as c1 recover
chk "provider outage: task stays durably owned (claim kept, state provider-outage)" '[ "$(st evt-0100)" = provider-outage ] && grep -q "director-evt-0100.c1" $STUB/db.json'
chk "provider outage: attempts not counted, never stuck, no ledger note" '! grep -q "\"state\": \"stuck\"" $DIRECTOR_STATE/runs/evt-0100.json && grep -q "\"attempts\": 0" $DIRECTOR_STATE/runs/evt-0100.json && [ "$(cnt "asks update" calls.log)" = 0 ]'
rm "$STUB/outage"; as c2 recover
chk "provider back: owned task launches, claim not re-written" '[ "$(st evt-0100)" = launched ] && [ "$(cnt "asks claim" calls.log)" = 1 ]'
touch "$DIRECTOR_STATE/runs/evt-0100.outage"; as c3 recover
chk "worker exits on outage (marker): relaunch without counting an attempt" '[ "$(st evt-0100)" = launched ] && grep -q "\"attempts\": 1" $DIRECTOR_STATE/runs/evt-0100.json && [ ! -e $DIRECTOR_STATE/runs/evt-0100.outage ]'
fi

if want live; then
fresh 11 "$(row A100 1)"; ev A100 evt-0100; as c1 consume
touch -d '3 days ago' "$DIRECTOR_STATE/runs/evt-0100.json"; touch "$STUB/active.director-run-evt-0100-a1"
for c in c2 c3 c4; do as $c recover; done
chk "healthy long worker (unit active, run file 3 days old): never stolen, no relaunch, no note" '[ "$(wc -l < $STUB/launch.log)" = 1 ] && [ "$(st evt-0100)" = launched ] && [ "$(cnt "asks update" calls.log)" = 0 ]'
fi

if want replay; then
fresh 12 "$(row A100 1)"; ev A100 evt-0100; as c1 consume; printf 'DONE\n' > "$DIRECTOR_STATE/runs/evt-0100.effect"; as c2 recover
before="$(cd $DIRECTOR_STATE/runs && find . -type f ! -name '*.lock' -exec md5sum {} + | sort | md5sum)"; : > "$STUB/calls.log"
as c1 consume; as c2 recover; as c3 recover; rm -f "$DIRECTOR_STATE/offset"; as c1 consume
after="$(cd $DIRECTOR_STATE/runs && find . -type f ! -name '*.lock' -exec md5sum {} + | sort | md5sum)"
chk "replay after completion (restart, lost offset): state unchanged" '[ "$before" = "$after" ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
chk "replay after completion: no ledger writes" '[ "$(cnt "asks \(claim\|update\)" calls.log)" = 0 ]'
fi

if want rev; then
seed(){ # seed <eid> <ask> <event_rev>: a ready event as an earlier consumer left it, before the row changed
  mkdir -p "$DIRECTOR_STATE/runs"
  python3 - "$DIRECTOR_STATE" "$1" "$2" "$3" <<'PY'
import json, sys
D, eid, ask, rev = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({"event_id": eid, "ask": ask, "text": "x", "source": "ready", "event_rev": rev, "state": "seen", "attempts": 0,
           "worker": "director-%s.c1" % eid, "owner": "c1"}, open("%s/runs/%s.json" % (D, eid), "w"))
open("%s/runs/%s.owner" % (D, eid), "w").write("c1\n")
PY
}
fresh 13 "$(row A300 4 false "\"someone-else@x\"")"; seed ready-A300-3 A300 3; as c2 recover
chk "stale rev event, row no longer ready: revision-mismatch, no claim, no launch" '[ "$(st ready-A300-3)" = superseded ] && [ "$(cnt "asks claim" calls.log)" = 0 ] && [ ! -e $STUB/launch.log ]'
fresh 14 "$(row A301 4 true)"; seed ready-A301-3 A301 3; as c2 recover
chk "edit-while-ready (rev 3 event, row rev 4 still ready): not dropped, claimed at rev 4" '[ "$(cnt "asks claim A301 --worker director-ready-A301-3.c1 --by hermes --expect-rev 4" calls.log)" = 1 ] && [ "$(st ready-A301-3)" = launched ]'
fresh 15 "$(row A302 2 true)"; seed ready-A302-2 A302 2; python3 - <<PY
import json,os
p=os.environ["STUB"]+"/db.json"; d=json.load(open(p)); d["A302"]["rev"]=3; json.dump(d,open(p,"w"))
PY
rm -f "$STUB/x"; ( sleep 0.1; true ) ; as c2 recover
chk "claim carries the rev just read, so a ledger edit between read and claim cannot be overwritten" 'grep -q -- "--expect-rev 3" $STUB/calls.log'
fi

if want scope; then
fresh 18 "$(row A400 1 true null promote:prod)" "$(row A401 1 true null promote:prod)" "$(row A402 1 true null)" "$(row A403 1 true null live-settings,promote:prod)"
export LAUNCH_DELAY=0.2
as c1 recover & as c2 recover & as c3 recover & wait
chk "same-target promotion serialized: exactly one of A400/A401/A403 launched" '[ "$(cat $STUB/launch.log | grep -c -E "A40[013]")" = 1 ]'
chk "independent unscoped task launches meanwhile" '[ "$(cnt director-run-ready-A402-1-a1 launch.log)" = 1 ]'
chk "blocked peers wait in scope-wait without a claim" '[ "$(grep -c "scope-wait" <(for f in $DIRECTOR_STATE/runs/*.json; do python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\"state\"])" $f; done))" = 2 ] && [ "$(cnt "asks claim" calls.log)" = 2 ]'
unset LAUNCH_DELAY
first="$(grep -o -E "ready-A40[013]-1" $STUB/launch.log | head -1)"
# every unit is healthy except the finished owner's, so a waiter launched by the wake is not mistaken for a dead worker
touch "$STUB/active.all" "$STUB/inactive.director-run-$first-a1"; printf 'DONE\n' > "$DIRECTOR_STATE/runs/$first.effect"; as c1 recover
chk "owner done: scope released, next waiter launched by the wake" '[ "$(st $first)" = completed ] && [ "$(cat $STUB/launch.log | grep -c -E "A40[013]")" = 2 ]'
fi

if want stamped; then
# real wm-asks stores claim as worker@timestamp (swarm-decide asks.py stamp); the stub does the same here
fresh 19 "$(row A100 1)" "$(row A101 1)"; touch "$STUB/stamp"; ev A100 evt-0100; ev A101 evt-0101; export LAUNCH_DELAY=0.3
as c1 consume & as c2 consume & as c3 recover & wait
chk "stamped claims: ledger claim carries @timestamp" 'grep -q "director-evt-0100\.c[123]@2026" $STUB/db.json'
chk "stamped claims: each task launched once (own claim is not a conflict)" '[ "$(cnt director-run-evt-0100-a1 launch.log)" = 1 ] && [ "$(cnt director-run-evt-0101-a1 launch.log)" = 1 ] && [ "$(st evt-0100)" = launched ]'
fresh 20 "$(row A100 1 true)"; touch "$STUB/stamp"; export LAUNCH_DELAY=0.3
for c in c1 c2 c3 c4 c5 c6; do as $c recover & done; wait
chk "stamped claims, race x6: one claim write, one launch" '[ "$(cnt "asks claim A100" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fresh 21 "$(row A100 1)"; touch "$STUB/stamp"; ev A100 evt-first; as c1 consume; ev A100 evt-second; as c2 consume
chk "stamped claims: second event for a busy ask is ask-busy, not claim-conflict" '[ "$(st evt-second)" = ask-busy ] && [ "$(cnt "asks claim" calls.log)" = 1 ]'
fresh 22 "$(row A100 1)"; touch "$STUB/stamp"; ev A100 evt-0100; as c1 consume; touch "$STUB/active.director-run-evt-0100-a1"; as c2 recover; as c3 recover
chk "stamped claims: replay/recover keeps one claim and one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(wc -l < $STUB/launch.log)" = 1 ]'
fi

if want scopetoken; then
# real rows have no scope field: the carrier is a `scope=a,b` token in the what text
mk(){ printf '"%s":{"ask_id":"%s","rev":1,"owner":"hermes","status":"open","claim":null,"ready":true,"what":"w scope=promote:prod waits-on=row:Z1","check":"c"}' "$1" "$1"; }
fresh 23 "$(mk A500)" "$(mk A501)"; touch "$STUB/stamp"; export LAUNCH_DELAY=0.2
as c1 recover & as c2 recover & wait
chk "scope token in what text serializes the shared target (no scope field, stamped claims)" '[ "$(wc -l < $STUB/launch.log)" = 1 ] && [ "$(cnt "asks claim" calls.log)" = 1 ]'
fi

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
