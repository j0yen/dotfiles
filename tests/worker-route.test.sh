#!/usr/bin/env bash
# worker-route.test.sh: launch A -> retained terminal -> consumer action -> automatic successor B with no seat model turn,
# plus wrong-host, stale/reused identity, unavailable consumer, refused/failed worker, duplicate terminal, UNKNOWN effect.
# Source-only fixtures: a fake ask store (wm-asks stub over a json file), a fake child process, a fake START_CMD that runs the
# supervisor synchronously. No real wm-asks write, no event send, no tmux, no network, no claude. Fixtures do not prove installed behavior.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$HERE/.local/bin/worker-route.py"
WE="$HERE/tests/lib/worker-route-seamed.py"   # review 4: the route runs as a program only through the test harness (the production script has no seams); WR_SRC names the copy under test
. "$HERE/tests/scratch.sh"; T="$(wr_scratch)" || exit 64; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

mkdir -p "$T/bin" "$T/forbid"; rm -f "$T/forbidden.log"; WORLDS=0
# fake ask store: query (--ids/--status/--json), claim (--worker --by --expect-rev), update (--append). Never close/resolve.
cat > "$T/bin/wm-asks" <<'PY'
#!/usr/bin/env python3
import json, os, sys
S = os.environ["STUB"]
a = sys.argv[1:]
open(S + "/calls.log", "a").write(" ".join(a) + "\n")
if os.path.exists(S + "/down"): sys.stderr.write("ledger down\n"); sys.exit(3)
if os.path.exists(S + "/garbage"): print("not json {"); sys.exit(0)
db = json.load(open(S + "/db.json"))
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    rows = list(db.values())
    if "--ids" in a:
        i = a[a.index("--ids") + 1]; rows = [db[i]] if i in db else []
    if "--status" not in a or a[a.index("--status") + 1] != "all": rows = [r for r in rows if r.get("status", "open") == "open"]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker") + 1]; rev = int(a[a.index("--expect-rev") + 1]); by = a[a.index("--by") + 1]
    if os.path.exists(S + "/claimfail"): sys.stderr.write("transient claim failure\n"); sys.exit(1)
    own_stale = by == "worker-route" and str(r.get("claim") or "").startswith("wr-")   # fixture: worker-route may re-claim its own dead invocation's claim
    if r.get("claim") and r["claim"].split("@")[0] != w and not own_stale: sys.exit(1)
    if r["rev"] != rev: sys.exit(2)
    r["claim"] = w + "@2026-11-13T02:40"; r["rev"] += 1; save()
    if os.path.exists(S + "/dieafterclaim"): open(S + "/down", "w").close()   # the claim landed, the readback cannot be read
    sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append") + 1]); r["rev"] += 1; save(); sys.exit(0)
