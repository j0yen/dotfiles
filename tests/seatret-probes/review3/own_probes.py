#!/usr/bin/env python3
"""seatrv3 own fake-world probes. Drives the head through its real CLI (python3 -I worker-route.py <cmd>) against fakes written here
(not the author's): real-semantics ask store (rc 66 on ANY existing claim / rev mismatch / closed, rc 2 refused, commit-before-print),
fake start client, fake unit probe (WR_UNIT_PROBE), fake coder. No systemd, no real ledger, HOME under R/tmp.
Usage: own_probes.py <worker-route.py path> [row ...]   -> JSON lines {row, ...}"""
"""Retained from the independent review-3 probes (S/in/review3-probes/own_probes.py, copied unedited in logic; repointed at THIS clone: the scratch base comes from WR_PROBE_BASE (never /tmp), the worker-route path from this repo, and the explicit test switch WR_TEST_SEAMS=1 is added to every world). Fixtures do not prove installed behaviour."""

import json, os, shutil, subprocess, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.realpath(HERE + "/../../..")
R = os.environ["WR_PROBE_BASE"]; os.makedirs(R + "/tmp", exist_ok=True); os.makedirs(R + "/probes", exist_ok=True)
W = sys.argv[1] if len(sys.argv) > 1 else REPO + "/.local/bin/worker-route.py"
ENTRY = os.path.join(REPO, "tests", "lib", "worker-route-seamed.py")     # review 4: programs run through the test harness (no seams in the production script)
ONLY = set(sys.argv[2:])
BASE = R + "/tmp/own-worlds"
TAG = os.environ.get("PROBE_TAG", "head")

ASKS = r'''#!/usr/bin/env python3
import json, os, sys, time
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
    if mode("refuse2"): sys.stderr.write("refused: bad worker\n"); sys.exit(2)
    if mode("down-then-fail"): open(S + "/readback-down", "w").close(); sys.stderr.write("killed before commit\n"); sys.exit(1)
    if mode("timeout-before-commit"): time.sleep(30)
    if r["rev"] != rev: sys.stderr.write("Conflict: rev\n"); sys.exit(66)
    if r.get("status") == "closed": sys.exit(66)
    if r.get("claim"): sys.stderr.write("Conflict: already claimed; no second claim\n"); sys.exit(66)
    r["claim"] = w + "@2026-11-13T04:00"; r["rev"] += 1; save()
    if mode("readback-down-after"): open(S + "/readback-down", "w").close()
    if mode("hang-after-commit"): time.sleep(30)
    if mode("after-commit-rc"): sys.exit(int(open(S + "/after-commit-rc").read()))
    print("claimed", a[2], w); sys.exit(0)
if a[:2] == ["asks", "update"]:
    r = db[a[2]]; r.setdefault("notes", []).append(a[a.index("--append") + 1]); r["rev"] += 1; save(); sys.exit(0)
sys.exit(2)
'''
CODER = '#!/usr/bin/env bash\necho "$1 INV=$WR_INVOCATION" >> "$STUB/child.log"\n[ -e "$STUB/effect-begin" ] && echo "BEGIN deploy" > "$WR_EFFECT_FILE"\nprintf \'{"model":"m"}\\n\' > "$WR_PROVENANCE_FILE"\nexit ${RC:-0}\n'
START = r'''#!/usr/bin/env bash
echo "$1 :: $2" >> "$STUB/start.log"
unit="$1"; shift 2
[ -e "$STUB/gone" ] && { echo "client missing" >&2; exit 127; }
[ -e "$STUB/startfail" ] && { echo "Failed to connect to bus" >&2; exit 1; }
[ -e "$STUB/partial" ] && { "$@" >/dev/null 2>&1; echo "client error after admit" >&2; exit 1; }
[ -e "$STUB/queued" ] && { touch "$STUB/unit-present"; echo "$@" > "$STUB/late.cmd"; echo "client timeout, unit queued" >&2; exit 1; }
exec "$@"
'''
UNIT = '#!/usr/bin/env bash\n[ -e "$STUB/probe-down" ] && { echo unreachable >&2; exit 3; }\nif [ -e "$STUB/unit-present" ]; then printf "LoadState=loaded\\nActiveState=active\\n"; else printf "LoadState=not-found\\nActiveState=inactive\\n"; fi\n'
HOLD = "#!/usr/bin/env bash\nexit 0\n"


