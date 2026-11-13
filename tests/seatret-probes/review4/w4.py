"""Retained from the independent review-4 probes (S/in/review4-probes/w4.py, repointed at THIS clone: scratch from WR_PROBE_BASE, the program run through the test harness; modes flip-down / flip-vanish added for R4-3). seatrv4 own fake-world harness (independent of the author's fakes). Drives worker-route.py through its CLI; every world under R/tmp; no systemd/claim/ledger."""
import json, os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.realpath(HERE + "/../../..")
SRC = os.environ.get("WR_SRC") or REPO + "/.local/bin/worker-route.py"          # the copy under test (mutants set WR_SRC)
ENTRY = REPO + "/tests/lib/worker-route-seamed.py"                                    # review 4: programs run through the test harness (the production script has no seams)
BASE = os.environ["WR_PROBE_BASE"] + "/w4-" + os.environ.get("W4TAG", "head")     # scratch base from the test script, never /tmp
ASKS = r'''#!/usr/bin/env python3
import json, os, sys, time
S = os.environ["STUB"]; a = sys.argv[1:]
open(S + "/calls.log", "a").write(" ".join(a) + "\n")
m = lambda n: os.path.exists(S + "/" + n)
db = json.load(open(S + "/db.json"))
def save(): json.dump(db, open(S + "/db.json", "w"))
if a[:2] == ["asks", "query"]:
    if m("readback-down"): sys.stderr.write("ledger unreadable\n"); sys.exit(3)
    rows = list(db.values())
    if "--ids" in a:
        i = a[a.index("--ids") + 1]; rows = [db[i]] if i in db else []
    if "--status" not in a or a[a.index("--status") + 1] != "all": rows = [r for r in rows if r.get("status", "open") == "open"]
    if m("flip") or m("flip-down") or m("flip-vanish"):
        n = int(open(S + "/qn").read()) if m("qn") else 0; open(S + "/qn", "w").write(str(n + 1))
        if n >= 1 and "--ids" in a:
            if m("flip-down"): sys.stderr.write("ledger unreadable\n"); sys.exit(3)
            rows = [] if m("flip-vanish") else [dict(r, claim="other@t") for r in rows]
    if m("nokey-claim"): rows = [{k: v for k, v in r.items() if k != "claim"} for r in rows]
    if m("nokey-waits"): rows = [{k: v for k, v in r.items() if k != "waits_on"} for r in rows]
    print(json.dumps(rows)); sys.exit(0)
if a[:2] == ["asks", "claim"]:
    r = db[a[2]]; w = a[a.index("--worker") + 1]; rev = int(a[a.index("--expect-rev") + 1])
    if m("refuse2"): sys.stderr.write("refused\n"); sys.exit(2)
    if r["rev"] != rev: sys.exit(66)
    if r.get("claim"): sys.stderr.write("Conflict: already claimed\n"); sys.exit(66)
    r["claim"] = w + "@t"; r["rev"] += 1; save()
    if m("readback-down-after"): open(S + "/readback-down", "w").close()
    if m("after-commit-rc"): sys.exit(int(open(S + "/after-commit-rc").read()))
    print("claimed"); sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r["rev"] += 1; save(); sys.exit(0)
sys.exit(2)
'''
CODER = '#!/usr/bin/env bash\necho "$1 INV=$WR_INVOCATION" >> "$STUB/child.log"\nprintf \'{"model":"m"}\\n\' > "$WR_PROVENANCE_FILE"\nexit ${RC:-0}\n'
START = r'''#!/usr/bin/env bash
echo "$1" >> "$STUB/start.log"
unit="$1"; shift 2
[ -e "$STUB/startfail" ] && { echo "bus" >&2; exit 1; }
[ -e "$STUB/partial" ] && { "$@" >/dev/null 2>&1; echo "client err after admit" >&2; exit 1; }
[ -e "$STUB/queued" ] && { touch "$STUB/unit-present"; echo "$@" > "$STUB/late.cmd"; exit 1; }
[ -e "$STUB/slowfail" ] && { echo "$@" > "$STUB/late.cmd"; exit 1; }
exec "$@"
'''
UNIT = '#!/usr/bin/env bash\n[ -e "$STUB/probe-down" ] && { exit 3; }\n[ -e "$STUB/probe-slow" ] && { touch "$STUB/probe-entered"; sleep 2; }\nif [ -e "$STUB/unit-present" ]; then printf "LoadState=loaded\\nActiveState=active\\n"; else printf "LoadState=not-found\\nActiveState=inactive\\n"; fi\n'
class World:
    def __init__(s, name, host="h1"):
        s.w = BASE + "/" + name; shutil.rmtree(s.w, ignore_errors=True)
        for d in ("bin", "stub", "home", "state"): os.makedirs(s.w + "/" + d)
        for n, b in (("wm-asks", ASKS), ("fake-coder", CODER), ("fake-start", START), ("hold", "#!/usr/bin/env bash\nexit 0\n"), ("unitprobe", UNIT)):
            open(s.w + "/bin/" + n, "w").write(b); os.chmod(s.w + "/bin/" + n, 0o755)
        s.db = {"A1": {"ask_id": "A1", "rev": 4, "owner": "r7", "status": "open", "claim": None, "waits_on": [], "what": "t. worker-route: host=h1 launcher=fake-coder arg=a1"}}
        s.save()
        s.env = dict(os.environ, WR_TEST_SEAMS="1", WR_SELF=ENTRY, WR_SRC=SRC, HOME=s.w + "/home", STUB=s.w + "/stub", WR_STATE=s.w + "/state", WM_ASKS_CMD=s.w + "/bin/wm-asks", WR_HOST=host,
                     WR_LAUNCHERS="fake-coder", WR_LAUNCHER_DIR=s.w + "/bin", WR_START_CMD=s.w + "/bin/fake-start", HOLD_GATE=s.w + "/bin/hold",
                     WR_UNIT_PROBE=s.w + "/bin/unitprobe", WR_ASKS_TIMEOUT="20")
        r = s.run("bind", "--executable", os.path.realpath(s.w + "/bin/wm-asks"), "--store", s.w + "/stub/db.json", "--by", "o"); assert r[0] == 0, r
    def save(s): json.dump(s.db, open(s.w + "/stub/db.json", "w"))
    def run(s, *a, env=None):
        p = subprocess.run([sys.executable, "-I", ENTRY] + list(a), env=env or s.env, capture_output=True, text=True, timeout=120)
        return p.returncode, [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")], p.stderr
    def flag(s, n, c=""): open(s.w + "/stub/" + n, "w").write(c)
    def unflag(s, n):
        try: os.unlink(s.w + "/stub/" + n)
        except OSError: pass
    def children(s):
        try: return [l for l in open(s.w + "/stub/child.log").read().splitlines()]
        except OSError: return []
    def calls(s, pre): 
        try: return sum(1 for l in open(s.w + "/stub/calls.log") if l.startswith(pre))
        except OSError: return 0
    def rec(s, kind, inv): 
        try: return json.load(open("%s/state/%s/%s.json" % (s.w, kind, inv)))
        except OSError: return None
    def invs(s): return sorted(f[:-5] for f in os.listdir(s.w + "/state/launches")) if os.path.isdir(s.w + "/state/launches") else []
    def receipts(s):
        d = s.w + "/state/consumed"; out = {}
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if f.endswith(".late-terminal.json"): out[f[:-5]] = "late"; continue
            j = json.load(open(d + "/" + f)); out[j["invocation"]] = j["state"]
        return out
def dec(ds): return [d["decision"] for d in ds]