sys.stderr.write("fake wm-asks: unsupported " + " ".join(a) + "\n"); sys.exit(2)
PY
# fake child process: the "worker". Behaviour from files under $STUB: rc-<name>, effect-<name> (lines), noprov-<name>.
cat > "$T/bin/fake-coder" <<'SH'
#!/usr/bin/env bash
n="$1"; echo "$n WR_INVOCATION=${WR_INVOCATION:-} WR_NONCE=${WR_NONCE:+set}" >> "$STUB/child.log"
[ -e "$STUB/effect-$n" ] && cp "$STUB/effect-$n" "$WR_EFFECT_FILE"
[ -e "$STUB/noprov-$n" ] || printf '{"model":"claude-sonnet-5-5","effort":"medium","account":"acct-from-launcher","session":"sess-%s"}\n' "$n" > "$WR_PROVENANCE_FILE"
rc=0; [ -e "$STUB/rc-$n" ] && rc="$(cat "$STUB/rc-$n")"; exit "$rc"
SH
# START_CMD stub: <unit> <description> <cmd...>: records unit+description, runs the supervisor synchronously.
cat > "$T/bin/fake-start" <<'SH'
#!/usr/bin/env bash
echo "$1 :: $2" >> "$STUB/start.log"
[ -e "$STUB/startfail" ] && { echo "unit start refused" >&2; exit 9; }
[ -e "$STUB/noop" ] && exit 0
[ -e "$STUB/gone" ] && { echo "client lost the bus" >&2; exit 127; }
[ -e "$STUB/markeronly" ] && { inv="${1#worker-route-}"; mkdir -p "$WR_STATE/started"; echo '{}' > "$WR_STATE/started/$inv.json"; echo "client error after the supervisor began" >&2; exit 1; }
[ -e "$STUB/partial" ] && { shift 2; "$@" >/dev/null 2>&1; echo "Job for unit failed after the unit was admitted" >&2; exit 1; }
shift 2; exec "$@"
SH
cat > "$T/bin/hold" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/hold" ] && { echo held >&2; exit 1; }; exit 0
SH
# unit probe stub (the systemctl show seam, WR_UNIT_PROBE): LoadState/ActiveState for one unit; modes under $STUB: probe-down, unit-present
cat > "$T/bin/unitprobe" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/probe-down" ] && { echo "bus unreachable" >&2; exit 3; }
if [ -e "$STUB/unit-present" ]; then printf 'LoadState=loaded\nActiveState=active\n'; else printf 'LoadState=not-found\nActiveState=inactive\n'; fi
SH
# claim-API-conformant ask store (S/in/api: asks.py:211-232, cli.py:260-307): ANY existing claim (same worker too), a rev mismatch or a closed ask
# is Conflict -> rc 66, nothing mutated; Refused -> rc 2, nothing mutated; the claim COMMITS before the client prints, so a nonzero exit
# (75 committed-but-unpublished, 1 uncaught) or a kill/timeout can follow a committed claim. There is no release/resume verb.
# Modes (files under $STUB): readback-down, stale-rev, refuse2, after-commit-rc (N), no-print, down-after, hang-after-commit, lost-claim.
cat > "$T/bin/wm-asks-real" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
S = os.environ["STUB"]; a = sys.argv[1:]
open(S + "/calls.log", "a").write(" ".join(a) + "\n")
mode = lambda n: os.path.exists(S + "/" + n)
if a[:2] == ["asks", "query"] and mode("readback-down"): sys.stderr.write("ledger unreadable\n"); sys.exit(3)
db = json.load(open(S + "/db.json"))
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    rows = list(db.values())
    if "--ids" in a:
        i = a[a.index("--ids") + 1]; rows = [db[i]] if i in db else []
    if "--status" not in a or a[a.index("--status") + 1] != "all": rows = [r for r in rows if r.get("status", "open") == "open"]
    print(json.dumps(rows, sort_keys=True)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker") + 1]; rev = int(a[a.index("--expect-rev") + 1])
    if mode("lost-claim"): open(S + "/readback-down", "w").close(); sys.stderr.write("killed before commit\n"); sys.exit(1)
    if mode("refuse2"): sys.stderr.write("refused: --worker wants one token\n"); sys.exit(2)
    if mode("stale-rev"): r["rev"] += 1; save()
    if r["rev"] != rev: sys.stderr.write("conflict: rev\n"); sys.exit(66)
    if r.get("status") == "closed": sys.stderr.write("conflict: closed\n"); sys.exit(66)
    if r.get("claim"): sys.stderr.write("conflict: already claimed; no second claim\n"); sys.exit(66)
    r["claim"] = w + "@2026-11-13T04:00"; r["rev"] += 1; save()
    if mode("down-after"): open(S + "/readback-down", "w").close()
    if mode("hang-after-commit"): open(S + "/readback-down", "w").close(); time.sleep(30)
    if mode("after-commit-rc"): sys.exit(int(open(S + "/after-commit-rc").read()))
    if not mode("no-print"): print("claimed", a[2], w)
    sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append") + 1]); r["rev"] += 1; save(); sys.exit(0)
sys.stderr.write("fake wm-asks-real: unsupported " + " ".join(a) + "\n"); sys.exit(2)
PY
# anything that would be a seat model turn or an event send: must never run
for f in seat-event.sh seat-ask.sh tmux claude fable-launch.sh seat-tick.sh systemd-run systemctl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/forbidden.log"\nexit 0\n' "$f" "$T" > "$T/forbid/$f"; done
chmod 755 "$T"/bin/* "$T"/forbid/*

fresh(){ # new stub + state world; A1 (spec) -> B1 (waits_on A1)
  export STUB="$T/s$1" WR_STATE="$T/st$1"; WORLDS=$((WORLDS+1))
  rm -rf "$STUB" "$WR_STATE"; mkdir -p "$STUB"      # forbidden.log is NOT reset: one log covers every world
  cat > "$STUB/db.json" <<'J'
{"A1":{"ask_id":"A1","rev":4,"owner":"r7","status":"open","claim":null,"waits_on":[],"ready":true,"check":"c1",
       "what":"first task. worker-route: host=h1 launcher=fake-coder arg=a1 model=sonnet-5.5 effort=medium"},
 "B1":{"ask_id":"B1","rev":2,"owner":"r7","status":"open","claim":null,"waits_on":["A1"],"ready":false,"check":"c2",
       "what":"second task. worker-route: host=h1 launcher=fake-coder arg=b1 model=sonnet-5.5 effort=medium"},
 "X9":{"ask_id":"X9","rev":1,"owner":"rb","status":"open","claim":"other-worker@2026-11-13T01:00","waits_on":[],"ready":true,"check":"c",
       "what":"held by someone. worker-route: host=h1 launcher=fake-coder arg=x9"}}
J
  export WM_ASKS_CMD="$T/bin/wm-asks" WR_HOST=h1 WR_LAUNCHERS="fake-coder" WR_LAUNCHER_DIR="$T/bin" WR_START_CMD="$T/bin/fake-start" HOLD_GATE="$T/bin/hold"
  export WR_UNIT_PROBE="$T/bin/unitprobe" WR_ASKS_TIMEOUT=120
  export WR_TEST_SEAMS=1 WR_SELF="$WE" WR_SRC="$W"      # R3-3: env seams (state root, host, ask executable, ...) are honoured only with this explicit test switch
  export PATH="$T/forbid:$PATH"
  bindit
}
# the owner's binding of the ask entrypoint (canonical executable path + host + store), verified on every call (review R2-6)
bindit(){ python3 -I "$WE" bind --executable "$(readlink -f "$WM_ASKS_CMD")" --store "$STUB/db.json" --by test-owner >"$T/bind.out" 2>&1; }
real(){ export WM_ASKS_CMD="$T/bin/wm-asks-real"; bindit; }
run(){ python3 -I "$WE" "$@" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rcis(){ [ "$(cat "$T/rc.txt")" = "$1" ]; }
ran(){ [ -x "$W" ] && [ -f "$T/rc.txt" ] && ! grep -q "No such file" "$T/out.txt"; }   # the unit under test existed and was invoked: a negative never passes vacuously
calls(){ grep -c -- "$1" "$STUB/calls.log" 2>/dev/null || true; }
dec(){ grep -c -- "$1" "$WR_STATE/decisions.jsonl" 2>/dev/null || true; }
inv_of(){ python3 -I -c "import json,sys,glob;print([json.load(open(f))['invocation'] for f in sorted(glob.glob('$WR_STATE/launches/*.json')) if json.load(open(f))['ask']=='$1'][0])"; }
jget(){ python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],''))" "$1" "$2"; }

# ---- 0. the unit under test exists
chk "worker-route.py exists and is executable" '[ -x "$W" ]'

# ---- 1. happy path: launch A -> terminal -> consume -> automatic B, no seat model turn
fresh 1; run launch A1
chk "launch A: exit 0, claim written with the invocation worker, launch record before child" 'rcis 0 && [ "$(calls "asks claim A1 --worker wr-")" = 1 ] && ls "$WR_STATE"/launches/*.json >/dev/null'
IA="$(inv_of A1 2>/dev/null || echo none)"
chk "launch A: child ran once under the fake START (unit + description carry PREMISE and EXPIRY, no runtime cap)" '[ "$(grep -c . "$STUB/child.log")" = 1 ] && grep -q "PREMISE" "$STUB/start.log" && grep -q "EXPIRY" "$STUB/start.log" && ! grep -qi "RuntimeMax=[0-9]" "$STUB/start.log"'
chk "retained terminal for A written (rc 0, nonce echoed, host h1, actual provenance copied from the launcher)" '[ "$(jget "$WR_STATE/terminals/$IA.json" rc)" = 0 ] && [ "$(jget "$WR_STATE/terminals/$IA.json" host)" = h1 ] && grep -q acct-from-launcher "$WR_STATE/terminals/$IA.json"'
run consume
chk "consume: A receipt consumed; B claimed and launched automatically" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ] && grep -q "^b1 " "$STUB/child.log"'
chk "receipt copies launcher provenance verbatim (actual account), requested model kept separate" '[ "$(python3 -I -c "import json;d=json.load(open(\"$WR_STATE/consumed/$IA.json\"));print(d[\"provenance\"][\"account\"], d[\"requested\"][\"model\"])")" = "acct-from-launcher sonnet-5.5" ]'
run consume
IB="$(inv_of B1 2>/dev/null || echo none)"
chk "second consume: B terminal consumed, no further successor, no duplicate launch" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IB.json" state)" = consumed ] && [ "$(grep -c . "$STUB/child.log")" = 2 ]'
chk "NO seat model turn: no seat-event/seat-ask/tmux/claude/systemd-run call anywhere" '[ ! -s "$T/forbidden.log" ]'
chk "asks never closed/resolved/accepted by the route (only query, claim, update)" '! grep -qE "asks (close|resolve|accept|complete)" "$STUB/calls.log"'
chk "source has no seat model route (seat-event|seat-ask|tmux|claude -p)" '! grep -nE "seat-event|seat-ask|send-keys|claude -p" "$W" | grep -v "^[0-9]*:\s*#" | grep -v "^[0-9]*:.*never"'

# ---- 2. wrong host
fresh 2; [ -n "${WR_TEST_INJECT_FORBIDDEN:-}" ] && echo "injected seat-event.sh world2" >> "$T/forbidden.log"
python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["what"]=d["A1"]["what"].replace("host=h1","host=h2");json.dump(d,open(s,"w"))
P
run launch A1
chk "wrong host at launch: refused 79, no claim, no launch record, no child" 'ran && rcis 79 && [ "$(dec wrong-host)" -ge 1 ] && [ "$(calls "asks claim")" = 0 ] && [ ! -e "$WR_STATE/launches" -o -z "$(ls "$WR_STATE/launches" 2>/dev/null)" ] && [ ! -e "$STUB/child.log" ]'
fresh 2b; run launch A1; IA="$(inv_of A1)"
python3 -I - <<P
import json,os;p=os.environ["WR_STATE"]+"/terminals/$IA.json";d=json.load(open(p));d["host"]="h2";json.dump(d,open(p,"w"))
P
run consume
chk "terminal from another host: left unconsumed for that host, decision wrong-host, B not launched" 'ran && rcis 0 && [ ! -e "$WR_STATE/consumed/$IA.json" ] && [ "$(dec wrong-host)" -ge 1 ] && [ "$(calls "asks claim B1")" = 0 ]'

# ---- 3. stale / reused identity
fresh 3; run launch A1; IA="$(inv_of A1)"
python3 -I - <<P
import json,os;p=os.environ["WR_STATE"]+"/terminals/$IA.json";d=json.load(open(p));d["nonce"]="deadbeefdeadbeef";json.dump(d,open(p,"w"))
P
run consume
chk "wrong nonce (stale/forged terminal): refused stale-identity, B not launched, ask untouched" 'ran && rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec stale-identity)" -ge 1 ]'
fresh 3b; run launch A1; IA="$(inv_of A1)"
python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["claim"]="someone-else@2026-11-13T03:00";json.dump(d,open(s,"w"))
P
run consume
chk "claim re-owned by another worker before consume: refused claim-mismatch, B not launched" 'ran && rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec claim-mismatch)" -ge 1 ]'
fresh 3c; run launch A1; run launch A1
chk "reused identity: a second launch of A while its invocation is unconsumed is refused with exit 6 invocation-in-use, one child only" 'ran && rcis 6 && grep -q invocation-in-use "$WR_STATE/decisions.jsonl" && [ "$(grep -c . "$STUB/child.log")" = 1 ]'
fresh 3d; run launch X9
chk "ask already claimed by another worker: refused 5, original invocation keeps it, no launch" 'ran && rcis 5 && [ "$(dec claim-conflict)" = 1 ] && [ ! -e "$STUB/child.log" ]'

# ---- 4. unavailable consumer
fresh 4; run launch A1; touch "$STUB/down"; run consume
chk "ask store down at consume: exit 4, terminal stays pending, nothing launched" 'ran && rcis 4 && [ ! -e "$WR_STATE/consumed/$(inv_of A1).json" ] && [ "$(grep -c . "$STUB/child.log")" = 1 ] && [ "$(dec canonical-unavailable)" -ge 1 ]'
rm "$STUB/down"; run consume
chk "store back: the same terminal is consumed and B launches (no retry cap, no replay of A)" 'rcis 0 && [ "$(calls "asks claim B1 --worker wr-")" = 1 ] && [ "$(grep -c "^a1 " "$STUB/child.log")" = 1 ]'
fresh 4b; touch "$STUB/garbage"; run launch A1
chk "malformed ask store: launch refused 4, nothing started" 'ran && rcis 4 && [ "$(dec canonical-unavailable)" -ge 1 ] && [ ! -e "$STUB/child.log" ]'
fresh 4c; run launch A1; WR_LAUNCHERS="other-launcher" run consume
chk "successor launcher not allowlisted: A consumed, B stays unclaimed, decision consumer-unavailable" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$(inv_of A1).json" state)" = consumed ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec consumer-unavailable)" -ge 1 ]'
run consume
chk "launcher allowlisted again: B launches on the next consume" 'rcis 0 && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
fresh 4d; run launch A1; touch "$STUB/hold"; run consume
chk "quota hold gate closed: no successor launched, decision held; released -> launches" 'ran && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec held)" -ge 1 ]'
rm "$STUB/hold"; run consume
chk "hold released: B launches" '[ "$(calls "asks claim B1 --worker wr-")" = 1 ]'

# ---- 5. refused / failed worker
fresh 5; echo 1 > "$STUB/rc-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "failed worker (rc 1): state worker-failed, NO successor, ask still open with a note, nothing closed" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = worker-failed ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(calls "asks update A1")" = 1 ] && ! grep -qE "asks (close|resolve)" "$STUB/calls.log"'
fresh 5b; echo 78 > "$STUB/rc-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "refused worker (rc 78): state worker-refused, NO successor, terminal status refused" '[ "$(jget "$WR_STATE/consumed/$IA.json" state)" = worker-refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(jget "$WR_STATE/terminals/$IA.json" status)" = refused ]'
run consume; run consume
chk "failed/refused terminals are not retried or replayed by later consumes (one child total)" '[ "$(grep -c . "$STUB/child.log")" = 1 ]'
fresh 5c; echo 1 > "$STUB/rc-a1"; run launch A1; run consume; run consume; run consume
chk "duplicate failed terminal is processed once: one worker-failed decision, one ask note" 'ran && [ "$(dec worker-failed)" = 1 ] && [ "$(calls "asks update A1")" = 1 ]'

# ---- 6. duplicate terminal
fresh 6; run launch A1; IA="$(inv_of A1)"
python3 -I "$WE" supervise "$IA" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"
chk "second supervise of the same invocation does not overwrite the terminal; decision duplicate-terminal; child not rerun" '[ "$(jget "$WR_STATE/terminals/$IA.json" rc)" = 0 ] && [ "$(dec duplicate-terminal)" -ge 1 ] && [ "$(grep -c . "$STUB/child.log")" = 1 ]'
run consume; run consume; run consume
chk "consume x3 over one terminal: A consumed once, B claimed once, B launched once" '[ "$(calls "asks claim B1 --worker wr-")" = 1 ] && [ "$(grep -c "^b1 " "$STUB/child.log")" = 1 ]'

# ---- 7. UNKNOWN effect preserved
fresh 7; printf 'BEGIN push-branch\n' > "$STUB/effect-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "effect ledger has BEGIN without END: state unknown-effect, NO successor" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = unknown-effect ] && [ "$(calls "asks claim B1")" = 0 ]'
run consume; run consume
chk "UNKNOWN is reported once, not re-processed on each later consume (one unknown-effect decision)" 'ran && [ "$(dec unknown-effect)" = 1 ]'
chk "UNKNOWN is preserved across later consumes (never downgraded, B still not launched)" '[ "$(jget "$WR_STATE/consumed/$IA.json" state)" = unknown-effect ] && [ "$(calls "asks claim B1")" = 0 ]'
run reconcile "$IA" --verdict maybe --by r7
chk "reconcile with a bad verdict refused" '! rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = unknown-effect ]'
run reconcile "$IA" --verdict present --by owner-readback
chk "reconcile present (owner readback) releases the hold; effect ledger records END + RECONCILED" 'rcis 0 && grep -q "END push-branch" "$WR_STATE/effects/$IA.effect" && grep -q "RECONCILED present by owner-readback" "$WR_STATE/effects/$IA.effect"'
run consume
chk "after reconcile the next consume proceeds: A consumed, B launched once" '[ "$(jget "$WR_STATE/consumed/$IA.json" state)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'

# ---- 8. provenance: missing launcher provenance is recorded unrecorded, never inferred
fresh 8; touch "$STUB/noprov-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "launcher wrote no provenance: receipt says unrecorded, no account inferred" 'grep -q unrecorded "$WR_STATE/consumed/$IA.json" && ! grep -q acct-from-launcher "$WR_STATE/consumed/$IA.json"'

# ---- 10. failed-before-start is terminal and relaunchable (review F1); UNKNOWN still blocks
nrec(){ ls "$WR_STATE"/launches/*.json 2>/dev/null | wc -l; }
fresh 10; touch "$STUB/claimfail"; run launch A1
chk "transient claim failure: exit 5, decision claim-failed, no child, no claim held" 'ran && rcis 5 && [ "$(dec claim-failed)" = 1 ] && [ ! -e "$STUB/child.log" ] && [ "$(python3 -I -c "import json;print(json.load(open(\"$STUB/db.json\"))[\"A1\"][\"claim\"])")" = None ]'
IF="$(inv_of A1 2>/dev/null || echo none)"
chk "claim-failed record is a FINAL receipt of its own carrying the failure decision (visible in history)" '[ "$(jget "$WR_STATE/consumed/$IF.json" state)" = claim-failed ] && [ "$(jget "$WR_STATE/launches/$IF.json" state)" = claim-failed ]'
rm "$STUB/claimfail"; run launch A1
chk "store recovered: the ask relaunches under a NEW invocation id (not rc 6), child runs once, history keeps the failed record" 'ran && rcis 0 && [ "$(nrec)" = 2 ] && [ "$(grep -c . "$STUB/child.log")" = 1 ] && [ "$(dec claim-failed)" = 1 ] && [ "$(jget "$WR_STATE/consumed/$IF.json" state)" = claim-failed ] && ! grep -q "$IF" "$STUB/child.log"'
run consume
chk "after the relaunch the successor chain still completes (A consumed, B launched once)" 'rcis 0 && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
fresh 10b; touch "$STUB/startfail"; run launch A1
chk "start failure: exit 1, decision start-failed, no child" 'ran && rcis 1 && [ "$(dec start-failed)" = 1 ] && [ ! -e "$STUB/child.log" ]'
IF="$(inv_of A1 2>/dev/null || echo none)"
chk "start-failed record is FINAL (receipt state start-failed), not an open invocation" '[ "$(jget "$WR_STATE/consumed/$IF.json" state)" = start-failed ]'
rm "$STUB/startfail"; run launch A1
chk "start recovered: relaunch under a NEW invocation id re-claims the dead invocation claim, child runs once" 'ran && rcis 0 && [ "$(nrec)" = 2 ] && [ "$(grep -c . "$STUB/child.log")" = 1 ] && grep -q "claim A1 --worker wr-A1-[0-9]*-[0-9a-f]* " "$STUB/calls.log" && [ "$(jget "$WR_STATE/consumed/$IF.json" state)" = start-failed ]'
fresh 10c; touch "$STUB/dieafterclaim"; run launch A1
chk "claim landed but readback unreadable: exit 4, record state claim-unknown, reported UNKNOWN, no child" 'ran && rcis 4 && [ "$(dec claim-unknown)" = 1 ] && [ ! -e "$STUB/child.log" ]'
IU="$(inv_of A1 2>/dev/null || echo none)"
rm "$STUB/down" "$STUB/dieafterclaim"; run launch A1
chk "UNKNOWN still blocks: relaunch refused 6 invocation-in-use, never silently retried (one claim call, no child, record not final)" 'ran && rcis 6 && [ "$(calls "asks claim A1")" = 1 ] && [ ! -e "$STUB/child.log" ] && [ ! -e "$WR_STATE/consumed/$IU.json" ] && [ "$(jget "$WR_STATE/launches/$IU.json" state)" = claim-unknown ]'

# ---- 11. partial waits_on never launches a successor (review F4)
fresh 11; python3 -I - <<'PYEOF'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s))
d["B1"]["waits_on"]=["A1","Z9"]; d["Z9"]={"ask_id":"Z9","rev":1,"owner":"r7","status":"open","claim":None,"waits_on":[],"what":"unrelated open dependency, no spec"}
json.dump(d,open(s,"w"))
PYEOF
run launch A1; run consume; run consume
chk "B waits_on [A1,Z9]: A consumed but Z9 is not, so B is never claimed or launched" 'ran && [ "$(jget "$WR_STATE/consumed/$(inv_of A1).json" state)" = consumed ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(grep -c . "$STUB/child.log")" = 1 ]'

# ---- 12. supervise re-validates the launcher at execution time (review F6)
fresh 12; touch "$STUB/noop"; printf '#!/usr/bin/env bash\ntouch "%s/evil.ran"\n' "$T" > "$T/evil"; chmod 755 "$T/evil"; rm -f "$T/evil.ran"
run launch A1; IT="$(inv_of A1)"
T_EVIL="$T/evil" python3 -I - <<PYEOF
import json,os;p=os.environ["WR_STATE"]+"/launches/$IT.json";d=json.load(open(p));d["launcher"]=os.environ["T_EVIL"];json.dump(d,open(p,"w"))
PYEOF
python3 -I "$WE" supervise "$IT" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"
chk "tampered launch record (launcher outside the allowlist): supervise refuses, the planted program never runs" 'ran && [ ! -e "$T/evil.ran" ] && [ "$(jget "$WR_STATE/terminals/$IT.json" status)" = refused ] && [ "$(jget "$WR_STATE/terminals/$IT.json" rc)" = 78 ] && [ "$(dec launcher-not-allowed)" = 1 ]'
run consume
chk "the refusal flows to a worker-refused receipt, no successor" '[ "$(jget "$WR_STATE/consumed/$IT.json" state)" = worker-refused ] && [ "$(calls "asks claim B1")" = 0 ]'

# ======== review 2 (R2-1..R2-8): same-owner repair 2. Real claim API semantics (wm-asks-real: rc 66/2/75, commit-before-print, no release),
# ======== partial start / readback failure per the safety addendum, explicit resume, entrypoint binding. Fixtures are source-only.
lclaim(){ python3 -I -c "import json,sys;print(json.load(open('$STUB/db.json'))['$1']['claim'] or '')"; }
lstate(){ jget "$WR_STATE/launches/$1.json" state; }
cstate(){ jget "$WR_STATE/consumed/$1.json" state 2>/dev/null; }
nochild(){ [ ! -s "$STUB/child.log" ]; }
nchild(){ grep -c . "$STUB/child.log" 2>/dev/null || true; }

# ---- 13. R2-1 partial start: the start client fails AFTER the unit/child ran; that is never a FINAL start-failed
fresh 13; real; touch "$STUB/partial"; run launch A1; IP="$(inv_of A1 2>/dev/null || echo none)"
chk "partial start (client returns 1 after the supervisor ran): reconciled as started, exit 0, receipt NOT start-failed, one child, terminal kept" 'ran && rcis 0 && [ "$(cstate $IP)" != start-failed ] && [ "$(dec start-failed)" = 0 ] && [ "$(nchild)" = 1 ] && [ -f "$WR_STATE/terminals/$IP.json" ]'
rm "$STUB/partial"; run launch A1
chk "relaunch after the partial start: refused 6 invocation-in-use, still one child and one claim (no second worker)" 'ran && rcis 6 && [ "$(nchild)" = 1 ] && [ "$(calls "asks claim A1")" = 1 ]'
run consume
chk "the terminal that followed the partial start is consumed, not dropped: A consumed, B launched" 'rcis 0 && [ "$(cstate $IP)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
fresh 13b; real; touch "$STUB/partial"; printf 'BEGIN deploy\n' > "$STUB/effect-a1"; run launch A1; IP="$(inv_of A1 2>/dev/null || echo none)"; run consume
chk "partial start whose child left BEGIN without END: the effect is surfaced UNKNOWN (unknown-effect), no successor" 'ran && [ "$(cstate $IP)" = unknown-effect ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec unknown-effect)" = 1 ]'
fresh 13c; real; touch "$STUB/startfail"; run launch A1; IL="$(inv_of A1 2>/dev/null || echo none)"
chk "exact no-start proof (client refused, unit absent, no marker/terminal/effect): FINAL start-failed, exit 1, no child" 'ran && rcis 1 && [ "$(cstate $IL)" = start-failed ] && [ "$(dec start-failed)" = 1 ] && nochild'
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];r=json.load(open(w+"/launches/$IL.json"))
t={"invocation":"$IL","nonce":r["nonce"],"ask":"A1","host":"h1","rc":0,"status":"ok","effect":"x","provenance":"unrecorded","started":"s","ended":"e"}
json.dump(t,open(w+"/terminals/$IL.json","w"))
P
run consume
chk "a terminal that arrives AFTER a start-failed FINAL is preserved (file intact), surfaced UNKNOWN as late-terminal, receipt not overwritten, no successor" 'ran && [ -f "$WR_STATE/terminals/$IL.json" ] && [ "$(cstate $IL)" = start-failed ] && [ "$(dec late-terminal)" = 1 ] && [ -f "$WR_STATE/consumed/$IL.late-terminal.json" ] && [ "$(calls "asks claim B1")" = 0 ]'
rm "$STUB/startfail"; run launch A1
chk "relaunch refused while a late terminal exists (the unit did run): claim-conflict 5, no new child, claim kept" 'ran && rcis 5 && nochild && [ "$(calls "asks claim A1")" = 1 ]'
fresh 14; real; touch "$STUB/gone" "$STUB/probe-down"; run launch A1; IG="$(inv_of A1 2>/dev/null || echo none)"
chk "start client lost (127) and the unit cannot be inspected: UNKNOWN, exit 7, record start-unknown, NO final receipt, UNKNOWN decision, no child" 'ran && rcis 7 && [ "$(lstate $IG)" = start-unknown ] && [ ! -e "$WR_STATE/consumed/$IG.json" ] && [ "$(dec start-unknown)" = 1 ] && nochild'
run launch A1
chk "UNKNOWN start blocks: relaunch refused 6, still one claim call" 'ran && rcis 6 && [ "$(calls "asks claim A1")" = 1 ] && nochild'
run resume "$IG" --by owner
chk "resume while the unit is still not inspectable: stays UNKNOWN (exit 7), no child, no final receipt" 'ran && rcis 7 && [ "$(lstate $IG)" = start-unknown ] && [ ! -e "$WR_STATE/consumed/$IG.json" ] && nochild'
rm "$STUB/probe-down"; run resume "$IG" --by owner
chk "resume after the exact no-start proof (unit inspected: absent; no marker/terminal/effect): FINAL start-failed with the proof, exit 1" 'ran && rcis 1 && [ "$(cstate $IG)" = start-failed ] && grep -q no-start-proven "$WR_STATE/consumed/$IG.json"'
rm "$STUB/gone"; run launch A1; IR="$(ls "$WR_STATE"/launches | grep -v "$IG" | sed 's/.json//' | head -1)"
chk "retry after the proof under REAL claim semantics (no second claim is possible): the held claim is adopted, exit 0, ONE claim call, claim holder unchanged, one child, no release" 'ran && rcis 0 && [ "$(calls "asks claim A1")" = 1 ] && [ "$(nchild)" = 1 ] && case "$(lclaim A1)" in "$IG"@*) true;; *) false;; esac && ! grep -qE "release|unclaim|clear" "$STUB/calls.log"'
run consume
chk "the adopted invocation completes: A consumed (claim readback = adopted holder), B launched" 'rcis 0 && [ "$(cstate $IR)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
fresh 14b; real; touch "$STUB/gone" "$STUB/unit-present"; run launch A1; IQ="$(inv_of A1 2>/dev/null || echo none)"
chk "client error but the unit EXISTS (inspected: present): reconciled started, exit 0, state launched, not FINAL" 'ran && rcis 0 && [ "$(lstate $IQ)" = launched ] && [ ! -e "$WR_STATE/consumed/$IQ.json" ] && [ "$(dec start-failed)" = 0 ]'
fresh 14c; real; printf "#!/bin/sh\n" > "$T/not-exec"; chmod 644 "$T/not-exec"; export WR_START_CMD="$T/not-exec"; run launch A1; IM="$(inv_of A1 2>/dev/null || echo none)"
chk "start client not executable (OSError, the client never ran) with the unit absent: proven no-start, FINAL start-failed, exit 1" 'ran && rcis 1 && [ "$(cstate $IM)" = start-failed ]'
fresh 14e; real; touch "$STUB/markeronly"; run launch A1; IK="$(inv_of A1 2>/dev/null || echo none)"
chk "client error after ONLY the supervisor marker exists (no terminal, effect or provenance yet; unit already collected = absent): started evidence, not FINAL, no second worker" 'ran && rcis 0 && [ "$(lstate $IK)" = launched ] && [ ! -e "$WR_STATE/consumed/$IK.json" ] && [ "$(dec start-failed)" = 0 ]'
fresh 14f; real; touch "$STUB/startfail"; run launch A1; IL="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"
python3 -I "$WE" supervise "$IL" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"
chk "a supervisor that starts late for an invocation already FINAL start-failed runs NO child and writes no terminal or marker (supervise-after-final)" 'ran && rcis 0 && nochild && [ ! -e "$WR_STATE/terminals/$IL.json" ] && [ ! -e "$WR_STATE/started/$IL.json" ] && [ "$(dec supervise-after-final)" = 1 ]'
fresh 14d; real; printf "#!/bin/sh\n" > "$T/not-exec"; chmod 644 "$T/not-exec"; export WR_START_CMD="$T/not-exec"; touch "$STUB/probe-down"; run launch A1; IM="$(inv_of A1 2>/dev/null || echo none)"
chk "start client not executable AND unit not inspectable: UNKNOWN, not FINAL" 'ran && rcis 7 && [ "$(lstate $IM)" = start-unknown ] && [ ! -e "$WR_STATE/consumed/$IM.json" ]'

# ---- 15. R2-3 timeout / exit 127 after a committed claim is never "nothing happened"
fresh 15; real; touch "$STUB/hang-after-commit"; WR_ASKS_TIMEOUT=1 run launch A1; IT="$(inv_of A1 2>/dev/null || echo none)"
chk "claim client TIMEOUT after the claim committed, readback down: claim-unknown (not FINAL claim-failed), exit 4, no child, ledger claim kept" 'ran && rcis 4 && [ "$(lstate $IT)" = claim-unknown ] && [ ! -e "$WR_STATE/consumed/$IT.json" ] && [ "$(dec claim-failed)" = 0 ] && [ "$(dec claim-unknown)" = 1 ] && [ -n "$(lclaim A1)" ] && nochild'
rm "$STUB/hang-after-commit" "$STUB/readback-down"; run launch A1
chk "later launch: refused 6 invocation-in-use (not claim-conflict 5), one claim call" 'ran && rcis 6 && [ "$(calls "asks claim A1")" = 1 ] && nochild'

# ---- 16. R2-4 claim-unknown has a convergent resume path (readback against the canonical store), neither wedged nor double-launched
fresh 16; real; touch "$STUB/down-after"; run launch A1; IC="$(inv_of A1 2>/dev/null || echo none)"
chk "claim committed, readback down: claim-unknown, exit 4" 'ran && rcis 4 && [ "$(lstate $IC)" = claim-unknown ]'
run resume "$IC" --by owner
chk "resume while the ledger is still unreadable: stays claim-unknown, exit 4, no claim call, no child" 'ran && rcis 4 && [ "$(lstate $IC)" = claim-unknown ] && [ "$(calls "asks claim A1")" = 1 ] && nochild'
rm "$STUB/readback-down" "$STUB/down-after"; run resume "$IC" --by owner
chk "resume once readback proves THIS invocation holds the claim: the same invocation starts (no second claim, no release), one child, exit 0" 'ran && rcis 0 && [ "$(calls "asks claim A1")" = 1 ] && [ "$(nchild)" = 1 ] && [ "$(lstate $IC)" = launched ]'
run consume
chk "the resumed invocation completes: A consumed, B launched" 'rcis 0 && [ "$(cstate $IC)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
run resume "$IC" --by owner; R1=$(cat "$T/rc.txt")
chk "resume of an invocation whose terminal is already consumed (receipt FINAL) is refused (3), nothing restarted" '[ "$R1" = 3 ] && [ "$(nchild)" = 2 ] && [ "$(calls "asks claim")" = 2 ]'
fresh 16b; real; touch "$STUB/lost-claim"; run launch A1; IL="$(inv_of A1 2>/dev/null || echo none)"
chk "claim client killed before commit and readback down: claim-unknown, exit 4" 'ran && rcis 4 && [ "$(lstate $IL)" = claim-unknown ]'
rm "$STUB/lost-claim" "$STUB/readback-down"; run resume "$IL" --by owner
chk "readback proves the claim never landed: FINAL claim-failed, exit 5, no child" 'ran && rcis 5 && [ "$(cstate $IL)" = claim-failed ] && nochild && [ -z "$(lclaim A1)" ]'
run launch A1
chk "the ask is then relaunchable under a new invocation with a fresh claim" 'ran && rcis 0 && [ "$(nchild)" = 1 ] && [ "$(calls "asks claim A1")" = 2 ]'
fresh 16c; real; touch "$STUB/down-after"; run launch A1; IO="$(inv_of A1 2>/dev/null || echo none)"
rm "$STUB/readback-down" "$STUB/down-after"
python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["claim"]="other-worker@2026-11-13T05:00";json.dump(d,open(s,"w"))
P
run resume "$IO" --by owner
chk "claim is now held by another worker: FINAL claim-failed, no start, the other claim untouched" 'ran && rcis 5 && [ "$(cstate $IO)" = claim-failed ] && nochild && [ "$(lclaim A1)" = "other-worker@2026-11-13T05:00" ]'
run resume "$IO" --by owner; R1=$(cat "$T/rc.txt"); run resume wr-A1-4-deadbeef --by owner; R2=$(cat "$T/rc.txt"); run resume "$IO"; R3=$(cat "$T/rc.txt")
chk "resume refuses a FINAL invocation (3), an unknown invocation (3) and a missing --by (3)" '[ "$R1" = 3 ] && [ "$R2" = 3 ] && [ "$R3" = 3 ]'

# ---- 17. R2-5 real claim exit codes and the commit-before-print window
fresh 17; real; touch "$STUB/stale-rev"; run launch A1; IV="$(inv_of A1 2>/dev/null || echo none)"
chk "rev mismatch (real rc 66, pre-commit): FINAL claim-failed, exit 5, no child, claim not held" 'ran && rcis 5 && [ "$(cstate $IV)" = claim-failed ] && nochild && [ -z "$(lclaim A1)" ]'
rm "$STUB/stale-rev"; run launch A1
chk "after the rev settles the ask relaunches with a fresh claim (exit 0, one child)" 'ran && rcis 0 && [ "$(nchild)" = 1 ]'
fresh 17b; real; touch "$STUB/refuse2"; run launch A1; IV="$(inv_of A1 2>/dev/null || echo none)"
chk "Refused (real rc 2, pre-commit): FINAL claim-failed, exit 5, no child, claim not held" 'ran && rcis 5 && [ "$(cstate $IV)" = claim-failed ] && nochild && [ -z "$(lclaim A1)" ]'
fresh 17c; real; echo 75 > "$STUB/after-commit-rc"; run launch A1; IV="$(inv_of A1 2>/dev/null || echo none)"
chk "claim committed then client exits 75 (committed-but-unpublished), readback readable: proceeds on the readback identity, one claim, one child" 'ran && rcis 0 && [ "$(calls "asks claim A1")" = 1 ] && [ "$(nchild)" = 1 ] && [ "$(dec claim-failed)" = 0 ]'
fresh 17d; real; echo 1 > "$STUB/after-commit-rc"; run launch A1
chk "claim committed then client exits 1 (uncaught after commit), readback readable: proceeds, one child" 'ran && rcis 0 && [ "$(nchild)" = 1 ] && [ "$(dec claim-failed)" = 0 ]'
fresh 17e; real; touch "$STUB/no-print"; run launch A1
chk "claim committed, output lost (commit-before-print), exit 0: proceeds on the readback, one child" 'ran && rcis 0 && [ "$(nchild)" = 1 ]'
fresh 17f; real; echo 75 > "$STUB/after-commit-rc"; touch "$STUB/down-after"; run launch A1; IV="$(inv_of A1 2>/dev/null || echo none)"
chk "claim committed, exit 75 AND readback down: claim-unknown (never success, never nothing-happened), exit 4, no child" 'ran && rcis 4 && [ "$(lstate $IV)" = claim-unknown ] && [ "$(dec claim-failed)" = 0 ] && nochild'
fresh 17g; real; run launch A1; run launch A1
chk "no implicit release: a second launch over the held claim never issues another claim, release or clear (one claim call)" 'ran && rcis 6 && [ "$(calls "asks claim A1")" = 1 ] && ! grep -qiE "release|unclaim|clear" "$STUB/calls.log"'

# ---- 18. R2-6 the ask entrypoint is bound: canonical executable path + sha256 + host + store, verified on every launch/consume/resume
fresh 18; rm -f "$WR_STATE/asks-binding.json"; run launch A1
chk "no binding: launch refused 77 asks-unbound, no ask-store call at all, no child" 'ran && rcis 77 && [ ! -s "$STUB/calls.log" ] && nochild && [ "$(dec asks-unbound)" -ge 1 ]'
fresh 18b; cp "$T/bin/wm-asks" "$T/bin/asks-copy"; export WM_ASKS_CMD="$T/bin/asks-copy"; bindit; echo "# tampered after binding" >> "$T/bin/asks-copy"; run launch A1
chk "executable changed after binding (sha256 mismatch): refused 77, no ask-store call, no child" 'ran && rcis 77 && [ ! -s "$STUB/calls.log" ] && nochild'
fresh 18c; cp "$T/bin/wm-asks" "$T/bin/asks-decoy"; export WM_ASKS_CMD="$T/bin/asks-decoy"; run launch A1
chk "a different executable than the bound one (decoy path): refused 77" 'ran && rcis 77 && [ ! -s "$STUB/calls.log" ] && nochild'
fresh 18d; mkdir -p "$T/decoybin"; cp "$T/bin/wm-asks" "$T/decoybin/wm-asks"; WM_ASKS_CMD="" PATH="$T/decoybin:$PATH" run launch A1
chk "no WM_ASKS_CMD and a decoy wm-asks first on PATH (default resolution): refused 77, the PATH name is never trusted" 'ran && rcis 77 && [ ! -s "$STUB/calls.log" ] && nochild'
fresh 18e; python3 -I - <<'P'
import json,os;p=os.environ["WR_STATE"]+"/asks-binding.json";d=json.load(open(p));d["host"]="h2";json.dump(d,open(p,"w"))
P
run launch A1
chk "binding made for another host: refused 77" 'ran && rcis 77 && [ ! -s "$STUB/calls.log" ] && nochild'
fresh 18f; cp "$STUB/db.json" "$STUB/db.new"; rm "$STUB/db.json"; mv "$STUB/db.new" "$STUB/db.json"; run launch A1
chk "bound store replaced by a different file (device/inode changed): refused 77" 'ran && rcis 77 && nochild'
fresh 18g; run consume
R1=$(cat "$T/rc.txt"); rm -f "$WR_STATE/asks-binding.json"; run consume; R2=$(cat "$T/rc.txt"); run resume wr-A1-4-deadbeef --by o; R3=$(cat "$T/rc.txt")
chk "consume and resume refuse an unbound entrypoint too (77), consume with the binding is fine (0)" '[ "$R1" = 0 ] && [ "$R2" = 77 ] && [ "$R3" = 77 ]'
fresh 18h; B0="$(sha256sum "$WR_STATE/asks-binding.json" 2>/dev/null)"; run bind --executable "$T/bin/hold" --store "$STUB/db.json" --by o; R1=$(cat "$T/rc.txt"); run bind --executable "$(readlink -f "$WM_ASKS_CMD")" --store "$T/no-such-store" --by o; R2=$(cat "$T/rc.txt")
chk "bind refuses an executable that is not the one WM_ASKS_CMD resolves to (non-zero), and a missing store (non-zero); the binding file is unchanged" 'ran && [ "$R1" != 0 ] && [ "$R2" != 0 ] && [ -n "$B0" ] && [ "$B0" = "$(sha256sum "$WR_STATE/asks-binding.json")" ]'

# ---- 19. R2-7 the nonce can contain a1/b1: counts anchor on the child name, so the suite is deterministic. Run the happy path against a copy whose nonce always starts a1b1
sed 's/os.urandom(8).hex()/"a1b1" + os.urandom(6).hex()/' "$W" > "$T/wr-nonce.py"; chmod 755 "$T/wr-nonce.py"; W0="$W"; W="$T/wr-nonce.py"; export WR_SRC="$W"
fresh 19; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; run consume; run consume
W="$W0"; export WR_SRC="$W"
chk "forced a1b1 nonces: invocation ids really contain a1b1 and the chain still counts exactly (A once, B once, each claimed once)" 'case "$IA" in wr-A1-4-a1b1*) true;; *) false;; esac && [ "$(grep -c "^a1 " "$STUB/child.log")" = 1 ] && [ "$(grep -c "^b1 " "$STUB/child.log")" = 1 ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ] && [ "$(calls "asks claim A1 --worker wr-")" = 1 ]'

# ---- 20. R2-8 only the claim holder's OWN start-failed invocation of THIS ask may be adopted
fresh 20; python3 -I - <<'P'
import json,os;w=os.environ["WR_STATE"];s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["claim"]="wr-B1-9-deadbeef@2026-11-13T01:00";json.dump(d,open(s,"w"))
inv="wr-B1-9-deadbeef"
os.makedirs(w+"/launches",exist_ok=True);os.makedirs(w+"/consumed",exist_ok=True)
json.dump({"invocation":inv,"ask":"B1","host":"h1","nonce":"n","worker":inv,"state":"start-failed"},open(w+"/launches/"+inv+".json","w"))
json.dump({"invocation":inv,"state":"start-failed","ask":"B1","consumer":"worker-route"},open(w+"/consumed/"+inv+".json","w"))
P
run launch A1
chk "A1 is claimed by a start-failed invocation of ANOTHER ask (B1): claim-conflict 5, never adopted, no child" 'ran && rcis 5 && [ "$(dec claim-conflict)" = 1 ] && nochild && [ "$(dec adopt)" = 0 ]'

# ---- 25. R3-5 the forbidden-call list covers systemctl (the default unit-probe client): a world that forgets the unit-probe seam would be caught, shown by a positive control
mkdir -p "$T/forbid-ctl"; printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s/forbidden-ctl.log"\nexit 0\n' "$T" > "$T/forbid-ctl/systemctl"; chmod 755 "$T/forbid-ctl/systemctl"
fresh 25a; real; touch "$STUB/startfail"; PATH="$T/forbid-ctl:$PATH" WR_UNIT_PROBE="" run launch A1
chk "R3-5: with no unit-probe seam the default probe is the stubbed systemctl (positive control: the forbid stub sees 'systemctl --user show ... worker-route-'), and the global forbidden log stays clean" 'ran && grep -q "systemctl --user show --property=LoadState,ActiveState worker-route-" "$T/forbidden-ctl.log" && [ -x "$T/forbid/systemctl" ] && [ ! -s "$T/forbidden.log" ]'

# ---- 21. R3-1 chain-aware adoption: a held claim is adopted only while EVERY invocation that ever carried its token is a proven no-start; after a run,
# a failure or a late terminal no second adopter may adopt it (review 3 own_probes2.py x1-x3, source cf32/5f6eb3d: adoption read only the claim-holder token's record)
export T
chain_prefix(){ # A start-failed (proven no-start) -> B adopts the held claim; leaves IA IB
  touch "$STUB/startfail"; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"; run launch A1
  IB="$(ls -t "$WR_STATE"/launches | sed 's/.json//' | grep -v "$IA" | head -1)"; }
fresh 21a; real; chain_prefix
chk "x0 control: A start-failed, B adopts the held claim (exit 0, one child, one claim call)" 'ran && rcis 0 && [ "$(lstate $IB)" = launched ] && [ "$(nchild)" = 1 ] && [ "$(calls "asks claim A1")" = 1 ]'
run consume; run launch A1
chk "x1 R3-1: B ran to completion and was consumed: a later launch is claim-conflict 5, NO second worker (one child, one adoption)" 'ran && rcis 5 && [ "$(grep -c "^a1 " "$STUB/child.log")" = 1 ] && [ "$(dec adopt-failed-start-claim)" = 1 ] && [ "$(cstate $IB)" = consumed ]'
fresh 21b; real; echo 1 > "$STUB/rc-a1"; chain_prefix; run consume; run launch A1
chk "x2 R3-1: B worker-failed: a later launch is claim-conflict 5 (owner decides), NO relaunch, one child" 'ran && rcis 5 && [ "$(cstate $IB)" = worker-failed ] && [ "$(nchild)" = 1 ] && [ "$(dec adopt-failed-start-claim)" = 1 ]'
fresh 21c; real; touch "$STUB/startfail"; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; run launch A1
IB="$(ls -t "$WR_STATE"/launches | sed 's/.json//' | grep -v "$IA" | head -1)"
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];r=json.load(open(w+"/launches/$IB.json"))
t={"invocation":"$IB","nonce":r["nonce"],"ask":"A1","host":"h1","rc":0,"status":"ok","effect":"x","provenance":"unrecorded","started":"s","ended":"e"}
json.dump(t,open(w+"/terminals/$IB.json","w"))
P
run consume; rm "$STUB/startfail"; run launch A1
chk "x3 R3-1: B FINAL start-failed then B's late terminal (the unit ran): C does not adopt: claim-conflict 5, no child" 'ran && rcis 5 && [ "$(cstate $IB)" = start-failed ] && [ -f "$WR_STATE/consumed/$IB.late-terminal.json" ] && nochild'
fresh 21d; real; touch "$STUB/startfail"; run launch A1; run launch A1; rm "$STUB/startfail"; run launch A1
chk "x4 positive control: A and B both proven no-start (chain all start-failed, no evidence): C adopts the same held claim, one child, still ONE claim call" 'ran && rcis 0 && [ "$(nchild)" = 1 ] && [ "$(calls "asks claim A1")" = 1 ] && [ "$(dec adopt-failed-start-claim)" = 2 ]'
fresh 21e; real; touch "$STUB/startfail"; run launch A1; rm "$STUB/startfail"; touch "$STUB/noop"; run launch A1; run launch A1
chk "x5 an adopter whose unit was admitted (no terminal yet) blocks a third launch: invocation-in-use 6, one adoption, no child yet" 'ran && rcis 6 && [ "$(dec adopt-failed-start-claim)" = 1 ] && nochild'
fresh 21f; real; touch "$STUB/startfail"; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];r=json.load(open(w+"/launches/$IA.json"));r["host"]="h2";json.dump(r,open(w+"/launches/$IA.json","w"))
P
run launch A1
chk "x6 R3-2 (mutant o6): the adopted invocation belongs to ANOTHER host: adoption refused claim-conflict 5, no child" 'ran && rcis 5 && nochild && [ "$(dec adopt-failed-start-claim)" = 0 ]'

fresh 21g; real; touch "$STUB/startfail"; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];p=w+"/consumed/$IA.json";r=json.load(open(p));r["state"]="worker-failed";json.dump(r,open(p,"w"))
P
run launch A1
chk "x7 chain member whose FINAL receipt is not start-failed (even with no run evidence on disk): claim-conflict 5, never adopted" 'ran && rcis 5 && nochild && [ "$(dec adopt-failed-start-claim)" = 0 ]'
fresh 21h; real; touch "$STUB/startfail"; run launch A1; IA="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];p=w+"/consumed/$IA.json";r=json.load(open(p));r["ask"]="B1";json.dump(r,open(p,"w"))
P
run launch A1
chk "x8 the claimant's start-failed receipt names ANOTHER ask: claim-conflict 5, never adopted" 'ran && rcis 5 && nochild && [ "$(dec adopt-failed-start-claim)" = 0 ]'

# ---- 22. R3-2 host guards (reviewer mutants o9, o10): resume is same-host only; start evidence for another host's invocation is UNKNOWN, never absence
fresh 22a; real; touch "$STUB/down-after"; run launch A1; IC="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/readback-down" "$STUB/down-after"
python3 -I - <<P
import json,os;w=os.environ["WR_STATE"];r=json.load(open(w+"/launches/$IC.json"));r["host"]="h2";json.dump(r,open(w+"/launches/$IC.json","w"))
P
run resume "$IC" --by owner
chk "o9: resume of an invocation recorded on ANOTHER host: resume-refused 3, record unchanged (claim-unknown), no claim call, no child" 'ran && rcis 3 && [ "$(lstate $IC)" = claim-unknown ] && [ "$(calls "asks claim A1")" = 1 ] && nochild && [ "$(dec resume-refused)" = 1 ]'
fresh 22b
chk "o10: start_evidence of an invocation recorded on another host is 'unknown' even when the local unit probe says absent (no foreign absence proof)" '[ "$(WR_TEST_SEAMS=1 python3 -I -c "
import importlib.util,sys
sp=importlib.util.spec_from_file_location(\"wr\",sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
print(m.start_evidence({\"invocation\":\"wr-A1-4-deadbeef\",\"host\":\"h2\",\"unit\":\"worker-route-wr-A1-4-deadbeef\"}))" "$W")" = unknown ]'

# ---- 23. R3-3 the binding is not forgeable through the environment, and calls exec the VERIFIED realpath
chk "R3-3a: env cannot redirect state, host, executable or binding without the explicit test switch (module constants with WR_STATE/WR_HOST/WM_ASKS_CMD/WR_ASKS_BINDING forged)" '[ "$(env -u WR_TEST_SEAMS WR_STATE=/forged/state WR_HOST=forged-host WM_ASKS_CMD=/forged/asks WR_ASKS_BINDING=/forged/binding.json HOME=/forged/home python3 -I -c "
import importlib.util,sys
sp=importlib.util.spec_from_file_location(\"wr\",sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
print(\"forged\" if any(\"forged\" in str(x) for x in (m.STATE,m.HOST,m.ASKS_CMD,m.BINDING)) else \"clean\")" "$W")" = clean ]'
chk "R3-3b: even with the test switch an env var cannot name another BINDING file (the binding is always <state>/asks-binding.json)" '[ "$(WR_TEST_SEAMS=1 WR_STATE=/x/state WR_ASKS_BINDING=/forged/binding.json python3 -I -c "
import importlib.util,sys
sp=importlib.util.spec_from_file_location(\"wr\",sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
print(m.BINDING)" "$W")" = /x/state/asks-binding.json ]'
fresh 23a; mkdir -p "$T/xreal"; sed 's|^open(S + "/calls.log", "a")|open(S + "/argv0.log", "a").write(sys.argv[0] + "\\n"); open(S + "/calls.log", "a")|' "$T/bin/wm-asks-real" > "$T/xreal/wm-asks-x"; chmod 755 "$T/xreal/wm-asks-x"; ln -s "$T/xreal/wm-asks-x" "$T/xlink"
export WM_ASKS_CMD="$T/xlink"; python3 -I "$WE" bind --executable "$(readlink -f "$T/xlink")" --store "$STUB/db.json" --by test-owner >"$T/bind.out" 2>&1; run launch A1
chk "R3-3c: calls exec the verified realpath, not the PATH/symlink name that was checked (argv[0] of every ask call is the bound realpath)" 'ran && rcis 0 && [ "$(sort -u "$STUB/argv0.log")" = "$(readlink -f "$T/xlink")" ] && [ "$(wc -l < "$STUB/argv0.log")" -ge 3 ]'
fresh 23b; chmod 666 "$STUB/db.json"; run bind --executable "$(readlink -f "$WM_ASKS_CMD")" --store "$STUB/db.json" --by o; R1=$(cat "$T/rc.txt"); chmod 644 "$STUB/db.json"
cp "$T/bin/wm-asks" "$T/bin/asks-gw"; chmod 777 "$T/bin/asks-gw"; export WM_ASKS_CMD="$T/bin/asks-gw"; run bind --executable "$T/bin/asks-gw" --store "$STUB/db.json" --by o; R2=$(cat "$T/rc.txt")
chk "R3-3d: bind refuses a world-writable store and a world-writable executable (non-zero), nothing bound" 'ran && [ "$R1" != 0 ] && [ "$R2" != 0 ]'

chk "R3-3e: an executable that changes AFTER verification is never executed (sha256 re-read immediately before the exec): asks_call returns 127 and the changed program does not run" '[ "$(WR_TEST_SEAMS=1 python3 -I -c "
import importlib.util,sys,os,hashlib
sp=importlib.util.spec_from_file_location(\"wr\",sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
x=sys.argv[2]+\"/chg\";open(x,\"w\").write(\"#!/bin/sh\necho ok\n\");os.chmod(x,0o755)
m._VERIFIED.update(exe=x,sha=m.file_sha(x))
a=m.asks_call(\"asks\",\"query\")[0]
open(x,\"a\").write(\"touch \"+sys.argv[2]+\"/ran\n\")
b=m.asks_call(\"asks\",\"query\")[0]
print(a,b,os.path.exists(sys.argv[2]+\"/ran\"))" "$W" "$T")" = "0 127 False" ]'

mkdir -p "$T/forbid-ctl"; : > "$T/forbidden-ctl.log"
chk "R3-3f: without the test switch an env WR_UNIT_PROBE cannot replace the unit probe (the default systemctl client is called, the forged probe is not)" '[ "$(env -u WR_TEST_SEAMS WR_UNIT_PROBE=/forged/probe PATH="$T/forbid-ctl:$PATH" python3 -I -c "
import importlib.util,sys
sp=importlib.util.spec_from_file_location(\"wr\",sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
print(m.unit_probe(\"worker-route-wr-A1-4-deadbeef\"))" "$W")" = unknown ] && grep -q "systemctl --user show" "$T/forbidden-ctl.log"'

# ---- 24. R3-4 an absence read once is not proof later; a late admission is handled, never dropped
fresh 24a; real; touch "$STUB/startfail"; run launch A1; rm "$STUB/startfail"; touch "$STUB/unit-present"; run launch A1
chk "R3-4a: the unit of the start-failed invocation APPEARS after the proof (late admission): adoption re-reads it, refuses (5), no child" 'ran && rcis 5 && nochild && [ "$(dec adopt-failed-start-claim)" = 0 ] && [ "$(dec adopt-blocked)" = 1 ]'
fresh 24b; real; touch "$STUB/startfail"; run launch A1; rm "$STUB/startfail"; touch "$STUB/probe-down"; run launch A1
chk "R3-4b: unit not inspectable at adoption time: UNKNOWN, refused 7, no child, the earlier absence is not reused" 'ran && rcis 7 && nochild && [ "$(dec adopt-blocked)" = 1 ]'
rm "$STUB/probe-down"; run launch A1
chk "R3-4c: once the unit is inspected absent again, adoption proceeds (exit 0, one child, one claim call)" 'ran && rcis 0 && [ "$(nchild)" = 1 ] && [ "$(calls "asks claim A1")" = 1 ]'
fresh 24d; real; touch "$STUB/startfail"; run launch A1; IL="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/startfail"
python3 -I - "$WR_STATE" "$IL" "$WE" "$STUB" "$T/bin/fake-start" <<'P'
import fcntl, os, subprocess, sys, time, json
st, inv, w, stub, _ = sys.argv[1:6]
lk = open(st + "/locks/start-" + inv + ".lock", "a"); fcntl.flock(lk, fcntl.LOCK_EX)     # a finish_start decision is in progress for this invocation
p = subprocess.Popen([sys.executable, "-I", w, "supervise", inv], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1.5)
blocked = p.poll() is None and not os.path.exists(st + "/started/" + inv + ".json")
fcntl.flock(lk, fcntl.LOCK_UN); p.wait(timeout=30)
open(os.environ["T"] + "/r3-4d.txt", "w").write("blocked=%s rc=%s child=%s marker=%s\n" % (blocked, p.returncode, os.path.exists(stub + "/child.log"), os.path.exists(st + "/started/" + inv + ".json")))
P
chk "R3-4d: a supervisor and a start-failed finalization are serialized on one per-invocation lock: the supervisor waits for the in-progress decision (no marker while it is held), then sees the FINAL receipt and runs no child" 'grep -q "blocked=True rc=0 child=False marker=False" "$T/r3-4d.txt"'
fresh 24e; real; touch "$STUB/gone" "$STUB/probe-down"; run launch A1; IG="$(inv_of A1 2>/dev/null || echo none)"; rm "$STUB/gone" "$STUB/probe-down"
python3 -I - "$WR_STATE" "$IG" "$WE" <<'P'
import fcntl, os, subprocess, sys, time, json
st, inv, w = sys.argv[1:4]
lk = open(st + "/locks/start-" + inv + ".lock", "a"); fcntl.flock(lk, fcntl.LOCK_EX)     # a supervisor is between its start marker and its child
p = subprocess.Popen([sys.executable, "-I", w, "resume", inv, "--by", "owner"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1.5)
blocked = p.poll() is None
json.dump({"invocation": inv}, open(st + "/started/" + inv + ".json", "w"))                 # the marker appears while the lock is held
fcntl.flock(lk, fcntl.LOCK_UN); p.wait(timeout=30)
open(os.environ["T"] + "/r3-4e.txt", "w").write("blocked=%s rc=%s\n" % (blocked, p.returncode))
P
chk "R3-4e: resume of a start-unknown waits for an in-progress supervisor start and then reads its marker: started (exit 0), NOT FINAL start-failed" 'grep -q "blocked=True rc=0" "$T/r3-4e.txt" && [ "$(lstate $IG)" = launched ] && [ ! -e "$WR_STATE/consumed/$IG.json" ]'

# ---- 26. R3-6 the ask API calls bind to the supported source (in/api claim-api-source.json: cli.py:260-307, asks.py:211-232); a shape the source does not give is UNKNOWN, never assumed
fresh 26a; real; run launch A1; run consume
chk "R3-6a: every ask-store call uses only flags/verbs the supported source defines (query --json --ids --status; claim --worker --by --expect-rev; update --append); no release/resume/close verb" 'ran && ! grep -vE "^asks (query --json( --ids [A-Za-z0-9]+)?( --status (all|open))?|claim [A-Za-z0-9]+ --worker wr-[A-Za-z0-9-]+ --by worker-route --expect-rev [0-9]+|update [A-Za-z0-9]+ --append .*)$" "$STUB/calls.log" | grep -q .'
fresh 26b; real; python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s))
for r in d.values(): r.pop("claim",None)
json.dump(d,open(s,"w"))
P
run launch A1
chk "R3-6b: query rows with NO claim key (shape not given by the source): the whole read is UNKNOWN (canonical-shape-unverified, exit 4), nothing claimed, no launch record, no child" 'ran && rcis 4 && [ "$(calls "asks claim")" = 0 ] && [ "$(dec canonical-shape-unverified)" -ge 1 ] && [ -z "$(ls "$WR_STATE/launches" 2>/dev/null)" ] && nochild'
fresh 26c; real; python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s))
for r in d.values(): r.pop("waits_on",None)
json.dump(d,open(s,"w"))
P
run launch A1; run consume
chk "R3-6c: rows with NO waits_on key: no successor is ever started (dependency unknown), the decision says so, A itself is consumed" 'ran && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec waits-on-unverified)" -ge 1 ] && [ "$(cstate $(inv_of A1))" = consumed ]'

# ---- 9. final: no seat route anywhere across all worlds
chk "no forbidden (seat/tmux/claude/systemd-run) call in any world (one log for all $WORLDS worlds)" '[ -x "$W" ] && [ "$WORLDS" -ge 20 ] && [ ! -s "$T/forbidden.log" ]'

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
