#!/usr/bin/env bash
# director-event-consumer.test.sh (A1299): stubs for wm-asks, launcher, hold-gate, is-active; no real Hermes run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="$HERE/.local/bin/director-event-consumer.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

cat > "$T/wm-asks" <<'PY'
#!/usr/bin/env python3
import json, os, sys
S = os.environ["STUB"]
open(S + "/calls.log", "a").write(" ".join(sys.argv[1:]) + "\n")
if os.path.exists(S + "/down"): sys.exit(3)
if os.path.exists(S + "/garbage"): print("not json {"); sys.exit(0)
db = json.load(open(S + "/db.json"))
a = sys.argv[1:]
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    rows = list(db.values())
    if "--ids" in a: rows = [db[a[a.index("--ids")+1]]] if a[a.index("--ids")+1] in db else []
    if "--ready" in a: rows = [r for r in rows if r.get("ready") and not r.get("claim") and r["owner"] == "hermes"]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker")+1]
    if r.get("claim") and r["claim"] != w: sys.exit(1)
    r["claim"] = w; r["rev"] += 1; save(); sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append")+1]); r["rev"] += 1; save(); sys.exit(0)
sys.exit(2)
PY
cat > "$T/launcher" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$STUB/launch.log"; cp "$2" "$STUB/last-envelope.md"
[ -e "$STUB/launch-outage" ] && exit 75
[ -e "$STUB/launch-fail" ] && exit 1; exit 0
SH
cat > "$T/hold" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$STUB/hold.log"; [ -e "$STUB/hold" ] && { echo held >&2; exit 1; }; exit 0
SH
cat > "$T/active" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/active" ]
SH
chmod +x "$T"/wm-asks "$T"/launcher "$T"/hold "$T"/active

fresh(){ # new stub + state world
  export STUB="$T/s$1" DIRECTOR_STATE="$T/st$1" DIRECTOR_EVENTS_LOG="$T/ev$1.log"
  rm -rf "$STUB" "$DIRECTOR_STATE"; mkdir -p "$STUB"; : > "$DIRECTOR_EVENTS_LOG"
  echo '{"A100":{"ask_id":"A100","rev":3,"owner":"hermes","status":"open","claim":null,"ready":false,"what":"w","check":"c"},
         "A200":{"ask_id":"A200","rev":1,"owner":"hermes","status":"open","claim":"someone-else@x","ready":false,"what":"w","check":"c"}}' > "$STUB/db.json"
  export WM_ASKS_CMD="$T/wm-asks" DIRECTOR_LAUNCH_CMD="$T/launcher" HOLD_GATE="$T/hold" DIRECTOR_ACTIVE_CMD="$T/active"
  export DIRECTOR_HERMES_CMD=/bin/false
}
run(){ python3 "$C" "$@" >"$T/out.txt" 2>&1; }
cnt(){ local n; n="$(grep -c -- "$1" "$STUB/$2" 2>/dev/null)"; echo "${n:-0}"; }
ev(){ echo "2026-11-08T01:00:00-08:00 | hermes | $1" >> "$DIRECTOR_EVENTS_LOG"; }
M='DIRECTOR-ACTION ask=A100 event=evt-0001'

fresh 1; ev "just chatter, no marker A100"; run
chk "known-bad control: no marker => no claim, no launch" '[ "$(cnt claim calls.log)" = 0 ] && [ ! -e "$STUB/launch.log" ] && [ "$(cat $DIRECTOR_STATE/offset)" -gt 0 ]'

fresh 2; ev "$M do the thing"; run
chk "actionable: one claim" '[ "$(cnt "asks claim A100 --worker director-evt-0001.c0 --by hermes --expect-rev 3" calls.log)" = 1 ]'
chk "actionable: one launch" '[ "$(cnt director-run-evt-0001-a1 launch.log)" = 1 ]'
chk "actionable: state launched + hold gate asked" 'grep -q "\"state\": \"launched\"" $DIRECTOR_STATE/runs/evt-0001.json && grep -q "director-consumer:A100" $STUB/hold.log'
chk "envelope: mode 600, event text only in quoted block" '[ "$(stat -c %a $DIRECTOR_STATE/runs/evt-0001.envelope.md)" = 600 ] && grep -q "^> .*do the thing" $STUB/last-envelope.md && [ "$(grep -c "do the thing" $STUB/last-envelope.md)" = "$(grep -c "^> .*do the thing" $STUB/last-envelope.md)" ]'
chk "decisions printed and appended" 'grep -q launched $T/out.txt && grep -q launched $DIRECTOR_STATE/decisions.jsonl'

run; ev "$M again"; run
chk "duplicate delivery (same event twice) => still one claim, one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 1 ]'
rm "$DIRECTOR_STATE/offset"; run
chk "offset lost then replay => still one claim, one launch" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 1 ]'

