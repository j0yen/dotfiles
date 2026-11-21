#!/usr/bin/env bash
# director-event-consumer-own-claim-rerun.test.sh (A1299, E15 R6): the row's OWN completed consumer run still HOLDS the ledger claim.
# The real ledger never releases a claim (asks.py claim(): "no second claim"; no release path), so every fixture here keeps
# db.json claim = the worker name the consumer itself wrote; claim is never set to null. Stubs and helpers are copied from
# director-event-consumer.test.sh with two ledger-fidelity edits, marked "FIDELITY" below.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="$HERE/.local/bin/director-event-consumer.py"
mkdir -p "$HOME/.cache/director-scratch"; T="$(mktemp -d "$HOME/.cache/director-scratch/t.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fails=0; passes=0
ok(){ echo "PASS $1"; passes=$((passes+1)); }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

cat > "$T/wm-asks" <<'PY'
#!/usr/bin/env python3
import json, os, sys
S = os.environ["STUB"]
open(S + "/calls.log", "a").write(" ".join(sys.argv[1:]) + "\n")
if os.path.exists(S + "/down"): sys.stderr.write(open(S + "/down").read()); sys.exit(3)
if os.path.exists(S + "/down-ready") and "--ready" in sys.argv: sys.stderr.write(open(S + "/down-ready").read()); sys.exit(3)
if os.path.exists(S + "/garbage"): print("not json {"); sys.exit(0)
db = json.load(open(S + "/db.json"))
a = sys.argv[1:]
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    rows = list(db.values())
    if "--ids" in a: rows = [db[a[a.index("--ids")+1]]] if a[a.index("--ids")+1] in db else []
    if "--status" not in a or a[a.index("--status")+1] != "all": rows = [r for r in rows if r.get("status", "open") == "open"]
    # FIDELITY 1: readiness is the ledger's own flag; a held claim does not hide a ready row (the consumer decides what the claim means)
    if "--ready" in a: rows = [r for r in rows if r.get("ready") and r["owner"] == "hermes"]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker")+1]
    # FIDELITY 2: asks.py claim() refuses ANY second claim ("already claimed ... no second claim"), even by the same worker name
    if r.get("claim"): sys.exit(1)
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
chmod 755 "$T"/wm-asks "$T"/launcher "$T"/hold "$T"/active

fresh(){ # new stub + state world; A200 starts UNCLAIMED, not ready, rev 4; A100 is a separate row for the foreign-run control
  export STUB="$T/s$1" DIRECTOR_STATE="$T/st$1" DIRECTOR_EVENTS_LOG="$T/ev$1.log"
  rm -rf "$STUB" "$DIRECTOR_STATE"; mkdir -p "$STUB"; : > "$DIRECTOR_EVENTS_LOG"
  echo '{"A100":{"ask_id":"A100","rev":3,"owner":"hermes","status":"open","claim":null,"ready":false,"what":"w","check":"c"},
         "A200":{"ask_id":"A200","rev":4,"owner":"hermes","status":"open","claim":null,"ready":false,"what":"w","check":"c"}}' > "$STUB/db.json"
  export WM_ASKS_CMD="$T/wm-asks" DIRECTOR_LAUNCH_CMD="$T/launcher" HOLD_GATE="$T/hold" DIRECTOR_ACTIVE_CMD="$T/active"
  export DIRECTOR_HERMES_CMD=/bin/false
}
run(){ python3 "$C" "$@" >"$T/out.txt" 2>&1; }
cnt(){ local n; n="$(grep -c -- "$1" "$STUB/$2" 2>/dev/null)"; echo "${n:-0}"; }
ev(){ echo "2026-11-08T01:00:00-08:00 | hermes | $1" >> "$DIRECTOR_EVENTS_LOG"; }