class World:
    def __init__(self, name):
        w = self.w = os.path.join(BASE, TAG, name)
        shutil.rmtree(w, ignore_errors=True)
        for s in ("bin", "stub", "home", "state"): os.makedirs(w + "/" + s)
        for n, body in (("wm-asks", ASKS), ("fake-coder", CODER), ("fake-start", START), ("unitprobe", UNIT), ("hold", HOLD)):
            p = w + "/bin/" + n; open(p, "w").write(body); os.chmod(p, 0o755)
        db = {"A1": {"ask_id": "A1", "rev": 4, "owner": "r7", "status": "open", "claim": None, "waits_on": [],
                     "what": "t. worker-route: host=h1 launcher=fake-coder arg=a1"},
              "B1": {"ask_id": "B1", "rev": 2, "owner": "r7", "status": "open", "claim": None, "waits_on": ["A1"],
                     "what": "t. worker-route: host=h1 launcher=fake-coder arg=b1"}}
        json.dump(db, open(w + "/stub/db.json", "w"))
        self.env = dict(WR_TEST_SEAMS="1", WR_SELF=ENTRY, WR_SRC=W, PATH="/usr/bin:/bin", HOME=w + "/home", STUB=w + "/stub", WR_STATE=w + "/state", WM_ASKS_CMD=w + "/bin/wm-asks", WR_HOST="h1",
                        WR_LAUNCHERS="fake-coder", WR_LAUNCHER_DIR=w + "/bin", WR_START_CMD=w + "/bin/fake-start", HOLD_GATE=w + "/bin/hold",
                        WR_UNIT_PROBE=w + "/bin/unitprobe", WR_ASKS_TIMEOUT="3", TMPDIR=R + "/tmp")
        self.flag_names = []

    def run(self, *args, env=None):
        e = dict(self.env); e.update(env or {})
        p = subprocess.run(["python3", "-I", ENTRY] + list(args), capture_output=True, text=True, env=e, stdin=subprocess.DEVNULL, timeout=120)
        return p.returncode, [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")], p.stderr

    def bind(self, env=None):
        e = dict(self.env); e.update(env or {})
        exe = os.path.realpath(e["WM_ASKS_CMD"])
        return self.run("bind", "--executable", exe, "--store", self.w + "/stub/db.json", "--by", "reviewer", env=env)[0]

    def flag(self, n, c=""): open(self.w + "/stub/" + n, "w").write(c)
    def unflag(self, n):
        try: os.unlink(self.w + "/stub/" + n)
        except OSError: pass
    def db(self): return json.load(open(self.w + "/stub/db.json"))
    def children(self):
        try: return open(self.w + "/stub/child.log").read().splitlines()
        except OSError: return []
    def calls(self, pat):
        try: return sum(1 for l in open(self.w + "/stub/calls.log") if pat in l)
        except OSError: return 0
    def receipts(self):
        out = {}; d = self.w + "/state/consumed"
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            j = json.load(open(d + "/" + f)); out[f[:-5]] = j["state"]
        return {k: v for k, v in out.items()}
    def invs(self):
        d = self.w + "/state/launches"; return sorted(f[:-5] for f in os.listdir(d)) if os.path.isdir(d) else []
    def lstate(self, inv): return json.load(open(self.w + "/state/launches/" + inv + ".json"))["state"]
    def terminals(self):
        d = self.w + "/state/terminals"; return sorted(os.listdir(d)) if os.path.isdir(d) else []


def dec(ds): return [d["decision"] for d in ds]
ROWS = {}
def row(f): ROWS[f.__name__] = f; return f
OUT = []
def emit(name, **kw):
    kw["row"] = name; OUT.append(kw); print(json.dumps(kw, sort_keys=True), flush=True)


def newworld(n):
    w = World(n); w.bind(); return w


@row
def a1_partial_start_child_ran():
    w = newworld("a1"); w.flag("partial")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    r_after = dict(w.receipts())
    rc2, ds2, _ = w.run("consume")
    emit("a1_partial_start_child_ran", rc=rc, dec=dec(ds), receipt_after_launch=r_after, children=len(w.children()), terminals=w.terminals(),
         consume=dec(ds2), receipts=w.receipts(), b_launched=any("b1" in c for c in w.children()))


@row
def a2_partial_unit_running_no_marker():
    w = newworld("a2"); w.flag("queued")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    rc2, ds2, _ = w.run("launch", "A1")
    emit("a2_partial_unit_running_no_marker", rc=rc, dec=dec(ds), lstate=w.lstate(inv), receipts=w.receipts(), relaunch_rc=rc2, relaunch_dec=dec(ds2),
         claim_calls=w.calls("asks claim A1"), children=len(w.children()))


@row
def a3_begin_without_end():
    w = newworld("a3"); w.flag("partial"); w.flag("effect-begin")
    rc, ds, _ = w.run("launch", "A1"); rc2, ds2, _ = w.run("consume")
    rc3, ds3, _ = w.run("consume")
    emit("a3_begin_without_end", launch_rc=rc, consume=dec(ds2), receipts=w.receipts(), b_claim=w.calls("asks claim B1"), consume2=dec(ds3))


@row
def a4_late_terminal_after_final():
    w = newworld("a4"); w.flag("startfail")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    rec = json.load(open(w.w + "/state/launches/" + inv + ".json"))
    # a late supervisor run (unit queued before the client failed) after the FINAL start-failed
    rc_s, ds_s, _ = w.run("supervise", inv)
    # simulate a terminal written by a child that was already past the gate (race): hand-write it
    t = {"invocation": inv, "nonce": rec["nonce"], "ask": "A1", "host": "h1", "rc": 0, "status": "ok", "effect": "x", "provenance": "unrecorded", "started": "s", "ended": "e"}
    json.dump(t, open(w.w + "/state/terminals/" + inv + ".json", "w"))
    tb = open(w.w + "/state/terminals/" + inv + ".json").read()
    rc2, ds2, _ = w.run("consume")
    rc3, ds3, _ = w.run("launch", "A1")
    emit("a4_late_terminal_after_final", final=w.receipts().get(inv), supervise_rc=rc_s, supervise_dec=dec(ds_s), children_after_supervise=len(w.children()),
         consume=dec(ds2), late_file=os.path.exists(w.w + "/state/consumed/" + inv + ".late-terminal.json"),
         terminal_intact=open(w.w + "/state/terminals/" + inv + ".json").read() == tb, relaunch_rc=rc3, relaunch_dec=dec(ds3), b_claim=w.calls("asks claim B1"))


@row
def a5_start_unknown_blocks_and_resumes():
    w = newworld("a5"); w.flag("gone"); w.flag("probe-down")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    st1 = (rc, w.lstate(inv), w.receipts())
    rl, dl, _ = w.run("launch", "A1")
    rr1, dr1, _ = w.run("resume", inv, "--by", "rev")           # probe still down
    st2 = (rr1, w.lstate(inv), w.receipts())
    w.unflag("probe-down"); w.flag("unit-present")
    rr2, dr2, _ = w.run("resume", inv, "--by", "rev")           # unit present -> started
    emit("a5_start_unknown_blocks_and_resumes", first=st1, relaunch_rc=rl, relaunch_dec=dec(dl), resume_down=st2, resume_present=(rr2, dec(dr2), w.lstate(inv), w.receipts()),
         claim_calls=w.calls("asks claim A1"), children=len(w.children()))
    w2 = newworld("a5b"); w2.flag("gone"); w2.flag("probe-down")
    w2.run("launch", "A1"); inv2 = w2.invs()[0]; w2.unflag("probe-down"); w2.unflag("gone")
    rr3, dr3, _ = w2.run("resume", inv2, "--by", "rev")         # unit absent, no marker -> proven no-start
    rl2, dl2, _ = w2.run("launch", "A1")
    emit("a5b_resume_absent_then_retry", resume=(rr3, dec(dr3), w2.receipts()), retry=(rl2, dec(dl2)), claim_calls=w2.calls("asks claim A1"), children=len(w2.children()))


@row
def b1_claim_commit_readback_fail_then_resume():
    w = newworld("b1"); w.flag("readback-down-after")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    s1 = (rc, dec(ds), w.lstate(inv), w.receipts(), len(w.children()), w.db()["A1"]["claim"])
    rl, dl, _ = w.run("launch", "A1")                            # store still down
    rr, dr, _ = w.run("resume", inv, "--by", "rev")              # store still down
    w.unflag("readback-down"); w.unflag("readback-down-after")
    rl2, dl2, _ = w.run("launch", "A1")                          # store back: launch must not double
    rr2, dr2, _ = w.run("resume", inv, "--by", "rev")
    rc3, ds3, _ = w.run("consume")
    emit("b1_claim_commit_readback_fail_then_resume", first=s1, relaunch_down=(rl, dec(dl)), resume_down=(rr, dec(dr)), relaunch_up=(rl2, dec(dl2)),
         resume_up=(rr2, dec(dr2)), children=len(w.children()), claim_calls=w.calls("asks claim A1"), receipts=w.receipts(), consume=dec(ds3), b_children=[c for c in w.children() if "b1" in c])
    w2 = newworld("b1b"); w2.flag("down-then-fail")                                           # claim refused rc2 AND readback down -> claim-unknown (cannot tell)
    rc, ds, _ = w2.run("launch", "A1"); inv2 = w2.invs()[0]
    w2.unflag("readback-down"); w2.unflag("down-then-fail"); rr, dr, _ = w2.run("resume", inv2, "--by", "rev")
    rl, dl, _ = w2.run("launch", "A1")
    emit("b1b_claim_not_held_resume_to_claim_failed", first=(rc, dec(ds), w2.lstate(inv2)), resume=(rr, dec(dr), w2.receipts()), relaunch=(rl, dec(dl)), claim_calls=w2.calls("asks claim A1"))


@row
def b2_after_commit_rc():
    for code in (75, 1):
        w = newworld("b2-%d" % code); w.flag("after-commit-rc", str(code))
        rc, ds, _ = w.run("launch", "A1")
        emit("b2_after_commit_rc%d_readback_ok" % code, rc=rc, dec=dec(ds), children=len(w.children()), receipts=w.receipts(), claim_calls=w.calls("asks claim A1"))
    w = newworld("b2-down"); w.flag("after-commit-rc", "75"); w.flag("readback-down-after")
    rc, ds, _ = w.run("launch", "A1")
    emit("b2_after_commit_rc75_readback_down", rc=rc, dec=dec(ds), children=len(w.children()), receipts=w.receipts(), ledger_claim=w.db()["A1"]["claim"])


@row
def s1_rc66_existing_claims():
    # own claim already held by a prior invocation that is merely `launched` (running)
    w = newworld("s1a"); w.run("launch", "A1"); w.unflag("startfail")
    rc2, ds2, _ = w.run("launch", "A1")
    emit("s1_second_launch_over_own_claim", rc=rc2, dec=dec(ds2), claim_calls=w.calls("asks claim A1"), children=len(w.children()))
    # prior claim by worker-route whose worker FAILED (terminal consumed worker-failed): held, no release path
    w = newworld("s1b")
    w.env["RC"] = "1"
    w.run("launch", "A1"); w.run("consume")
    rc3, ds3, _ = w.run("launch", "A1")
    emit("s1_claim_held_after_worker_failed", rc=rc3, dec=dec(ds3), receipts=w.receipts(), claim_calls=w.calls("asks claim A1"), release_calls=w.calls("release"))
    # stale-rev: our claim loses a race (rev moves) -> rc 66, readback shows no claim by us
    w = newworld("s1c")
    d = w.db(); d["A1"]["rev"] = 5; json.dump(d, open(w.w + "/stub/db.json", "w"))
    # row seen by launch has rev 5 -> claim succeeds; instead emulate race by flipping rev between query and claim: use a wrapper? skip; do via refuse2
    w.flag("refuse2")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    w.unflag("refuse2")
    rc2, ds2, _ = w.run("launch", "A1")
    emit("s2_rc2_refused_then_retry", first=(rc, dec(ds), w.receipts().get(inv)), retry=(rc2, dec(ds2)), claim_calls=w.calls("asks claim A1"), children=len(w.children()))


@row
def s3_timeout():
    w = newworld("s3a"); w.flag("hang-after-commit")
    rc, ds, _ = w.run("launch", "A1")
    emit("s3_timeout_after_commit_readback_up", rc=rc, dec=dec(ds), children=len(w.children()), receipts=w.receipts(), ledger_claim=w.db()["A1"]["claim"])
    w = newworld("s3b"); w.flag("hang-after-commit"); w.flag("readback-down-after")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    rl, dl, _ = w.run("launch", "A1")
    emit("s3_timeout_after_commit_readback_down", rc=rc, dec=dec(ds), lstate=w.lstate(inv), receipts=w.receipts(), relaunch=(rl, dec(dl)), children=len(w.children()))
    w = newworld("s3c"); w.flag("timeout-before-commit")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    emit("s3_timeout_before_commit_readback_up", rc=rc, dec=dec(ds), receipts=w.receipts(), ledger_claim=w.db()["A1"]["claim"])


@row
def c_unreachable_host():
    w = newworld("c1"); w.flag("gone"); w.flag("probe-down")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    # resume from a different host identity: must refuse (host mismatch), not decide
    w.unflag("probe-down")
    e2 = {"WR_HOST": "h2"}
    b = w.bind(env=e2)
    rr, dr, _ = w.run("resume", inv, "--by", "rev", env=e2)
    emit("c_resume_from_other_host", launch_rc=rc, lstate_before=w.lstate(inv), resume_rc=rr, resume_dec=dec(dr), lstate_after=w.lstate(inv), receipts=w.receipts())


@row
def d_positive_nostart_retry():
    w = newworld("d1"); w.flag("startfail")
    rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    w.unflag("startfail")
    rc2, ds2, _ = w.run("launch", "A1")
    rc3, ds3, _ = w.run("consume")
    rc4, ds4, _ = w.run("consume")
    emit("d_proved_no_start_retry_positive", first=(rc, dec(ds), w.receipts()), retry=(rc2, dec(ds2)), claim_calls=w.calls("asks claim A1"), release_calls=w.calls("release"),
         children=len(w.children()), consume=dec(ds3), receipts=w.receipts(), b_children=[c for c in w.children() if "b1" in c])


@row
def bind_rows():
    # no binding at all
    w = World("e0"); rc, ds, _ = w.run("launch", "A1")
    emit("bind_missing_binding_file", rc=rc, dec=dec(ds), asks_calls=w.calls(""))
    # decoy wm-asks first on PATH, no WM_ASKS_CMD
    w = newworld("e1"); decoydir = w.w + "/decoy"; os.makedirs(decoydir); shutil.copy(w.w + "/bin/wm-asks", decoydir + "/wm-asks")
    env = {"PATH": decoydir + ":/usr/bin:/bin"}; w.env.pop("WM_ASKS_CMD")
    rc, ds, _ = w.run("launch", "A1", env=env)
    emit("bind_decoy_on_PATH_no_cmd", rc=rc, dec=dec(ds), children=len(w.children()))
    # WM_ASKS_CMD points at a decoy path (copy, same content)
    w = newworld("e2"); shutil.copy(w.w + "/bin/wm-asks", w.w + "/bin/wm-asks-decoy")
    rc, ds, _ = w.run("launch", "A1", env={"WM_ASKS_CMD": w.w + "/bin/wm-asks-decoy"})
    emit("bind_other_executable_path", rc=rc, dec=dec(ds), children=len(w.children()))
    # content changed
    w = newworld("e3"); open(w.w + "/bin/wm-asks", "a").write("\n# changed\n")
    rc, ds, _ = w.run("launch", "A1"); emit("bind_executable_changed_hash", rc=rc, dec=dec(ds), children=len(w.children()))
    # other host
    w = newworld("e4"); rc, ds, _ = w.run("launch", "A1", env={"WR_HOST": "h2"}); emit("bind_other_host", rc=rc, dec=dec(ds), children=len(w.children()))
    # store replaced
    w = newworld("e5"); p = w.w + "/stub/db.json"; t = open(p).read(); os.rename(p, p + ".old"); open(p, "w").write(t)
    rc, ds, _ = w.run("launch", "A1"); emit("bind_store_replaced", rc=rc, dec=dec(ds), children=len(w.children()))
    # symlink swap: bound path is a symlink to exe1; retarget to exe2 with identical content
    w = newworld("e6"); link = w.w + "/bin/wm-asks-link"; os.symlink(w.w + "/bin/wm-asks", link)
    w.env["WM_ASKS_CMD"] = link; w.bind()
    shutil.copy(w.w + "/bin/wm-asks", w.w + "/bin/wm-asks2"); os.unlink(link); os.symlink(w.w + "/bin/wm-asks2", link)
    rc, ds, _ = w.run("launch", "A1"); emit("bind_symlink_retargeted_same_content", rc=rc, dec=dec(ds), children=len(w.children()))
    # symlink swap to different content
    w = newworld("e7"); link = w.w + "/bin/wm-asks-link"; os.symlink(w.w + "/bin/wm-asks", link)
    w.env["WM_ASKS_CMD"] = link; w.bind()
    open(w.w + "/bin/evil", "w").write(open(w.w + "/bin/wm-asks").read() + "\n# evil\n"); os.chmod(w.w + "/bin/evil", 0o755)
    os.unlink(link); os.symlink(w.w + "/bin/evil", link)
    rc, ds, _ = w.run("launch", "A1"); emit("bind_symlink_retargeted_other_content", rc=rc, dec=dec(ds), children=len(w.children()))
    # env bypass: forged binding via WR_ASKS_BINDING + decoy WM_ASKS_CMD (no bind ever run by the owner for the decoy)
    w = World("e8"); w.bind()                                     # legitimate bind of the real one
    shutil.copy(w.w + "/bin/wm-asks", w.w + "/bin/decoy"); os.chmod(w.w + "/bin/decoy", 0o755)
    exe = os.path.realpath(w.w + "/bin/decoy"); sha = hashlib.sha256(open(exe, "rb").read()).hexdigest(); st = os.stat(w.w + "/stub/db.json")
    forged = {"executable": exe, "sha256": sha, "host": "h1", "store": {"path": os.path.realpath(w.w + "/stub/db.json"), "dev": st.st_dev, "ino": st.st_ino}, "by": "x", "ts": "t"}
    json.dump(forged, open(w.w + "/forged.json", "w"))
    rc, ds, _ = w.run("launch", "A1", env={"WM_ASKS_CMD": exe, "WR_ASKS_BINDING": w.w + "/forged.json"})
    emit("bind_env_WR_ASKS_BINDING_forged_accepted", rc=rc, dec=dec(ds), children=len(w.children()))
    # WR_STATE pointed at a fresh state dir (no binding there)
    w = newworld("e9"); rc, ds, _ = w.run("launch", "A1", env={"WR_STATE": w.w + "/state2"}); emit("bind_fresh_state_no_binding", rc=rc, dec=dec(ds))
    # owner `bind` of an arbitrary non-canonical executable is accepted (self-attestation)
    w = World("e10"); open(w.w + "/bin/wm-asks", "w").write("#!/usr/bin/env bash\necho decoy\n"); os.chmod(w.w + "/bin/wm-asks", 0o755)
    open(w.w + "/stub/anyfile", "w").write("x")
    rc, ds, _ = w.run("bind", "--executable", w.w + "/bin/wm-asks", "--store", w.w + "/stub/anyfile", "--by", "anyone")
    emit("bind_accepts_arbitrary_executable_and_store_file", rc=rc, dec=dec(ds))
    # reconcile / supervise do not require binding (informational)
    # binding file corrupt
    w = newworld("e11"); open(w.w + "/state/asks-binding.json", "w").write("{")
    rc, ds, _ = w.run("launch", "A1"); emit("bind_corrupt_binding_file", rc=rc, dec=dec(ds))
    # binding file with store lacking keys
    w = newworld("e12"); b = json.load(open(w.w + "/state/asks-binding.json")); b["store"] = {}
    json.dump(b, open(w.w + "/state/asks-binding.json", "w")); rc, ds, _ = w.run("launch", "A1"); emit("bind_store_field_emptied", rc=rc, dec=dec(ds))
    # exec TOCTOU: the exe path used for calls is the PATH name, not the verified realpath (static)
    emit("bind_exec_uses_verified_path", src_uses_realpath_for_exec=("ASKS + list(args)" not in open(W).read()))


if __name__ == "__main__":
    for n, f in ROWS.items():
        if not ONLY or n in ONLY: f()
    json.dump(OUT, open(R + "/probes/own_%s.json" % TAG, "w"), indent=1, sort_keys=True)