# complete
echo '{"x":1}' > "$T/effect.json"
python3 "$C" complete evt-0001 --effect "$T/nope.json" >/dev/null 2>&1; rc=$?
chk "complete refuses missing effect" '[ $rc -ne 0 ] && [ ! -e $DIRECTOR_STATE/runs/evt-0001.receipt.json ]'
: > "$T/empty.json"; python3 "$C" complete evt-0001 --effect "$T/empty.json" >/dev/null 2>&1; rc=$?
chk "complete refuses empty effect" '[ $rc -ne 0 ]'
python3 "$C" complete evt-0001 --effect "$T/effect.json" >/dev/null 2>&1; rc=$?
chk "complete writes receipt, state=completed, ask not closed" '[ $rc -eq 0 ] && grep -q "\"state\": \"completed\"" $DIRECTOR_STATE/runs/evt-0001.json && grep -q "director-evt-0001.c0" $DIRECTOR_STATE/runs/evt-0001.receipt.json && grep -q "\"ask_status\": \"open\"" $DIRECTOR_STATE/runs/evt-0001.receipt.json && [ "$(cnt "asks \(resolve\|accept\|close\)" calls.log)" = 0 ]'

# crash after launch before receipt
fresh 3; ev "$M x"; run
touch "$STUB/active"; : > "$STUB/calls.log"; run recover
chk "recover: unit active => left alone" '[ "$(cnt director-run launch.log)" = 1 ] && [ "$(cnt claim calls.log)" = 0 ]'
rm "$STUB/active"; run recover
chk "crash before receipt: single relaunch, same claim/event id" '[ "$(cnt director-run-evt-0001 launch.log)" = 2 ] && [ "$(cnt "asks claim" calls.log)" = 0 ] && grep -q "\"claim\": \"director-evt-0001.c0\"" $DIRECTOR_STATE/runs/evt-0001.json'
run recover
chk "second crash: relaunched, not stuck, same claim, no new claim" '[ "$(cnt director-run launch.log)" = 3 ] && ! grep -q "\"state\": \"stuck\"" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 0 ]'
for i in 1 2 3 4; do run recover; done
chk "seven crashes: still relaunching, never stuck, attempt count does not end the work" '[ "$(cnt director-run launch.log)" = 7 ] && ! grep -q "\"state\": \"stuck\"" $DIRECTOR_STATE/runs/evt-0001.json'
chk "visibility note: one owned note with --by hermes --expect-rev, no date change, work not ended" '[ "$(cnt "asks update A100 --by hermes --expect-rev" calls.log)" = 1 ] && ! grep -q -- "--due" $STUB/calls.log'
touch "$STUB/active"; run recover; run recover
chk "healthy live worker after many attempts: not stolen, no launch, no new note" '[ "$(cnt director-run launch.log)" = 7 ] && [ "$(cnt "asks update" calls.log)" = 1 ]'

# held
fresh 4; touch "$STUB/hold"; ev "$M x"; run
chk "held: no claim, no launch, state=held" '[ "$(cnt "asks claim" calls.log)" = 0 ] && [ ! -e $STUB/launch.log ] && grep -q "\"state\": \"held\"" $DIRECTOR_STATE/runs/evt-0001.json'
run recover; run recover
chk "held stays held across recover while gate blocks" '[ "$(cnt "asks claim" calls.log)" = 0 ] && [ "$(grep -c held $DIRECTOR_STATE/decisions.jsonl)" = 1 ]'
rm "$STUB/hold"; run recover
chk "gate passes => recover claims and launches once" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 1 ]'

# canonical unavailable
fresh 5; touch "$STUB/down"; ev "$M x"; run
chk "canonical-unavailable: no claim, no launch, no TSV fallback" '[ ! -e $STUB/launch.log ] && grep -q "\"state\": \"canonical-unavailable\"" $DIRECTOR_STATE/runs/evt-0001.json'
rm "$STUB/down"; run recover
chk "canonical back => recover proceeds once" '[ "$(cnt director-run launch.log)" = 1 ]'

# claim conflict
fresh 6; ev "DIRECTOR-ACTION ask=A200 event=evt-0200 x"; run
chk "claim-conflict: nothing launched" '[ ! -e $STUB/launch.log ] && grep -q "\"state\": \"claim-conflict\"" $DIRECTOR_STATE/runs/evt-0200.json && [ "$(cnt "asks claim" calls.log)" = 0 ]'