# set fields on a ledger row WITHOUT touching claim unless the caller names it: sets A200 '{"rev":6,"ready":true}'
sets(){ python3 - "$1" "$2" <<'PY'
import json, os, sys
p = os.environ["STUB"] + "/db.json"; d = json.load(open(p)); d[sys.argv[1]].update(json.loads(sys.argv[2])); json.dump(d, open(p, "w"))
PY
}
claim_of(){ python3 -c 'import json,os,sys; print(json.load(open(os.environ["STUB"]+"/db.json"))[sys.argv[1]]["claim"])' "$1"; }
# complete a run through the consumer's own complete command (receipt + state=completed; the ledger claim is left as written)
done_run(){ printf 'BEGIN s1\nEND s1\nDONE\n' > "$DIRECTOR_STATE/runs/$1.effect"; python3 "$C" complete "$1" --effect "$DIRECTOR_STATE/runs/$1.effect" >/dev/null 2>&1; }
# world: A200 ready at rev 5 with binding B1 closed, claimed + launched + completed by its OWN consumer run ready-A200-5
own_completed(){
  fresh "$1"; sets A200 '{"ready":true,"rev":5,"bindings":[{"id":"B1","closed":true}]}'; run recover
  done_run ready-A200-5
  W5="director-ready-A200-5.c0"
  R5="$(cat $DIRECTOR_STATE/runs/ready-A200-5.receipt.json)"; J5="$(cat $DIRECTOR_STATE/runs/ready-A200-5.json)"
}

# ---- precondition: the fixture really is the real-ledger state (claim held by the own completed run, never null)
own_completed 1
chk "setup: own run ready-A200-5 launched once and completed, receipt written" '[ "$(cnt director-run-ready-A200-5-a1 launch.log)" = 1 ] && grep -q "\"state\": \"completed\"" $DIRECTOR_STATE/runs/ready-A200-5.json && [ -e $DIRECTOR_STATE/runs/ready-A200-5.receipt.json ]'
chk "setup: ledger claim is still the consumer-written own worker (bare stub form $W5), not null" '[ "$(claim_of A200)" = "$W5" ]'

# ---- case 1: newly satisfied closes-after binding set at a new revision, claim STILL HELD => exactly one fresh run per set
sets A200 '{"rev":6,"ready":true,"bindings":[{"id":"B1","closed":true},{"id":"B2","closed":true}]}'; run recover
chk "case1a: new binding set at rev 6 with the own claim held => exactly one run for ready-A200-6" '[ "$(cnt director-run-ready-A200-6 launch.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 2 ]'
chk "case1a: the ledger claim is unchanged, still the original own worker (the real ledger refuses a second claim)" '[ "$(claim_of A200)" = "$W5" ]'
chk "case1a: rev-5 receipt and run file untouched, ready-A200-5 never relaunched" '[ "$(cat $DIRECTOR_STATE/runs/ready-A200-5.receipt.json)" = "$R5" ] && [ "$(cat $DIRECTOR_STATE/runs/ready-A200-5.json)" = "$J5" ] && [ "$(cnt director-run-ready-A200-5 launch.log)" = 1 ]'
run recover; run recover
chk "case1a: repeated recover at rev 6 still one run" '[ "$(cnt director-run launch.log)" = 2 ]'
done_run ready-A200-6
sets A200 '{"rev":7,"ready":true,"bindings":[{"id":"B1","closed":true},{"id":"B2","closed":true},{"id":"B3","closed":true}]}'; run recover
chk "case1b: a later satisfied set at rev 7 => one more run (ready-A200-7), three total, earlier keys never relaunched" '[ "$(cnt director-run-ready-A200-7 launch.log)" = 1 ] && [ "$(cnt director-run launch.log)" = 3 ] && [ "$(cnt director-run-ready-A200-5 launch.log)" = 1 ] && [ "$(cnt director-run-ready-A200-6 launch.log)" = 1 ] && [ "$(cat $DIRECTOR_STATE/runs/ready-A200-5.receipt.json)" = "$R5" ]'

