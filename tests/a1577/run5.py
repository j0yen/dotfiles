import json, os, sys, tempfile, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import succ_v5 as succ
from datetime import datetime, timezone
_b = succ.build
succ.build = lambda pid, sid, le, lp, proc="/proc", projects_root=None: _b(pid, sid, le, lp, proc=proc, projects_root=proc + "/projects")
S = "11111111-1111-1111-1111-111111111111"; OTHER = "22222222-2222-2222-2222-222222222222"
BT = 1_000_000; HZ = 100; L = float(BT + 1000); NOW = L + 30; LP = 900; INV = "inv-A1296-t1"
sh = lambda b: hashlib.sha256(b).hexdigest()
def stub(pid=4242, cmd=("claude","--resume",S), tr=S, start=L+5, ppid=LP, env=INV, statraw=None, btime=BT, mk=None, mtime=None, tsoff=1, trname=None):
    root = tempfile.mkdtemp(); d = f"{root}/{pid}"; os.makedirs(d + "/fd")
    open(root + "/stat", "w").write(f"cpu 1\nbtime {btime}\n")
    if cmd is not None: open(d + "/cmdline", "wb").write(("\0".join(cmd) + "\0").encode())
    if start is not None:
        ticks = statraw if statraw is not None else int(round((start - btime) * HZ))
        open(d + "/stat", "w").write(f"{pid} (claude x) S {ppid} 1 1 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 {ticks} 0 0\n")
    if env is not None: open(d + "/environ", "wb").write(f"A=b\0WM_RELAUNCH_INVOCATION={env}\0".encode())
    if tr:
        os.makedirs(root + "/projects/p")
        ts = datetime.fromtimestamp((start or L) + tsoff, timezone.utc).isoformat().replace("+00:00", "Z")
        recs = mk if mk is not None else [dict(type="user", timestamp=ts, message=dict(role="user", content="resume. a1577-inv=" + INV))]
        tp = f"{root}/projects/p/{trname or tr}.jsonl"
        open(tp, "w").write("".join(json.dumps(x) + "\n" for x in recs)); os.utime(tp, (L + 10, mtime if mtime is not None else L + 10))
    return root
ROW = dict(ask_id="A1296", rev="14", status="open", what="drive recovery", check="test -s x")
TD = succ.task_digest(ROW)
CUR = {}
PNOW = {'v': []}
succ.live_priors = lambda a, i, e=None: (None if PNOW['v'] is None else list(PNOW['v']))   # per-case canonical bind line
def ledger_ok(a): return dict(ROW, what=ROW["what"] + CUR.get("line", "")) if a == "A1296" else None
EFF = dict(schema="a1577-effect/1", ask="A1296", invocation=INV, outcome="applied", effect_id="eff-1", source_row="d-test-1", readback="read ok")
REC = dict(schema="a1577-reconcile/1", ask="A1296", prior_invocation="inv-prev", status="reconciled", effects=["A1 verifying"])
def binding(eff=None, rec=None, **kw):
    w = tempfile.mkdtemp()
    ef = f"{w}/effect.json"; eb = (eff if isinstance(eff, bytes) else json.dumps(EFF if eff is None else eff).encode()); open(ef, "wb").write(eb)
    pf = f"{w}/prior.json"; pb = (rec if isinstance(rec, bytes) else json.dumps(REC if rec is None else rec).encode()); open(pf, "wb").write(pb)
    b = dict(ask="A1296", rev=14, invocation=INV, task_digest=TD, effect_file=ef, effect_sha=sh(eb), prior=[dict(file=pf, sha=sh(pb))])
    b.update(kw)
    pr = ",".join(f"{os.path.basename(x['file'])}:{x['sha']}" for x in b["prior"]) or "none"
    CUR["line"] = f"\na1577-bind inv={INV} effect-sha={b['effect_sha']} prior={pr}"
    p = f"{w}/binding.json"
    if b.get("_raw") is not None: open(p, "w").write(b.pop("_raw"))
    else: open(p, "w").write(json.dumps(b))
    return p, w
def run(root, bp, w, now=NOW, launch=L, lp=LP, sid=S, preconsume=None, ledger=ledger_ok, void=None):
    cp = f"{w}/consumed"
    if void is not None: open(f"{w}/succ-void", "w").write(void)
    if preconsume: open(cp, "w").write(preconsume)
    r = succ.build(4242, S, launch, lp, proc=root)
    return succ.check(r, sid, bp, now, cp, ledger=ledger)