# malicious text
fresh 7; X="$T/PWNED"
ev "$M \$(touch $X) \`touch $X\` ; touch $X"
printf '2026-11-08T01:00:01-08:00 | hermes | DIRECTOR-ACTION ask=A100 event=evt-0002 line1\n' >> "$DIRECTOR_EVENTS_LOG"
run
chk "malicious text never executes" '[ ! -e "$X" ]'
chk "malicious text sits inside the quoted block" '! grep -v "^> " $STUB/last-envelope.md | grep -q "touch"'

# bad ids
fresh 8
ev "DIRECTOR-ACTION ask=A100 event=ab"; ev "DIRECTOR-ACTION ask=A10x event=evt-good1"; ev "DIRECTOR-ACTION ask=A100 event=bad/id/with/slash"
ev "DIRECTOR-ACTION ask=A100 event=$(printf 'e%.0s' $(seq 81))"; run
chk "bad ids rejected: no claim, no launch" '[ "$(cnt "asks claim" calls.log)" = 0 ] && [ ! -e $STUB/launch.log ]'
chk "bad ids rejected: decision recorded" '[ "$(grep -c rejected $DIRECTOR_STATE/decisions.jsonl)" -ge 3 ]'

# launch failure
fresh 9; touch "$STUB/launch-fail"; ev "$M x"; run
chk "launch-failed: claim kept, attempt counted, no note yet" 'grep -q "\"state\": \"launch-failed\"" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(cnt "asks update" calls.log)" = 0 ]'
run recover; run recover; run recover; run recover
chk "launch failures keep retrying: 5 launches, still launch-failed, never stuck" '[ "$(cnt director-run launch.log)" = 5 ] && grep -q "\"state\": \"launch-failed\"" $DIRECTOR_STATE/runs/evt-0001.json && ! grep -q "\"state\": \"stuck\"" $DIRECTOR_STATE/runs/evt-0001.json'
chk "launch failures: exactly one visibility note, no self-posting loop" '[ "$(cnt "asks update" calls.log)" = 1 ] && ! grep -q -- "--due" $STUB/calls.log'
rm "$STUB/launch-fail"; run recover
chk "launcher healthy again: launched on the same claim, one claim total" '[ "$(cnt director-run launch.log)" = 6 ] && grep -q "\"state\": \"launched\"" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 1 ]'

# ready source
fresh 10
python3 - <<PY
import json,os
p=os.environ["STUB"]+"/db.json"; d=json.load(open(p)); d["A100"]["ready"]=True; json.dump(d,open(p,"w"))
PY
run recover
chk "ready row => event ready-A100-3, one claim, one launch" '[ "$(cnt director-run-ready-A100-3-a1 launch.log)" = 1 ] && [ "$(cnt "asks claim" calls.log)" = 1 ]'
touch "$STUB/active"; run recover
chk "ready row claimed => not re-acted" '[ "$(cnt "asks claim" calls.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 1 ]'

# provider outage stays durable and recoverable (never counted, never stuck)
fresh 12; touch "$STUB/launch-outage"; ev "$M x"; run
for i in 1 2 3 4 5; do run recover; done
chk "outage: claim kept, provider-outage state, attempts not counted, never stuck" 'grep -q "\"state\": \"provider-outage\"" $DIRECTOR_STATE/runs/evt-0001.json && grep -q "\"attempts\": 0" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 1 ] && ! grep -q stuck $DIRECTOR_STATE/runs/evt-0001.json'
rm "$STUB/launch-outage"; run recover
chk "outage over: launched, no new claim" 'grep -q "\"state\": \"launched\"" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 1 ]'

# unknown effect: BEGIN without END is never blindly replayed; an owned reconciliation gate holds it
fresh 13; ev "$M x"; run
printf 'BEGIN push-config\n' > "$DIRECTOR_STATE/runs/evt-0001.effect"
: > "$STUB/calls.log"; run recover; run recover; run recover
chk "unknown effect: reconcile-required, no relaunch across ticks, claim kept" '[ "$(cnt director-run launch.log)" = 1 ] && grep -q "\"state\": \"reconcile-required\"" $DIRECTOR_STATE/runs/evt-0001.json && [ "$(cnt "asks claim" calls.log)" = 0 ]'
chk "unknown effect: one owned note naming the step, ask not closed" '[ "$(cnt "asks update A100 --by hermes --expect-rev" calls.log)" = 1 ] && grep -q "push-config" $STUB/db.json && [ "$(cnt "asks \(resolve\|accept\|close\)" calls.log)" = 0 ]'
python3 "$C" reconcile evt-0001 --verdict bogus --by t >/dev/null 2>&1; rc=$?
chk "reconcile refuses an unknown verdict, gate stays" '[ $rc -ne 0 ] && grep -q "\"state\": \"reconcile-required\"" $DIRECTOR_STATE/runs/evt-0001.json'
python3 "$C" reconcile evt-0001 --verdict absent --by t >/dev/null 2>&1; rc=$?
chk "reconcile absent: gate released, ledger records the verdict" '[ $rc -eq 0 ] && grep -q "ABSENT push-config" $DIRECTOR_STATE/runs/evt-0001.effect'
run recover
chk "after reconcile: exactly one relaunch, envelope tells the worker the step was reconciled" '[ "$(cnt director-run launch.log)" = 2 ] && grep -qi "reconcil" $STUB/last-envelope.md'
fresh 14; ev "$M x"; run
printf 'BEGIN s1\nEND s1\n' > "$DIRECTOR_STATE/runs/evt-0001.effect"; run recover
chk "recorded steps (BEGIN/END matched): safe relaunch resumes from the ledger" '[ "$(cnt director-run launch.log)" = 2 ] && ! grep -q reconcile-required $DIRECTOR_STATE/runs/evt-0001.json'

