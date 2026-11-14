#!/usr/bin/python3 -I
"""A1577 successor-session equivalence v6 (transcript marker evidence replaces the fd; v2 text follows)
A1577 successor-session equivalence v2: observed evidence only. No provider, no live relaunch.
build(): derives the child's identity from /proc (pid, ppid, finite start time from stat+btime, --resume SID,
transcript open in fd, launch invocation id from environ). It takes NO task/effect from the caller.
check(): reads the durable binding record (canonical ask id+rev, invocation, effect evidence file, prior-effect
reconciliation files), recomputes digests from the files, and refuses on absent/wrong/replayed/nonfinite input."""
import glob, hashlib, json, math, os, re
from datetime import datetime, timezone
INV_KEY = b"WM_RELAUNCH_INVOCATION="
BIND_LINE = re.compile(r"^a1577-bind inv=(\S+) effect-sha=([0-9a-f]{64}) prior=(\S+)$")   # whole line only (C1); task_digest uses the same pattern
BTIME_SLACK = 1.0   # /proc/stat btime is whole seconds: derived start can read up to 1 s early (C9)
def _read(p):
    try:
        with open(p, "rb") as f: return f.read()
    except OSError: return None
def _sha(p):
    b = _read(p)
    return None if not b else hashlib.sha256(b).hexdigest()   # absent or empty = no evidence
def _child_start(proc, pid, hz=100):
    st, g = _read(f"{proc}/{pid}/stat"), _read(f"{proc}/stat")
    if not st or not g: return None, None
    try:
        f = st.decode("utf-8", "replace").rsplit(")", 1)[1].split()
        ppid, ticks = int(f[1]), int(f[19])
        bt = [int(l.split()[1]) for l in g.decode().splitlines() if l.startswith("btime ")][0]
    except (IndexError, ValueError): return None, None
    return ppid, bt + ticks / hz
def build(pid, sid, launch_epoch, launcher_pid, proc="/proc", projects_root=None):
    r = {"pid": pid, "ppid": None, "launcher_pid": launcher_pid, "sid_expected": sid, "launch_epoch": launch_epoch,
         "cmd_resume": None, "open_transcript": None, "child_start": None, "invocation": None, "transcripts": []}
    cmd = _read(f"{proc}/{pid}/cmdline")
    if cmd is not None:
        a = cmd.decode("utf-8", "replace").split("\0")
        if "--resume" in a and a.index("--resume") + 1 < len(a): r["cmd_resume"] = a[a.index("--resume") + 1]
    r["ppid"], r["child_start"] = _child_start(proc, pid)
    try: r["exe"] = os.path.basename(os.readlink(f"{proc}/{pid}/exe"))
    except OSError:
        r["exe"] = os.path.basename((cmd or b"").split(b"\0")[0].decode("utf-8", "replace")) if cmd else None   # stub procs have no exe link; same-uid forgeability remains a residual
    env = _read(f"{proc}/{pid}/environ")
    if env:
        for kv in env.split(b"\0"):
            if kv.startswith(INV_KEY): r["invocation"] = kv[len(INV_KEY):].decode("utf-8", "replace")
    # v6: live claude holds no transcript fd (0/600 samples); the transcript named exactly by the expected SID is read ONCE here
    # (bytes + mtime) and every decision in check() comes from that one buffer.
    root = projects_root if projects_root is not None else os.path.expanduser("~/.claude/projects")
    for tp in sorted(glob.glob(os.path.join(glob.escape(root), "*", glob.escape(sid) + ".jsonl"))):
        try: st = os.stat(tp)
        except OSError: continue
        buf = _read(tp)
        if buf is not None: r["transcripts"].append({"path": tp, "mtime": st.st_mtime, "buf": buf})
    try:
        for fd in os.listdir(f"{proc}/{pid}/fd"):
            try: t = os.readlink(f"{proc}/{pid}/fd/{fd}")
            except OSError: continue
            m = re.search(r"/\.claude/projects/[^/]+/([0-9a-f-]{36})\.jsonl$", t)
            if m: r["open_transcript"] = m.group(1)
    except OSError: pass
    return r