cases = []
def add(name, want, **k): cases.append((name, want, k))
add("valid bound continuation", True)
_OLD = lambda a: dict(ROW, what=ROW["what"] + "\na1577-bind inv=inv-old effect-sha=" + "0"*64 + " prior=none" + CUR["line"])
add("X1 post-void superseding bind: earlier bind voided, LAST binds -> full positive ACCEPT", True, ledger=_OLD, void="inv-old\n")
add("X1 earlier bind NOT voided -> refused", False, ledger=_OLD, void="")
add("S1 earlier bind voided but consumed by a live child -> not voided -> refused", False, ledger=_OLD, void="inv-old\n", pre="inv-old 999 1\n")
add("S1b last bind's own invocation voided -> refused", False, void=INV + "\n")
add("X1 void store absent -> refused (fail closed)", False, ledger=_OLD)
add("newer unrelated transcript only", False, root=dict(tr=OTHER))
add("old matching transcript, no child", False, root=dict(cmd=None, tr=None, start=None, env=None))
add("wrong resumed SID in child cmdline", False, root=dict(cmd=("claude","--resume",OTHER)))
add("stale pre-launch pid", False, root=dict(start=L-50))
add("child start NaN", False, root=dict(statraw="nan"))
add("launch epoch NaN", False, launch=float("nan"))
add("observation time infinity", False, now=float("inf"))
add("launch epoch infinity", False, launch=float("inf"))
add("live launch: derived start 0.8 s before launch epoch (btime truncation)", True, root=dict(start=L-0.8))
add("derived start 1.5 s before launch epoch", False, root=dict(start=L-1.5))
add("child start in the future", False, root=dict(start=NOW+500))
add("child start outside observation bound", False, now=L+99999)
add("parent is not the launcher", False, root=dict(ppid=1))
add("launcher pid zero", False, lp=0)
add("child missing /proc stat", False, root=dict(start=None))
add("wrong invocation in environ", False, root=dict(env="inv-other"))
add("no invocation in environ", False, root=dict(env=None))
add("no binding record", False, bind=dict(_raw=""))
add("malformed binding record", False, bind=dict(_raw="{not json"))
add("binding missing effect_sha", False, bind="drop:effect_sha")
add("effect evidence digest wrong (wrong effect)", False, bind=dict(effect_sha="0"*64))
add("effect evidence file empty", False, bind="emptyeffect")
add("effect evidence file absent", False, bind="noeffect")
add("prior effects unreconciled (sha wrong)", False, bind="badprior")
add("prior file absent", False, bind="noprior")
add("rev malformed (0)", False, bind=dict(rev=0))
add("stale canonical rev (ledger moved on)", False, ledger=lambda a: dict(ROW, rev="15"))
add("binding rev ahead of ledger", False, bind=dict(rev=99))
add("task digest of another task", False, bind=dict(task_digest="2"*64))
add("canonical row changed task text", False, ledger=lambda a: dict(ROW, what="different task"))
add("canonical ask closed", False, ledger=lambda a: dict(ROW, status="closed"))
add("ledger unreadable", False, ledger=lambda a: None)
add("ledger returns another ask", False, ledger=lambda a: dict(ROW, ask_id="A1"))
add("effect arbitrary nonempty text, matching sha", False, bind=dict(eff=b"UNOBSERVED-EFFECT\n"))
add("effect outcome not applied", False, bind=dict(eff=dict(EFF, outcome="unsupported")))
add("effect receipt for another ask", False, bind=dict(eff=dict(EFF, ask="A9")))
add("effect receipt for another invocation", False, bind=dict(eff=dict(EFF, invocation="inv-z")))
add("effect receipt without effect_id", False, bind=dict(eff=dict(EFF, effect_id="")))
add("prior arbitrary text, matching sha", False, bind=dict(rec=b"A1/A2 reconciled\n"))
add("prior status not reconciled", False, bind=dict(rec=dict(REC, status="pending")))
add("prior is the same invocation", False, bind=dict(rec=dict(REC, prior_invocation=INV)))
add("prior lists no effects", False, bind=dict(rec=dict(REC, effects=[])))
add("prior for another ask", False, bind=dict(rec=dict(REC, ask="A2")))
add("canonical row has no bind line", False, ledger=lambda a: dict(ROW))
add("canonical bind line for another invocation", False, ledger=lambda a: dict(ROW, what="x\na1577-bind inv=inv-other effect-sha=" + "0"*64 + " prior=none"))
add("prior omitted locally, ledger lists one (UNKNOWN not erasable)", False, bind="dropprior")
add("prior added locally, ledger says none", False, bind="addprior")
add("ledger declares prior=none and binding has none", True, bind="noneprior")
add("replayed binding by another child", False, pre=f"{INV} 999\n")
add("same child consumed again is not a replay", True, pre=f"{INV} 4242 {float(L+5)}\n")
add("pid reuse: same pid, different start, is a replay (C2)", False, pre=f"{INV} 4242 {float(L+9)}\n")

