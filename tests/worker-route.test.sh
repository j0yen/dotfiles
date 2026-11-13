#!/usr/bin/env bash
# worker-route.test.sh: launch A -> retained terminal -> consumer action -> automatic successor B with no seat model turn,
# plus wrong-host, stale/reused identity, unavailable consumer, refused/failed worker, duplicate terminal, UNKNOWN effect.
# Source-only fixtures: a fake ask store (wm-asks stub over a json file), a fake child process, a fake START_CMD that runs the
# supervisor synchronously. No real wm-asks write, no event send, no tmux, no network, no claude. Fixtures do not prove installed behavior.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$HERE/.local/bin/worker-route.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

mkdir -p "$T/bin" "$T/forbid"
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
    r = db[a[2]]; w = a[a.index("--worker") + 1]; rev = int(a[a.index("--expect-rev") + 1])
    if r.get("claim") and r["claim"].split("@")[0] != w: sys.exit(1)
    if r["rev"] != rev: sys.exit(2)
    r["claim"] = w + "@2026-11-13T02:40"; r["rev"] += 1; save(); sys.exit(0)
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
echo "$1 :: $2" >> "$STUB/start.log"; shift 2; exec "$@"
SH
cat > "$T/bin/hold" <<'SH'
#!/usr/bin/env bash
[ -e "$STUB/hold" ] && { echo held >&2; exit 1; }; exit 0
SH
# anything that would be a seat model turn or an event send: must never run
for f in seat-event.sh seat-ask.sh tmux claude fable-launch.sh seat-tick.sh systemd-run; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/forbidden.log"\nexit 0\n' "$f" "$T" > "$T/forbid/$f"; done
chmod 755 "$T"/bin/* "$T"/forbid/*

fresh(){ # new stub + state world; A1 (spec) -> B1 (waits_on A1)
  export STUB="$T/s$1" WR_STATE="$T/st$1"
  rm -rf "$STUB" "$WR_STATE" "$T/forbidden.log"; mkdir -p "$STUB"
  cat > "$STUB/db.json" <<'J'
{"A1":{"ask_id":"A1","rev":4,"owner":"r7","status":"open","claim":null,"waits_on":[],"ready":true,"check":"c1",
       "what":"first task. worker-route: host=h1 launcher=fake-coder arg=a1 model=sonnet-5.5 effort=medium"},
 "B1":{"ask_id":"B1","rev":2,"owner":"r7","status":"open","claim":null,"waits_on":["A1"],"ready":false,"check":"c2",
       "what":"second task. worker-route: host=h1 launcher=fake-coder arg=b1 model=sonnet-5.5 effort=medium"},
 "X9":{"ask_id":"X9","rev":1,"owner":"rb","status":"open","claim":"other-worker@2026-11-13T01:00","waits_on":[],"ready":true,"check":"c",
       "what":"held by someone. worker-route: host=h1 launcher=fake-coder arg=x9"}}
J
  export WM_ASKS_CMD="$T/bin/wm-asks" WR_HOST=h1 WR_LAUNCHERS="fake-coder" WR_LAUNCHER_DIR="$T/bin" WR_START_CMD="$T/bin/fake-start" HOLD_GATE="$T/bin/hold"
  export PATH="$T/forbid:$PATH"
}
run(){ python3 -I "$W" "$@" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"; }
rcis(){ [ "$(cat "$T/rc.txt")" = "$1" ]; }
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
chk "consume: A receipt consumed; B claimed and launched automatically" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = consumed ] && [ "$(calls "asks claim B1 --worker wr-")" = 1 ] && grep -q "b1" "$STUB/child.log"'
chk "receipt copies launcher provenance verbatim (actual account), requested model kept separate" '[ "$(python3 -I -c "import json;d=json.load(open(\"$WR_STATE/consumed/$IA.json\"));print(d[\"provenance\"][\"account\"], d[\"requested\"][\"model\"])")" = "acct-from-launcher sonnet-5.5" ]'
run consume
IB="$(inv_of B1 2>/dev/null || echo none)"
chk "second consume: B terminal consumed, no further successor, no duplicate launch" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IB.json" state)" = consumed ] && [ "$(grep -c . "$STUB/child.log")" = 2 ]'
chk "NO seat model turn: no seat-event/seat-ask/tmux/claude/systemd-run call anywhere" '[ ! -s "$T/forbidden.log" ]'
chk "asks never closed/resolved/accepted by the route (only query, claim, update)" '! grep -qE "asks (close|resolve|accept|complete)" "$STUB/calls.log"'
chk "source has no seat model route (seat-event|seat-ask|tmux|claude -p)" '! grep -nE "seat-event|seat-ask|send-keys|claude -p" "$W" | grep -v "^[0-9]*:\s*#" | grep -v "^[0-9]*:.*never"'

# ---- 2. wrong host
fresh 2; python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["what"]=d["A1"]["what"].replace("host=h1","host=h2");json.dump(d,open(s,"w"))
P
run launch A1
chk "wrong host at launch: refused 79, no claim, no launch record, no child" 'rcis 79 && [ "$(calls "asks claim")" = 0 ] && [ ! -e "$WR_STATE/launches" -o -z "$(ls "$WR_STATE/launches" 2>/dev/null)" ] && [ ! -e "$STUB/child.log" ]'
fresh 2b; run launch A1; IA="$(inv_of A1)"
python3 -I - <<P
import json,os;p=os.environ["WR_STATE"]+"/terminals/$IA.json";d=json.load(open(p));d["host"]="h2";json.dump(d,open(p,"w"))
P
run consume
chk "terminal from another host: left unconsumed for that host, decision wrong-host, B not launched" 'rcis 0 && [ ! -e "$WR_STATE/consumed/$IA.json" ] && [ "$(dec wrong-host)" -ge 1 ] && [ "$(calls "asks claim B1")" = 0 ]'

# ---- 3. stale / reused identity
fresh 3; run launch A1; IA="$(inv_of A1)"
python3 -I - <<P
import json,os;p=os.environ["WR_STATE"]+"/terminals/$IA.json";d=json.load(open(p));d["nonce"]="deadbeefdeadbeef";json.dump(d,open(p,"w"))
P
run consume
chk "wrong nonce (stale/forged terminal): refused stale-identity, B not launched, ask untouched" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec stale-identity)" -ge 1 ]'
fresh 3b; run launch A1; IA="$(inv_of A1)"
python3 -I - <<'P'
import json,os;s=os.environ["STUB"]+"/db.json";d=json.load(open(s));d["A1"]["claim"]="someone-else@2026-11-13T03:00";json.dump(d,open(s,"w"))
P
run consume
chk "claim re-owned by another worker before consume: refused claim-mismatch, B not launched" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec claim-mismatch)" -ge 1 ]'
fresh 3c; run launch A1; run launch A1
chk "reused identity: a second launch of A while its invocation is unconsumed is refused, one child only" '! rcis 0 && [ "$(grep -c . "$STUB/child.log")" = 1 ]'
fresh 3d; run launch X9
chk "ask already claimed by another worker: refused 5, original invocation keeps it, no launch" 'rcis 5 && [ ! -e "$STUB/child.log" ]'

# ---- 4. unavailable consumer
fresh 4; run launch A1; touch "$STUB/down"; run consume
chk "ask store down at consume: exit 4, terminal stays pending, nothing launched" 'rcis 4 && [ ! -e "$WR_STATE/consumed/$(inv_of A1).json" ] && [ "$(grep -c . "$STUB/child.log")" = 1 ] && [ "$(dec canonical-unavailable)" -ge 1 ]'
rm "$STUB/down"; run consume
chk "store back: the same terminal is consumed and B launches (no retry cap, no replay of A)" 'rcis 0 && [ "$(calls "asks claim B1 --worker wr-")" = 1 ] && [ "$(grep -c a1 "$STUB/child.log")" = 1 ]'
fresh 4b; touch "$STUB/garbage"; run launch A1
chk "malformed ask store: launch refused 4, nothing started" 'rcis 4 && [ ! -e "$STUB/child.log" ]'
fresh 4c; run launch A1; WR_LAUNCHERS="other-launcher" run consume
chk "successor launcher not allowlisted: A consumed, B stays unclaimed, decision consumer-unavailable" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$(inv_of A1).json" state)" = consumed ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(dec consumer-unavailable)" -ge 1 ]'
run consume
chk "launcher allowlisted again: B launches on the next consume" 'rcis 0 && [ "$(calls "asks claim B1 --worker wr-")" = 1 ]'
fresh 4d; run launch A1; touch "$STUB/hold"; run consume
chk "quota hold gate closed: no successor launched, decision held; released -> launches" '[ "$(calls "asks claim B1")" = 0 ] && [ "$(dec held)" -ge 1 ]'
rm "$STUB/hold"; run consume
chk "hold released: B launches" '[ "$(calls "asks claim B1 --worker wr-")" = 1 ]'

# ---- 5. refused / failed worker
fresh 5; echo 1 > "$STUB/rc-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "failed worker (rc 1): state worker-failed, NO successor, ask still open with a note, nothing closed" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = worker-failed ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(calls "asks update A1")" = 1 ] && ! grep -qE "asks (close|resolve)" "$STUB/calls.log"'
fresh 5b; echo 78 > "$STUB/rc-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "refused worker (rc 78): state worker-refused, NO successor, terminal status refused" '[ "$(jget "$WR_STATE/consumed/$IA.json" state)" = worker-refused ] && [ "$(calls "asks claim B1")" = 0 ] && [ "$(jget "$WR_STATE/terminals/$IA.json" status)" = refused ]'
run consume; run consume
chk "failed/refused terminals are not retried or replayed by later consumes (one child total)" '[ "$(grep -c . "$STUB/child.log")" = 1 ]'

# ---- 6. duplicate terminal
fresh 6; run launch A1; IA="$(inv_of A1)"
python3 -I "$W" supervise "$IA" >"$T/out.txt" 2>&1; echo $? > "$T/rc.txt"
chk "second supervise of the same invocation does not overwrite the terminal; decision duplicate-terminal; child not rerun" '[ "$(jget "$WR_STATE/terminals/$IA.json" rc)" = 0 ] && [ "$(dec duplicate-terminal)" -ge 1 ] && [ "$(grep -c . "$STUB/child.log")" = 1 ]'
run consume; run consume; run consume
chk "consume x3 over one terminal: A consumed once, B claimed once, B launched once" '[ "$(calls "asks claim B1 --worker wr-")" = 1 ] && [ "$(grep -c b1 "$STUB/child.log")" = 1 ]'

# ---- 7. UNKNOWN effect preserved
fresh 7; printf 'BEGIN push-branch\n' > "$STUB/effect-a1"; run launch A1; IA="$(inv_of A1)"; run consume
chk "effect ledger has BEGIN without END: state unknown-effect, NO successor" 'rcis 0 && [ "$(jget "$WR_STATE/consumed/$IA.json" state)" = unknown-effect ] && [ "$(calls "asks claim B1")" = 0 ]'
run consume; run consume
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

# ---- 9. final: no seat route anywhere across all worlds
chk "no forbidden (seat/tmux/claude/systemd-run) call in any world" '[ ! -s "$T/forbidden.log" ]'

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES: $fails"; exit 1; }