def _fin(x): return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
def _posint(x): return isinstance(x, int) and not isinstance(x, bool) and x > 0
def live_ledger(ask):
    import subprocess
    try:
        o = subprocess.run(["wm-decide", "asks", "query", "--json", "--id", ask], capture_output=True, text=True, timeout=30)
        d = json.loads(o.stdout); return d[0] if isinstance(d, list) else d
    except Exception: return None
def task_digest(row):
    w = "\n".join(l for l in str(row.get("what")).splitlines() if not BIND_LINE.match(l))   # the bind line is the receipt, not the task
    return hashlib.sha256((w + "\0" + str(row.get("check"))).encode()).hexdigest()
def _doc(path, schema):
    raw = _read(path)
    try: d = json.loads(raw) if raw else None
    except ValueError: d = None
    return d if isinstance(d, dict) and d.get("schema") == schema else None
def _ts(x):
    try:
        d = datetime.fromisoformat(str(x).replace("Z", "+00:00"))
        return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()
    except (ValueError, TypeError): return None
def _prompt_texts(rec):
    """Text of the record's own prompt only: a user record with role user; string content or text parts. tool_result parts and assistant records carry none."""
    if not isinstance(rec, dict) or rec.get("type") != "user": return []
    m = rec.get("message")
    if not isinstance(m, dict) or m.get("role") != "user": return []
    c = m.get("content")
    if isinstance(c, str): return [c]
    if isinstance(c, list): return [p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text" and isinstance(p.get("text"), str)]
    return []
def _marker_observed(r, sid, inv, now=None, skew=5.0):
    """v6: the resume prompt carries `a1577-inv=<INV>`. Evidence = a user record of the SID-named transcript with that marker in its own
    prompt text, record timestamp >= child start - BTIME_SLACK, file mtime >= launch epoch. One buffer, read in build()."""
    cs, ls = r.get("child_start"), r.get("launch_epoch")
    if not (_fin(cs) and _fin(ls)) or not inv: return False
    marker = "a1577-inv=" + inv
    for t in r.get("transcripts") or []:
        if os.path.basename(str(t.get("path"))) != sid + ".jsonl": continue
        if not (_fin(t.get("mtime")) and t["mtime"] >= ls): continue
        for line in (t.get("buf") or b"").decode("utf-8", "replace").splitlines():
            try: rec = json.loads(line)
            except ValueError: continue
            ts = _ts(rec.get("timestamp")) if isinstance(rec, dict) else None
            if ts is None or not _fin(ts) or ts < cs - BTIME_SLACK: continue
            if _fin(now) and ts > now + skew: continue   # D10: a future-dated marker record is not observed evidence
            if any(re.search(r"(?<![\w-])" + re.escape(marker) + r"(?![\w-])", x) for x in _prompt_texts(rec)): return True
    return False
EFFECTS_FACTORY = None   # tests inject a DecisionEffects over fixed rows; production leaves it None (live ledger read)
def live_priors(ask, inv, effect_sha=None):
    """Check-time re-read of the decision ledger: invocations with an applied effect and no reconciliation (None = UNKNOWN). Lazy import keeps the checker standalone when injected."""
    try:
        import importlib.util
        sp = importlib.util.spec_from_file_location("a1577_produce", os.path.join(os.path.dirname(os.path.abspath(__file__)), "a1577_produce.py")); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
        de = EFFECTS_FACTORY() if EFFECTS_FACTORY else m.DecisionEffects()
        cur = de.effect(ask, inv)
        if cur is None: return None   # R6-a: the bound effect itself must still read as applied (a later failed/rolled-back/duplicate row makes effect() None)
        if effect_sha and hashlib.sha256(cur).hexdigest() != effect_sha: return None   # the authoritative current effect must be the bound one
        return de.unresolved(ask, inv)
    except Exception: return None
def check(r, exp_sid, binding_path, now, consumed_path, skew=5.0, ledger=live_ledger, priors_now="live"):
    """binding_path: durable record {ask, rev, invocation, effect_file, effect_sha, prior:[{file,sha}]}; its rev and
    ask id come from the canonical ledger row the launcher read. now: observation time (caller clock)."""
    why = []
    ls, cs = r.get("launch_epoch"), r.get("child_start")
    if not (_posint(r.get("pid")) and _posint(r.get("ppid")) and _posint(r.get("launcher_pid"))): why.append("pid/ppid/launcher identity not positive ints")
    elif r["ppid"] != r["launcher_pid"]: why.append("child parent is not the launcher")
    if not (_fin(ls) and _fin(cs) and _fin(now)): why.append("start/launch/observation time missing or nonfinite")
    else:
        if cs < ls - BTIME_SLACK: why.append("child predates this launch")
        if cs > now + skew: why.append("child start in the future")
        if ls > now + skew: why.append("launch in the future")
        if now - cs > 3600: why.append("child start outside observation bound")
    if r.get("cmd_resume") != exp_sid: why.append("child not launched with --resume expected sid")
    if not re.match(r"^(claude|node)", os.path.basename(str(r.get("exe") or ""))): why.append("child executable is not claude/node")
    raw = _read(binding_path)
    try: b = json.loads(raw) if raw else None
    except ValueError: b = None
    if not isinstance(b, dict): why.append("no durable task/effect binding record"); return False, why
    for k in ("ask", "rev", "invocation", "task_digest", "effect_file", "effect_sha", "prior"):
        if k not in b: why.append(f"binding record missing {k}")
    if why and any(w.startswith("binding record missing") for w in why): return False, why
    if not _posint(b["rev"]) or not b["ask"] or not b["invocation"]: why.append("binding ask/rev/invocation malformed")
    if not r.get("invocation") or r.get("invocation") != b["invocation"]: why.append("child invocation not the bound invocation")
    if not _marker_observed(r, exp_sid, b["invocation"], now, skew): why.append("no observed user prompt record carrying a1577-inv=<bound invocation> in the expected session transcript")
    row = ledger(b["ask"]) if callable(ledger) else None
    if not isinstance(row, dict) or row.get("ask_id") != b["ask"]: why.append("canonical ledger row unreadable or not the bound ask")
    else:
        if str(row.get("status")) != "open": why.append("canonical ask is not open")
        if str(row.get("rev")) != str(b["rev"]): why.append("binding rev is not the live canonical revision")
        if b["task_digest"] != task_digest(row): why.append("task digest is not the live canonical task")
    if isinstance(row, dict) and row.get("ask_id") == b["ask"]:
        # authoritative sourcing: the canonical ledger row carries the binding line; the local binding file only points at files
        ms = [m.groups() for m in (BIND_LINE.match(l) for l in str(row.get("what")).splitlines()) if m]
        try: _voided = set((open(os.path.join(os.path.dirname(os.path.abspath(consumed_path)), "succ-void")).read()).split())
        except OSError: _voided = set()   # unreadable void store = nothing voided (fail closed)
        try: _voided -= {l.split()[0] for l in open(consumed_path).read().splitlines() if l.strip()}   # S1: a consumed (live child) invocation is never voided
        except OSError: pass
        try: _voided -= set(open(os.path.join(os.path.dirname(os.path.abspath(consumed_path)), 'succ-launched')).read().split())   # H1: a launched id is never voided
        except OSError: pass
        if not ms: why.append("canonical row carries no a1577-bind line")
        elif any(m[0] not in _voided for m in ms[:-1]): why.append("canonical row carries an earlier a1577-bind line that is not voided (found %d)" % len(ms))   # X1: producer and checker agree: earlier binds must be voided, the LAST binds
        elif ms[-1][0] in _voided: why.append("the last a1577-bind line's own invocation is voided")
        else:
            li, le, lp = ms[-1]
            if li != b["invocation"]: why.append("canonical bind line is for another invocation")
            if le != b["effect_sha"]: why.append("canonical bind line effect digest differs from the supplied effect evidence")
            want = set() if lp == "none" else set(lp.split(","))
            have = {f"{os.path.basename(str(p.get('file')))}:{p.get('sha')}" for p in b["prior"] if isinstance(p, dict)} if isinstance(b["prior"], list) else None
            if lp != "none" and not all(re.fullmatch(r"[^:,]+:[0-9a-f]{64}", w) for w in want): why.append("canonical prior list malformed")
            elif have is None or have != want: why.append("supplied prior reconciliation set differs from the canonical prior list (omission or addition refused)")
    eraw = _read(b["effect_file"])   # C7: one read; digest and meaning come from the same bytes
    got = hashlib.sha256(eraw).hexdigest() if eraw else None
    if got is None: why.append("effect evidence absent or empty")
    elif got != b["effect_sha"]: why.append("effect evidence digest mismatch")
    else:
        try: e = json.loads(eraw)
        except ValueError: e = None
        if not (isinstance(e, dict) and e.get("schema") == "a1577-effect/1"): e = None
        if not e or e.get("ask") != b["ask"] or e.get("invocation") != b["invocation"] or e.get("outcome") != "applied" or not e.get("effect_id") or not e.get("source_row") or not e.get("readback"):
            why.append("effect evidence is not an applied-outcome receipt for this ask and invocation")
    try: e_doc = json.loads(eraw) if (eraw and got == b["effect_sha"]) else None
    except ValueError: e_doc = None
    bound_priors = set()
    if not isinstance(b["prior"], list): why.append("prior reconciliation malformed")
    else:
        for p in b["prior"]:
            praw = _read(p.get("file", "")) if isinstance(p, dict) else None   # C7b: one read; digest and meaning from the same buffer
            ok = bool(praw) and hashlib.sha256(praw).hexdigest() == p.get("sha")
            try: d = json.loads(praw) if ok else None
            except ValueError: d = None
            if not (isinstance(d, dict) and d.get("schema") == "a1577-reconcile/1"): d = None
            if d and e_doc and e_doc.get("effect_id") in (d.get("effects") or []): why.append("effect id already listed in a prior reconciliation (not unique)"); break
            if not (d and d.get("ask") == b["ask"] and d.get("status") == "reconciled" and d.get("prior_invocation") and d.get("prior_invocation") != b["invocation"] and d.get("effects")):
                why.append("prior effect not reconciled by a semantic reconciliation receipt"); break
            bound_priors.add(d.get("prior_invocation"))
    _live = priors_now == "live"
    if _live: priors_now = live_priors
    nowp = (priors_now(b["ask"], b["invocation"], b["effect_sha"]) if _live else priors_now(b["ask"], b["invocation"])) if callable(priors_now) else None   # check-time recheck: a prior effect recorded after produce must be in the bound set
    if nowp is None: why.append("prior effects unreadable or UNKNOWN at check time")
    elif set(nowp) - bound_priors: why.append("prior effect unreconciled in the decision ledger at check time (late prior): " + ",".join(sorted(set(nowp) - bound_priors)))
    cons = (_read(consumed_path) or b"").decode().splitlines()
    mine = f"{b['invocation']} {r.get('pid')} {r.get('child_start')}"
    if any(l.split()[0] == b["invocation"] and l != mine for l in cons if l.strip()): why.append("binding replayed: invocation already consumed by another child (pid+start)")
    return (not why), why
def check_and_consume(r, exp_sid, binding_path, now, consumed_path, ledger=live_ledger, **kw):   # kw may carry priors_now
    import fcntl
    with open(consumed_path + ".lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)   # C4: check + reserve under one lock
        ok, why = check(r, exp_sid, binding_path, now, consumed_path, ledger=ledger, **kw)
        if not ok: return False, why
        b = json.loads(_read(binding_path))
        row = ledger(b["ask"])   # C5: re-read the canonical rev after the check, before the reservation is kept
        if not isinstance(row, dict) or str(row.get("rev")) != str(b["rev"]): return False, ["canonical revision changed between check and consume"]
        with open(consumed_path, "a") as f: f.write(f"{b['invocation']} {r['pid']} {r.get('child_start')}\n")
        return True, []
def consume(binding_path, r, consumed_path):
    b = json.loads(_read(binding_path))
    with open(consumed_path, "a") as f: f.write(f"{b['invocation']} {r['pid']} {r.get('child_start')}\n")

def main(argv):
    import time
    sid, launcher, child, binding, consumed, launch = argv[1], int(argv[2]), int(argv[3]), argv[4], argv[5], float(argv[6])
    r = build(child, sid, launch, launcher, projects_root=(argv[7] if len(argv) > 7 else None))
    ok, why = check_and_consume(r, sid, binding, time.time(), consumed)
    print(json.dumps({"ok": ok, "why": why, "pid": child, "invocation": r.get("invocation")}))
    return 0 if ok else 1
if __name__ == "__main__":
    import sys; sys.exit(main(sys.argv))