add("C1 bind line quoted mid-line is not a receipt", False, ledger=lambda a: dict(ROW, what="x quoted a1577-bind inv=%s effect-sha=%s prior=none" % (INV, "0"*64)))
def _two(a):
    r = dict(ROW, what=ROW["what"] + CUR.get("line", "") + "\na1577-bind inv=inv-evil effect-sha=" + "0"*64 + " prior=none"); return r
add("C1b two bind lines, last no longer wins", False, ledger=_two)
add("C6 effect id already listed in prior reconciliation", False, bind=dict(eff=dict(EFF, effect_id="A1 verifying"), rec=dict(REC, effects=["A1 verifying"])))
add("C3 non-claude executable refused", False, root=dict(cmd=("python3","--resume",S)))
bad = 0
for name, want, k in cases:
    root = stub(**k.get("root", {}))
    bk = k.get("bind", {})
    if isinstance(bk, dict): bp, w = binding(**bk)
    else:
        bp, w = binding()
        b = json.load(open(bp))
        if bk.startswith("drop:"): b.pop(bk[5:])
        if bk == "emptyeffect": open(b["effect_file"], "w").close()
        if bk == "noeffect": os.unlink(b["effect_file"])
        if bk == "badprior": b["prior"][0]["sha"] = "1"*64
        if bk == "noprior": os.unlink(b["prior"][0]["file"])
        if bk in ("dropprior", "noneprior"):
            b["prior"] = []
            if bk == "noneprior": CUR["line"] = f"\na1577-bind inv={INV} effect-sha={b['effect_sha']} prior=none"
        if bk == "addprior":
            CUR["line"] = f"\na1577-bind inv={INV} effect-sha={b['effect_sha']} prior=none"
        json.dump(b, open(bp, "w"))
    try: ok, why = run(root, bp, w, now=k.get("now", NOW), launch=k.get("launch", L), lp=k.get("lp", LP), preconsume=k.get("pre"), ledger=k.get("ledger", ledger_ok), void=k.get("void"))
    except Exception as e: ok, why = "EXC", [repr(e)]
    res = "OK" if ok == want else "WRONG"; bad += ok != want
    print(f"{res} {name}: accepted={ok} {'; '.join(why)}")

import threading
def _case_c5():
    root = stub(); bp, w = binding(); st = {"n": 0}
    def led(a):
        st["n"] += 1
        row = ledger_ok(a)
        if st["n"] >= 2: row = dict(row, rev="15")
        return row
    r = succ.build(4242, S, L, LP, proc=root)
    return succ.check_and_consume(r, S, bp, NOW, f"{w}/consumed", ledger=led)
ok, why = _case_c5(); res = (not ok); bad += not res; print(("OK" if res else "WRONG"), "C5 rev changed between check and consume refused:", why)
def _case_c4():
    out = []; roots = [stub(pid=4242), stub(pid=5353, start=L+6)]
    bp, w = binding(); cp = f"{w}/consumed"
    def go(root, pid):
        r = succ.build(pid, S, L, LP, proc=root); out.append(succ.check_and_consume(r, S, bp, NOW, cp, ledger=ledger_ok)[0])
    ts = [threading.Thread(target=go, args=(roots[0], 4242)), threading.Thread(target=go, args=(roots[1], 5353))]
    [t.start() for t in ts]; [t.join() for t in ts]
    return out
o = _case_c4(); res = sorted(o) == [False, True]; bad += not res; print(("OK" if res else "WRONG"), "C4 concurrent children: exactly one binds:", o)
def _case_c7():
    root = stub(); bp, w = binding(); b = json.load(open(bp))
    good = open(b["effect_file"], "rb").read(); unsup = json.dumps(dict(EFF, outcome="unsupported")).encode()
    open(b["effect_file"], "wb").write(unsup); b["effect_sha"] = sh(unsup); json.dump(b, open(bp, "w"))
    CUR["line"] = f"\na1577-bind inv={INV} effect-sha={b['effect_sha']} prior=" + ",".join(f"{os.path.basename(x['file'])}:{x['sha']}" for x in b["prior"])
    real_read = succ._read; n = {"c": 0}
    def swap(p):
        if p == b["effect_file"]:
            n["c"] += 1
            if n["c"] >= 2: return good
        return real_read(p)
    succ._read = swap
    try: r = succ.build(4242, S, L, LP, proc=root); return succ.check(r, S, bp, NOW, f"{w}/consumed", ledger=ledger_ok)
    finally: succ._read = real_read