# completed receipt is never repeated
fresh 15; ev "$M x"; run
printf 'BEGIN s1\nEND s1\nDONE\n' > "$DIRECTOR_STATE/runs/evt-0001.effect"
python3 "$C" complete evt-0001 --effect "$DIRECTOR_STATE/runs/evt-0001.effect" >/dev/null 2>&1
: > "$STUB/calls.log"; run recover; run recover; run recover
chk "completed receipt: no relaunch, no claim, no note across recovers" '[ "$(cnt director-run launch.log)" = 1 ] && [ "$(cnt "asks \(claim\|update\)" calls.log)" = 0 ]'
fresh 16; ev "$M x"; run
printf 'BEGIN s1\nEND s1\nDONE\n' > "$DIRECTOR_STATE/runs/evt-0001.effect"; run recover
chk "crash after DONE before receipt: receipt written from the ledger, no relaunch" '[ "$(cnt director-run launch.log)" = 1 ] && [ -e $DIRECTOR_STATE/runs/evt-0001.receipt.json ]'

# canonical API malformed / unavailable: explicit durable incident, no fallback, recoverable
fresh 17; touch "$STUB/garbage"; ev "$M x"; run
chk "malformed canonical output: no claim, no launch, state canonical-unavailable" '[ ! -e $STUB/launch.log ] && [ "$(cnt "asks claim" calls.log)" = 0 ] && grep -q "\"state\": \"canonical-unavailable\"" $DIRECTOR_STATE/runs/evt-0001.json'
chk "malformed canonical output: durable incident row says malformed" 'grep -q malformed $DIRECTOR_STATE/incidents.jsonl'
rm "$STUB/garbage"; touch "$STUB/down"; run recover; run recover
chk "unavailable canonical: durable incident row says unavailable, not duplicated per tick" 'grep -q unavailable $DIRECTOR_STATE/incidents.jsonl && [ "$(grep -c "\"event_id\": \"evt-0001\"" $DIRECTOR_STATE/incidents.jsonl)" -le 2 ] && [ ! -e $STUB/launch.log ]'
rm "$STUB/down"; run recover
chk "canonical back: one claim, one launch, no TSV fallback read" '[ "$(cnt director-run launch.log)" = 1 ] && [ "$(cnt "asks claim" calls.log)" = 1 ]'

# exact task-revision mismatch still blocks
fresh 18
python3 - <<PY
import json,os
p=os.environ["STUB"]+"/db.json"; d=json.load(open(p)); d["A100"]["ready"]=True; json.dump(d,open(p,"w"))
PY
touch "$STUB/hold"; run recover
python3 - <<PY
import json,os
p=os.environ["STUB"]+"/db.json"; d=json.load(open(p)); d["A100"]["rev"]=4; d["A100"]["ready"]=False; json.dump(d,open(p,"w"))
PY
rm "$STUB/hold"; run recover
chk "revision changed and ask no longer ready: superseded, no claim, no launch" 'grep -q "\"state\": \"superseded\"" $DIRECTOR_STATE/runs/ready-A100-3.json && [ "$(cnt "asks claim" calls.log)" = 0 ] && [ ! -e $STUB/launch.log ]'

# unchanged state
fresh 11; run recover
chk "recover on empty state dir: exit 0" 'python3 "$C" recover >/dev/null 2>&1'
before="$(cd $DIRECTOR_STATE && find . -type f ! -name '*.lock' ! -name '*.flock' -exec md5sum {} + | sort | md5sum)"
: > "$STUB/calls.log"; run recover
after="$(cd $DIRECTOR_STATE && find . -type f ! -name '*.lock' ! -name '*.flock' -exec md5sum {} + | sort | md5sum)"
chk "unchanged recover: no writes, no launches, no ledger writes" '[ "$before" = "$after" ] && [ ! -e $STUB/launch.log ] && [ "$(cnt "asks \(claim\|update\)" calls.log)" = 0 ]'

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
