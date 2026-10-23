#!/usr/bin/env python3
# rb 10-22 12:4x PM (jsy-29 ask 2, after gate cap 13 / max_runs 2): minutes each run's GATE-class cargo units wait on the
# MemGate. Source = journal op cargo-admission (class gate): a wait episode runs from its first decision=wait row to the next
# grant/timeout for the same (run_id, producer), or to now if still open. Prints one row per run (total minutes, episodes, open).
# Runs > LIMIT (30) minutes print an RB-BELL GATE-WAIT line -> the seat takes a DECISION to CTRL (candidate: price gate on anon 7.1 G).
# rb 10-23 1:xx PM (ctl c296 + Fable W1-W7): lives in j0yen/dotfiles; judges a rolling window (default 60 min, never a fixed date) and
# prefixes RB-BELL only when a run is new or its total grew (closed: 0.5-min rounded total; OPEN: limit bucket) since the last bell.
# Usage: gate-wait-minutes.py [--since ISO | --window-min 60] [--journal PATH] [--state PATH] [--limit 30] | --selftest
import sys, json, datetime as dt, os, tempfile, io, contextlib
def parse(ts):
    return dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
def compute(lines, since, now, floor=None):
    # W1: rows are read from `floor` (default `since`) and each episode is clipped to [since, now], so a stall opened before
    # the window still counts for its in-window part.
    floor = since if floor is None else floor
    open_, tot, eps = {}, {}, {}
    for l in lines:
        if '"cargo-admission"' not in l or '"gate"' not in l: continue
        try: d = json.loads(l); r = d["row"]; t = parse(d["ts"])
        except Exception: continue
        if d.get("op") != "cargo-admission" or r.get("class") != "gate" or t < floor: continue
        k = (str(r.get("run_id")), str(r.get("producer"))); dec = r.get("decision")
        if dec == "wait":
            open_.setdefault(k, t)
        elif dec in ("grant", "timeout") and k in open_:
            s = open_.pop(k); run = k[0]
            if t > since:
                tot[run] = tot.get(run, 0.0) + (t - max(s, since)).total_seconds() / 60; eps[run] = eps.get(run, 0) + 1
    still = {}
    for (run, _), s in open_.items():
        tot[run] = tot.get(run, 0.0) + (now - max(s, since)).total_seconds() / 60; eps[run] = eps.get(run, 0) + 1; still[run] = 1
    return tot, eps, still
def default_state():
    return os.path.expanduser("~/.local/state/rb-gate-wait/last-bell.json")
def bell_key(total, is_open, lim):
    # W2: an OPEN run keys on the threshold bucket crossed (limit, 2x, 3x ...); a closed run on its total rounded to 0.5 min
    return f"open:{int(total // lim)}" if is_open else f"total:{round(total * 2) / 2:.1f}"
def should_bell(old, key):
    # bell when the run is new, switched open<->closed, or its key GREW; an equal or smaller key (the rolling window clipping an
    # old episode away) is not new information
    try: ok, on = old.split(":"); on = float(on)
    except Exception: return True
    kind, n = key.split(":"); n = float(n)
    return ok != kind or n > on
def load_state(path):
    try:
        with open(path) as f: runs = json.load(f)["runs"]
        if not isinstance(runs, dict): raise ValueError("runs")
        return {str(k): str(v) for k, v in runs.items()}, None
    except FileNotFoundError: return {}, "missing"
    except (ValueError, KeyError, TypeError): return {}, "corrupt"
    except OSError: return {}, "unreadable"