ok, why = _case_c7(); res = (not ok); bad += not res; print(("OK" if res else "WRONG"), "C7 swap between reads refused:", why)

def _case_c7b():
    root = stub(); bp, w = binding(); b = json.load(open(bp)); pf = b["prior"][0]["file"]
    r = succ.build(4242, S, L, LP, proc=root)
    base = succ.check(r, S, bp, NOW, f"{w}/consumed", ledger=ledger_ok)
    repl = json.dumps(dict(REC, effects=["UNBOUND-REPLACEMENT-EFFECT"])).encode()
    real_read = succ._read; n = {"c": 0}
    def swap(p):
        if p == pf:
            n["c"] += 1
            if n["c"] >= 3: return repl
        return real_read(p)
    succ._read = swap
    try: swapped = succ.check(r, S, bp, NOW, f"{w}/consumed2", ledger=ledger_ok)
    finally: succ._read = real_read
    return base, swapped, n["c"]
base, swapped, reads = _case_c7b(); res = base[0] is True and swapped[0] is True and reads == 1
print(("OK" if res else "WRONG"), "C7b prior read once (baseline accepted; third-read swap cannot change the parsed bytes), reads of prior file:", reads); bad += not res
def _v6(name, want, **k):
    global bad
    root = stub(**k); bp, w = binding(); r = succ.build(4242, S, L, LP, proc=root)
    ok, why = succ.check(r, S, bp, NOW, f"{w}/consumed", ledger=ledger_ok); res = ok == want; bad += not res
    print(("OK" if res else "WRONG"), "V6", name + ":", ok, "; ".join(why))
_T = lambda off=1: datetime.fromtimestamp(L + 5 + off, timezone.utc).isoformat().replace("+00:00", "Z")
_U = lambda c, off=1, t="user": dict(type=t, timestamp=_T(off), message=dict(role="user" if t == "user" else "assistant", content=c))
_v6("positive: marker in user prompt of SID transcript, no fd held", True)
_v6("marker for another invocation", False, mk=[_U("a1577-inv=inv-other")])
_v6("marker prefix-extended invocation", False, mk=[_U("a1577-inv=" + INV + "-x")])
_v6("marker only in assistant record", False, mk=[_U("a1577-inv=" + INV, t="assistant")])
_v6("marker only in tool_result part", False, mk=[dict(type="user", timestamp=_T(), message=dict(role="user", content=[dict(type="tool_result", content="a1577-inv=" + INV)]))])
_v6("marker in text part", True, mk=[dict(type="user", timestamp=_T(), message=dict(role="user", content=[dict(type="text", text="go a1577-inv=" + INV)]))])
_v6("marker record predates child start", False, tsoff=-300)
_v6("transcript mtime predates launch", False, mtime=L - 5)
_v6("marker in transcript of a different SID (file name)", False, trname=OTHER)
_v6("transcript has no marker record", False, mk=[_U("hello")])
_v6("malformed timestamp on marker record", False, mk=[dict(_U("a1577-inv=" + INV), timestamp="garbage")])
_v6("garbage lines around valid marker record", True, mk=[_U("x"), _U("a1577-inv=" + INV)])

def _pn(name, want, pn):
    global bad
    root = stub(); bp, w = binding(); r = succ.build(4242, S, L, LP, proc=root); PNOW["v"] = pn
    try: ok, why = succ.check(r, S, bp, NOW, f"{w}/consumed", ledger=ledger_ok)
    finally: PNOW["v"] = []
    res = ok == want; bad += not res
    print(("OK" if res else "WRONG"), "V7 check-time priors:", name + ":", ok, "; ".join(why))
_pn("ledger priors equal the bound set", True, ["inv-prev"])
_pn("late prior effect appeared after produce", False, ["inv-prev", "inv-late"])
_pn("late prior replaces the bound one", False, ["inv-late"])
_pn("ledger UNKNOWN at check time", False, None)
print("A1577-SUCC-V6-CONTROLS-PASS" if not bad else f"FAILED {bad}")
