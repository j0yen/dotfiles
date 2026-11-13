"""Fake-world helpers for the seatrv2 probes (reviewer originals in S/in/review2-probes, copied and repointed at this clone; the unit-probe stub and the entrypoint binding are added so they run against the repaired route). Real claim semantics from in/claim-api-source.json (asks.py:211-232, cli.py:260-307):
claim refuses ANY existing claim (even same worker) with Conflict->rc 66 (also rev mismatch, closed); Refused->rc 2; commit happens
before print, so a nonzero exit can follow a committed claim. No systemd, no real wm-asks, no ledger."""
import importlib.util, io, json, os, sys, tempfile, contextlib, shutil, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.realpath(os.path.join(HERE, "..", "..", ".local", "bin", "worker-route.py"))        # repointed: this clone, not the reviewer's tree
BASE = os.environ.get("WR_PROBE_BASE") or tempfile.mkdtemp(prefix="wr-probes-")
os.makedirs(BASE, exist_ok=True)
FAKE_ASKS = r'''#!/usr/bin/env python3
import json, os, sys
S = os.environ["STUB"]; a = sys.argv[1:]
open(S + "/calls.log", "a").write(" ".join(a) + "\n")
mode = lambda n: os.path.exists(S + "/" + n)
db = json.load(open(S + "/db.json"))
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    if mode("readback-down"): sys.stderr.write("ledger unreadable\n"); sys.exit(3)
    rows = list(db.values())
    if "--ids" in a:
        i = a[a.index("--ids") + 1]; rows = [db[i]] if i in db else []
    if "--status" not in a or a[a.index("--status") + 1] != "all": rows = [r for r in rows if r.get("status", "open") == "open"]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker") + 1]; rev = int(a[a.index("--expect-rev") + 1])
    if r["rev"] != rev: sys.stderr.write("Conflict: rev\n"); sys.exit(66)
    if r.get("claim"): sys.stderr.write("Conflict: already claimed; no second claim\n"); sys.exit(66)   # REAL: any claim, even same worker
    r["claim"] = w + "@2026-11-13T04:00"; r["rev"] += 1; save()
    if mode("after-commit-rc"): sys.exit(int(open(S + "/after-commit-rc").read()))        # nonzero exit after the committed claim
    if mode("readback-down-after"): open(S + "/readback-down", "w").close()
    print("claimed", a[2], w); sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append") + 1]); r["rev"] += 1; save(); sys.exit(0)
sys.exit(2)
'''
FAKE_CODER = '#!/usr/bin/env bash\necho "$1 INV=$WR_INVOCATION" >> "$STUB/child.log"\nprintf \'{"model":"m"}\\n\' > "$WR_PROVENANCE_FILE"\nexit ${RC:-0}\n'
# fake start client. modes: startfail (refuse, nothing ran), partial (supervisor DID run, client then returns nonzero), late (child runs AFTER we return nonzero)
FAKE_START = r'''#!/usr/bin/env bash
echo "$1 :: $2" >> "$STUB/start.log"
unit="$1"; shift 2
if [ -e "$STUB/startfail" ]; then echo "Failed to connect to bus" >&2; exit 1; fi
if [ -e "$STUB/partial" ]; then "$@" >/dev/null 2>&1; echo "Job for unit failed (client error after admit)" >&2; exit 1; fi
if [ -e "$STUB/late" ]; then echo "$unit" > "$STUB/late.pending"; echo "$@" > "$STUB/late.cmd"; echo "timeout waiting for unit" >&2; exit 1; fi
exec "$@"
'''
# unit probe stub (WR_UNIT_PROBE): modes under $STUB: probe-down, unit-present; default = unit absent
UNIT_PROBE = r'''#!/usr/bin/env bash
[ -e "$STUB/probe-down" ] && { echo "bus unreachable" >&2; exit 3; }
if [ -e "$STUB/unit-present" ]; then printf 'LoadState=loaded\nActiveState=active\n'; else printf 'LoadState=not-found\nActiveState=inactive\n'; fi
'''
def bind(w):
    r = subprocess.run([sys.executable, "-I", SRC, "bind", "--executable", os.path.realpath(w + "/bin/wm-asks"), "--store", w + "/stub/db.json", "--by", "probe-owner"],
                       env=dict(os.environ), capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
def world(name, **env_extra):
    w = os.path.join(BASE, name); shutil.rmtree(w, ignore_errors=True); os.makedirs(w + "/bin"); os.makedirs(w + "/stub"); os.makedirs(w + "/home")
    for n, body in (("wm-asks", FAKE_ASKS), ("fake-coder", FAKE_CODER), ("fake-start", FAKE_START), ("hold", "#!/usr/bin/env bash\nexit 0\n"), ("unitprobe", UNIT_PROBE)):
        p = w + "/bin/" + n; open(p, "w").write(body); os.chmod(p, 0o755)
    db = {"A1": {"ask_id": "A1", "rev": 4, "owner": "r7", "status": "open", "claim": None, "waits_on": [], "what": "t. worker-route: host=h1 launcher=fake-coder arg=a1"}}
    json.dump(db, open(w + "/stub/db.json", "w"))
    env = dict(HOME=w + "/home", STUB=w + "/stub", WR_STATE=w + "/state", WM_ASKS_CMD=w + "/bin/wm-asks", WR_HOST="h1", WR_LAUNCHERS="fake-coder",
               WR_LAUNCHER_DIR=w + "/bin", WR_START_CMD=w + "/bin/fake-start", HOLD_GATE=w + "/bin/hold", WR_UNIT_PROBE=w + "/bin/unitprobe", WR_ASKS_TIMEOUT="120")
    env.update(env_extra); os.environ.update(env)
    os.makedirs(w + "/state", exist_ok=True)
    bind(w)
    return w
def load_mod():
    spec = importlib.util.spec_from_file_location("wr", SRC); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.ensure(); return m
def call(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(*a)
    return rc, [json.loads(l) for l in buf.getvalue().splitlines() if l.startswith("{")]
def flag(w, n, content=""): open(w + "/stub/" + n, "w").write(content)
def unflag(w, n):
    try: os.unlink(w + "/stub/" + n)
    except OSError: pass
def db(w): return json.load(open(w + "/stub/db.json"))
def children(w):
    try: return open(w + "/stub/child.log").read().splitlines()
    except OSError: return []
def receipts(w):
    out = {}
    for f in sorted(os.listdir(w + "/state/consumed")) if os.path.isdir(w + "/state/consumed") else []:
        j = json.load(open(w + "/state/consumed/" + f)); out[j["invocation"]] = j["state"]
    return out
def terminals(w):
    d = w + "/state/terminals"; return sorted(os.listdir(d)) if os.path.isdir(d) else []