def save_state(path, runs):
    # W4: mkdir -p, tempfile in the same dir, os.replace
    d = os.path.dirname(os.path.abspath(path)); os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".last-bell.")
    try:
        with os.fdopen(fd, "w") as f: json.dump({"runs": runs}, f, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
def main(a, now=None):
    j = os.path.expanduser("~/.local/state/wm-build/journal.jsonl"); since = None; lim = 30.0; win = 60.0; state = None
    i = 0
    while i < len(a):
        if a[i] == "--journal": j = a[i + 1]; i += 2
        elif a[i] == "--since": since = a[i + 1]; i += 2
        elif a[i] == "--window-min": win = float(a[i + 1]); i += 2
        elif a[i] == "--state": state = a[i + 1]; i += 2
        elif a[i] == "--limit": lim = float(a[i + 1]); i += 2
        else: print(f"unknown arg {a[i]}", file=sys.stderr); return 2
    now = now or dt.datetime.now(dt.timezone.utc)
    sn = parse(since) if since else now - dt.timedelta(minutes=win)
    floor = min(sn, now - dt.timedelta(minutes=max(win, 24 * 60)))
    with open(j, errors="replace") as f: tot, eps, still = compute(f, sn, now, floor)
    state = state or default_state()
    old, why = load_state(state)
    if why: print(f"WARN state reset ({why})")
    new = {}
    print(f"gate-wait since {sn.isoformat(timespec='seconds')}: runs={len(tot)} total_min={sum(tot.values()):.1f}")
    for run in sorted(tot, key=lambda r: -tot[r]):
        bell = False
        if tot[run] > lim:
            key = bell_key(tot[run], run in still, lim); new[run] = key   # W3: runs absent or <= limit are pruned
            bell = should_bell(old.get(run), key)
        print(f"{'RB-BELL GATE-WAIT>' + str(int(lim)) + ' ' if bell else ''}run={run} wait_min={tot[run]:.1f} episodes={eps[run]}{' OPEN' if run in still else ''}")
    try: save_state(state, new)
    except OSError: print("WARN state not saved")
    return 0
def selftest():
    z = dt.datetime(2026, 10, 22, 19, 0, tzinfo=dt.timezone.utc)
    row = lambda m, run, dec, cls="gate", p="py": json.dumps({"op": "cargo-admission", "ts": (z + dt.timedelta(minutes=m)).isoformat(), "row": {"class": cls, "decision": dec, "run_id": run, "producer": p}})
    res = []
    def case(name, ok, detail=""): res.append((name, bool(ok), detail))
    # (s4) the original compute case: since filter, episode pairing, class filter, open run
    L = [row(0, "1", "wait"), row(5, "1", "wait"), row(12, "1", "grant"), row(0, "2", "wait", cls="inner"), row(1, "2", "grant", cls="inner"),
         row(20, "3", "wait"), row(30, "1", "wait", p="q"), row(31, "1", "grant", p="q"), "garbage", row(-90, "4", "wait")]
    tot, eps, still = compute(L, z, z + dt.timedelta(minutes=50))
    case("s4 original compute case", round(tot.get("1", 0)) == 13 and eps.get("1") == 2 and "2" not in tot and round(tot.get("3", 0)) == 30 and still == {"3": 1} and "4" not in tot, f"{tot} {eps} {still}")
    # CLI cases run main() in-process with HOME at a throwaway dir; --state/--journal always explicit, so the default state path must stay untouched
    old_home = os.environ.get("HOME"); tmp = tempfile.mkdtemp(prefix="gwm-selftest-")
    try:
        os.environ["HOME"] = os.path.join(tmp, "home"); dpath = default_state(); os.makedirs(os.path.dirname(dpath))
        with open(dpath, "w") as f: f.write('{"runs": {}}')
        before = (os.stat(dpath).st_mtime_ns, os.stat(dpath).st_ino, open(dpath).read())
        Z = dt.datetime(2026, 10, 23, 12, 0, tzinfo=dt.timezone.utc)
        rw = lambda m, run, dec, p="py": json.dumps({"op": "cargo-admission", "ts": (Z + dt.timedelta(minutes=m)).isoformat(), "row": {"class": "gate", "decision": dec, "run_id": run, "producer": p}})
        n = [0]
        def fresh():
            n[0] += 1; return os.path.join(tmp, f"j{n[0]}.jsonl"), os.path.join(tmp, f"st{n[0]}.json")
        def put(jp, lines):
            with open(jp, "w") as f: f.write("\n".join(lines) + "\n")
        def go(jp, sp, extra=(), at=Z):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf): rc = main(["--journal", jp, "--state", sp, *extra], now=at)
            out = buf.getvalue(); return rc, out, sum(1 for l in out.splitlines() if l.startswith("RB-BELL"))
        # (s1) the CLI default window (no --since): a 40-min closed wait that ended 4 h ago never bells and prints no row
        jp, sp = fresh(); put(jp, [rw(-300, "7", "wait"), rw(-260, "7", "grant")])
        rc, out, b = go(jp, sp); case("s1 key older than the default window never bells", rc == 0 and b == 0 and "run=7" not in out, out)
        # (s2) same (run, total) on a second invocation does not bell; the plain row still prints
        jp, sp = fresh(); put(jp, [rw(-40, "8", "wait"), rw(-5, "8", "grant")])
        _, o1, b1 = go(jp, sp); _, o2, b2 = go(jp, sp)
        case("s2 same (run, total) twice -> 1 bell then 0", b1 == 1 and b2 == 0 and "run=8 wait_min=35.0" in o2, f"{b1} {b2} {o2}")
        # (s3) a grown total bells once
        put(jp, [rw(-40, "8", "wait"), rw(-5, "8", "grant"), rw(-4, "8", "wait"), rw(-1, "8", "grant")])
        _, o3, b3 = go(jp, sp); _, o4, b4 = go(jp, sp)
        case("s3 grown total bells once", b3 == 1 and b4 == 0 and "wait_min=38.0" in o3, f"{b3} {b4} {o3}")
        # (s5) default state path untouched by every case so far (run again at the end)
        # (s6) W1: a wait opened 70 min ago with no grant bells at the default window (clipped to 60)
        jp, sp = fresh(); put(jp, [rw(-70, "9", "wait")])
        rc, o, b = go(jp, sp); case("s6 open stall older than the window still bells (W1)", rc == 0 and b == 1 and "wait_min=60.0 episodes=1 OPEN" in o, o)
        # (s7) W2: OPEN run at 31 then 33 -> one bell; at 61 -> a second
        jp, sp = fresh(); put(jp, [rw(-31, "10", "wait")]); w = ["--window-min", "180"]
        _, _, c1 = go(jp, sp, w); _, _, c2 = go(jp, sp, w, Z + dt.timedelta(minutes=2)); _, o7, c3 = go(jp, sp, w, Z + dt.timedelta(minutes=30))
        case("s7 OPEN 31 -> 33 one bell, 61 a second (W2)", (c1, c2, c3) == (1, 0, 1) and "wait_min=61.0" in o7, f"{c1} {c2} {c3} {o7}")
        # (s8) W4: corrupt / missing / unreadable state fails open: one WARN row, still bells, rc 0, then recovers
        jp, sp = fresh(); put(jp, [rw(-40, "8", "wait"), rw(-5, "8", "grant")]); open(sp, "w").write("{not json")
        rc, o, b = go(jp, sp); _, o2, b2 = go(jp, sp)
        case("s8a corrupt state -> WARN + bell, rc 0, next run clean", rc == 0 and b == 1 and o.count("WARN state reset") == 1 and b2 == 0 and "WARN" not in o2, f"{o} || {o2}")
        jp, sp = fresh(); put(jp, [rw(-40, "8", "wait"), rw(-5, "8", "grant")])
        rc, o, b = go(jp, sp); case("s8b missing state -> WARN + bell", rc == 0 and b == 1 and "WARN state reset (missing)" in o, o)
        jp, sp = fresh(); put(jp, [rw(-40, "8", "wait"), rw(-5, "8", "grant")]); os.mkdir(sp)
        rc, o, b = go(jp, sp); case("s8c unreadable state (a directory) -> WARN + bell, rc 0", rc == 0 and b == 1 and "WARN state reset (unreadable)" in o, o)
        # (s9) W3: state keeps only runs in this output that are above the limit
        jp, sp = fresh(); put(jp, [rw(-40, "hi", "wait"), rw(-5, "hi", "grant"), rw(-20, "low", "wait"), rw(-15, "low", "grant")])
        json.dump({"runs": {"gone": "total:40.0", "low": "total:40.0"}}, open(sp, "w")); go(jp, sp)
        case("s9 state pruned to runs above the limit in this output (W3)", sorted(json.load(open(sp))["runs"]) == ["hi"], open(sp).read())
        # (s10) a closed episode the rolling window clips away (total shrinks while still > limit) does not re-bell
        jp, sp = fresh(); put(jp, [rw(-90, "11", "wait"), rw(-20, "11", "grant")])
        _, _, d1 = go(jp, sp); _, o, d2 = go(jp, sp, at=Z + dt.timedelta(minutes=5))
        case("s10 shrinking clipped total does not re-bell", (d1, d2) == (1, 0) and "wait_min=35.0" in o, f"{d1} {d2} {o}")
        # (s5) last: nothing above touched the default state path
        after = (os.stat(dpath).st_mtime_ns, os.stat(dpath).st_ino, open(dpath).read())
        case("s5 default state path unchanged (mtime, inode, content)", before == after, f"{before} {after}")
    finally:
        if old_home is None: os.environ.pop("HOME", None)
        else: os.environ["HOME"] = old_home
        import shutil; shutil.rmtree(tmp, ignore_errors=True)
    bad = [r for r in res if not r[1]]
    for name, ok, detail in res:
        print(f"{'ok' if ok else 'NOT OK'} - {name}" + ("" if ok else f" :: {detail}"))
    print("SELFTEST PASS" if not bad else f"SELFTEST FAIL {len(bad)}/{len(res)}"); return 0 if not bad else 1
if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:2] == ["--selftest"] else main(sys.argv[1:]))