# ---- case 2: a NEW director-action event key for the row, claim held by the own completed run => exactly one run for that key
own_completed 2
sets A200 '{"ready":false,"rev":6}'; ev "DIRECTOR-ACTION ask=A200 event=evt-0300 follow-up"; run
chk "case2: new event key evt-0300 => exactly one run (director-run-evt-0300), not claim-conflict" '[ "$(cnt director-run-evt-0300 launch.log)" = 1 ] && ! grep -q "claim-conflict" $DIRECTOR_STATE/runs/evt-0300.json'
run; run recover
chk "case2: duplicate delivery and recover add no second run for evt-0300; rev-5 artefacts untouched" '[ "$(cnt director-run-evt-0300 launch.log)" = 1 ] && [ "$(cnt director-run-ready-A200-5 launch.log)" = 1 ] && [ "$(cat $DIRECTOR_STATE/runs/ready-A200-5.receipt.json)" = "$R5" ]'

# ---- case 3: a revision with NO new binding and no event => nothing starts (no claim call, no launch)
own_completed 3
: > "$STUB/calls.log"; sets A200 '{"rev":6,"ready":false}'; run recover; run recover
chk "case3: non-binding revision (ready stays false) => no claim call, no launch" '[ "$(cnt "asks claim" calls.log)" = 0 ] && [ "$(cnt director-run launch.log)" = 1 ]'
sets A200 '{"rev":7}'; run recover
chk "case3: a further bare revision => still nothing; one launch total, own receipt untouched" '[ "$(cnt "asks claim" calls.log)" = 0 ] && [ "$(cnt director-run launch.log)" = 1 ] && [ "$(cat $DIRECTOR_STATE/runs/ready-A200-5.receipt.json)" = "$R5" ]'

# ---- case 4a: claim held by a LIVE (not completed) run => no new run (ask-busy)
fresh 4; sets A200 '{"ready":true,"rev":5}'; run recover; touch "$STUB/active"
sets A200 '{"rev":6,"bindings":[{"id":"B2","closed":true}]}'; ev "DIRECTOR-ACTION ask=A200 event=evt-0300 follow-up"; run; run recover
chk "case4a: live own run (state launched, not completed) holds the claim => no second run, one launch total" '[ "$(cnt director-run launch.log)" = 1 ] && [ "$(cnt director-run-evt-0300 launch.log)" = 0 ] && [ "$(cnt director-run-ready-A200-6 launch.log)" = 0 ]'
chk "case4a: the event waits as ask-busy" 'grep -q "\"state\": \"ask-busy\"" $DIRECTOR_STATE/runs/evt-0300.json'

# ---- case 4b: claim held by a worker that is NOT this row's own completed consumer run => claim-conflict / no run
fresh 5; sets A200 '{"claim":"someone-else@x","ready":true,"rev":6,"bindings":[{"id":"B2","closed":true}]}'
ev "DIRECTOR-ACTION ask=A200 event=evt-0300 follow-up"; run; run recover
chk "case4b: foreign claim someone-else@x => no run for the event or the ready key, claim-conflict" '[ ! -e $STUB/launch.log ] && grep -q "\"state\": \"claim-conflict\"" $DIRECTOR_STATE/runs/evt-0300.json'
fresh 6; ev "DIRECTOR-ACTION ask=A100 event=evt-0001 x"; run; done_run evt-0001
sets A200 '{"claim":"director-evt-0001.c0","ready":true,"rev":6,"bindings":[{"id":"B2","closed":true}]}'
ev "DIRECTOR-ACTION ask=A200 event=evt-0300 follow-up"; run; run recover
chk "case4b: claim is another ask's COMPLETED consumer run (director-evt-0001.c0 belongs to A100) => not own, no run for A200" '[ "$(cnt director-run-evt-0300 launch.log)" = 0 ] && [ "$(cnt director-run-ready-A200 launch.log)" = 0 ] && grep -q "\"state\": \"claim-conflict\"" $DIRECTOR_STATE/runs/evt-0300.json'

echo "PASS=$passes FAIL=$fails"
[ "$fails" = 0 ]
