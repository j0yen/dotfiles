#!/usr/bin/env python3
"""queue-starve-watch — ping the r7 seat when the PRD queue starves free build slots.

10-20 2026 (P2, Fable-approved). Runs on carbon from queue-starve-watch.timer every 5 min. Stdlib only.

Source: ~/.cache/fleet-dash/status.json (<= 60 s old): queue.queue_ready and, for redbaron + ryzen7,
hosts.<h>.max_runs and len(hosts.<h>.open_runs).
  free_slots = sum over hosts of max(0, max_runs - open_runs); max_runs 0 = unlimited -> host skipped.
  starving   = free_slots > 0 and queue_ready < free_slots.
  episode    = starving continuously for >= 15 min (state in ~/.local/state/queue-starve/state.json);
               ONE ping per episode; the episode ends the first tick starving is false
               (queue_ready >= free_slots, or free_slots == 0).
Ping = queued-not-ready reason breakdown (ssh ryzen7 `wm-build queue`, non-parked / non-built rows grouped by
reason prefix) + a seed check (families with `covered-by: none` in orch's dream-seed-latest.md; none left ->
"seed exhausted - run a chain one-shot").
Delivery: pings.log (authoritative), an operator-notices file (injected into the next UserPromptSubmit of a carbon
seat by hooks/operator-notices.sh), `agorabus publish fleet.queue-starve` (advisory bus event), `tmux display-message
-t r7` (status-line flash), and (Fable review 10-20) a TYPED MESSAGE to the r7 seat:
`tmux send-keys -t r7 'queue-starve: queue_ready <n> < free slots <m>; dream the next seed-A chunk now' Enter`.
All of it fires once per episode (same state file, same ping gate). `--r7-dry-run` runs everything except that
send-keys, which is printed instead.

Usage: queue-starve-watch.py [--dry-run] [--r7-dry-run] [--selftest] [--status F] [--state-dir D] [--now EPOCH]
"""
import argparse, collections, json, os, re, shlex, subprocess, sys, tempfile, time

HOSTS = ("redbaron", "ryzen7")
EPISODE_S = 15 * 60
GAP_S = 15 * 60           # no observation for this long = continuity broken, episode timer restarts
STALE_S = 10 * 60         # status.json older than this = skip the tick
HOME = os.path.expanduser("~")
STATUS = os.path.join(HOME, ".cache/fleet-dash/status.json")
STATE_DIR = os.path.join(HOME, ".local/state/queue-starve")
NOTICES_DIR = os.path.join(os.environ.get("OPERATOR_CACHE_DIR", os.path.join(HOME, ".cache/operator")), "notices")
SEED = "~/.local/state/synthorg/runs/dream-seed-latest.md"
QUEUE_CMD = "export PATH=$HOME/.cargo/bin:$PATH; wm-build queue 2>/dev/null"


def free_slots(st):
    """-> (free, detail dict host -> (open, max) or 'unlimited')"""
    free, detail = 0, {}
    for h in HOSTS:
        x = (st.get("hosts") or {}).get(h) or {}
        mx = x.get("max_runs")
        if not isinstance(mx, int):
            detail[h] = "unknown"
            continue
        if mx == 0:
            detail[h] = "unlimited"
            continue
        op = len(x.get("open_runs") or [])
        detail[h] = (op, mx)
        free += max(0, mx - op)
    return free, detail


def evaluate(st):
    ready = (st.get("queue") or {}).get("queue_ready")
    free, detail = free_slots(st)
    starving = isinstance(ready, int) and free > 0 and ready < free
    return {"ready": ready, "free": free, "detail": detail, "starving": starving}


def step(state, ev, now):
    """Pure state machine. -> (new_state, ping_now)"""
    s = dict(state or {})
    last = s.get("last_seen")
    s["last_seen"] = now
    if not ev["starving"]:
        s["episode_start"], s["pinged"] = None, False
        return s, False
    if s.get("episode_start") is None or (last is not None and now - last > GAP_S):
        s["episode_start"], s["pinged"] = now, False
    ping = (now - s["episode_start"] >= EPISODE_S) and not s.get("pinged")
    if ping:
        s["pinged"] = True
    return s, ping


def reason_key(r):
    head = r.split(":")[0]
    return ":".join(r.split(":")[:2]) if head in ("status",) else head


def breakdown(rows):
    """Count not-eligible rows that are neither parked nor built, by reason prefix."""
    c = collections.Counter()
    for r in rows:
        if r.get("eligible"):
            continue
        rs = r.get("reasons") or []
        if any(x == "parked" or x.startswith("parked") or x.startswith("dir:") for x in rs):
            continue
        for x in rs or ["no-reason"]:
            c[reason_key(x)] += 1
    return c


def undreamed(seed_text):
    fams = re.split(r"(?m)^## Family: ", seed_text)[1:]
    # a family block ends at the next "## " heading; the last one must not swallow ## Candidates
    fams = [re.split(r"(?m)^## ", f, maxsplit=1)[0] for f in fams]
    none = sum(1 for f in fams if re.search(r"(?m)^- covered-by: none\s*$", f))
    return none, len(fams)


def ssh(cmd, host, timeout=45):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("ssh %s rc=%s" % (host, r.returncode))
    return r.stdout


def fmt_detail(detail):
    out = []
    for h in HOSTS:
        d = detail[h]
        out.append("%s %s" % (h, ("%d/%d open" % d) if isinstance(d, tuple) else d))
    return ", ".join(out)


def compose(ev, age_s, queue_rows, queue_err, seed_info, seed_err):
    parts = ["QUEUE STARVATION: queue_ready=%s < free_slots=%d for %dm (%s)." %
             (ev["ready"], ev["free"], age_s // 60, fmt_detail(ev["detail"]))]
    if queue_rows is not None:
        c = breakdown(queue_rows)
        parts.append("Queued-not-ready (ryzen7 wm-build queue, excl parked/built): " +
                     (", ".join("%s %d" % kv for kv in c.most_common()) or "none") + ".")
    else:
        parts.append("Reason breakdown unavailable (%s)." % queue_err)
    if seed_info is not None:
        n, tot = seed_info
        parts.append("Seed exhausted - run a chain one-shot." if n == 0 else
                     "Seed has %d undreamed families of %d - /dream them." % (n, tot))
    else:
        parts.append("Seed check skipped (%s)." % seed_err)
    return " ".join(parts)


def gather(runner=ssh):
    rows = qerr = seed = serr = None
    try:
        rows = json.loads(runner(QUEUE_CMD, "ryzen7"))
    except Exception as e:  # noqa: BLE001 - report, never crash the tick
        qerr = str(e)[:80]
    try:
        seed = undreamed(runner("cat " + SEED, "orch"))
    except Exception as e:  # noqa: BLE001
        serr = str(e)[:80]
    return rows, qerr, seed, serr


def r7_text(ev):
    return "queue-starve: queue_ready %s < free slots %d; dream the next seed-A chunk now" % (ev["ready"], ev["free"])


def r7_argv(text):
    return ["tmux", "send-keys", "-t", "r7", text, "Enter"]


def deliver(msg, state_dir, now, notices_dir=NOTICES_DIR, publish=True, seat_text=None, seat_dry=False):
    """-> list of channels that succeeded. pings.log is authoritative (caller treats its failure as undelivered).
    seat_text: typed into the r7 tmux seat (send-keys); seat_dry: report the command as "r7-dry:<argv>" instead."""
    ok = []
    stamp = time.strftime("%Y-%m-%d %I:%M:%S %p %Z", time.localtime(now))
    with open(os.path.join(state_dir, "pings.log"), "a") as f:
        f.write("%s %s\n" % (stamp, msg))
    ok.append("log")
    try:
        os.makedirs(notices_dir, exist_ok=True)
        with open(os.path.join(notices_dir, "queue-starve-%d.txt" % now), "w") as f:
            f.write("[queue-starve-watch -> r7 seat] %s\n" % msg)
        ok.append("notice")
    except OSError:
        pass
    if publish:
        for name, argv in (("agorabus", ["agorabus", "publish", "fleet.queue-starve", json.dumps({"to": "r7", "msg": msg}),
                                         "--session-id", "queue-starve-watch"]),
                           ("tmux", ["tmux", "display-message", "-t", "r7", "-d", "20000", "queue-starve: " + msg[:200]])):
            try:
                if subprocess.run(argv, capture_output=True, timeout=10).returncode == 0:
                    ok.append(name)
            except Exception:  # noqa: BLE001
                pass
    if seat_text:
        argv = r7_argv(seat_text)
        if seat_dry:
            ok.append("r7-dry:" + " ".join(shlex.quote(x) for x in argv))
        elif publish:
            try:
                if subprocess.run(argv, capture_output=True, timeout=10).returncode == 0:
                    ok.append("r7")
            except Exception:  # noqa: BLE001
                pass
    return ok


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def run(a):
    now = int(a.now or time.time())
    st = load(a.status, None)
    if not isinstance(st, dict):
        print("status.json unreadable: %s" % a.status)
        return 0
    ts = st.get("ts")
    if isinstance(ts, (int, float)) and now - ts > STALE_S and not a.now:
        print("status.json stale (%ds old): skipping" % (now - ts))
        return 0
    ev = evaluate(st)
    os.makedirs(a.state_dir, exist_ok=True)
    sp = os.path.join(a.state_dir, "state.json")
    old = load(sp, {})
    new, ping = step(old, ev, now)
    age = now - new["episode_start"] if new.get("episode_start") else 0
    print("queue_ready=%s free_slots=%d (%s) starving=%s episode_age=%dm pinged=%s" %
          (ev["ready"], ev["free"], fmt_detail(ev["detail"]), ev["starving"], age // 60, new.get("pinged")))
    if a.dry_run:
        if ev["starving"]:
            print("DRY-RUN (state NOT written, nothing sent); would_ping_now=%s; message as composed now:" % ping)
            print(compose(ev, age, *gather()))
            print("r7 seat message: " + r7_text(ev))
        else:
            print("DRY-RUN: not starving, no message.")
        return 0
    if ping:
        msg = compose(ev, age, *gather())
        try:
            ch = deliver(msg, a.state_dir, now, seat_text=r7_text(ev), seat_dry=getattr(a, "r7_dry_run", False))
            print("PING sent via %s" % ",".join(ch))
        except OSError as e:
            print("PING delivery failed (%s); will retry next tick" % e)
            new["pinged"] = False
    tmp = sp + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new, f)
    os.replace(tmp, sp)
    return 0


# ---------------------------------------------------------------- selftest
def selftest():
    fails = []

    def chk(name, cond):
        print("%s %s" % ("ok  " if cond else "FAIL", name))
        if not cond:
            fails.append(name)

    def status(ready, rb, r7, rb_max=2, r7_max=3):
        return {"ts": 0, "queue": {"queue_ready": ready},
                "hosts": {"redbaron": {"max_runs": rb_max, "open_runs": [0] * rb},
                          "ryzen7": {"max_runs": r7_max, "open_runs": [0] * r7}}}
    # fixture status.json files written to disk to exercise the file path too
    d = tempfile.mkdtemp(prefix="qs-selftest-")
    fx = {"starved": status(0, 2, 2), "ok": status(3, 2, 2), "unlimited_one": status(1, 5, 1, rb_max=0),
          "all_unlimited": status(0, 5, 5, rb_max=0, r7_max=0), "full": status(0, 2, 3)}
    for k, v in fx.items():
        json.dump(v, open(os.path.join(d, k + ".json"), "w"))
    ev = {k: evaluate(load(os.path.join(d, k + ".json"), {})) for k in fx}
    chk("starved: free=1 ready=0 -> starving", ev["starved"]["free"] == 1 and ev["starved"]["starving"])
    chk("not starved: ready 3 >= free 1", not ev["ok"]["starving"])
    chk("unlimited redbaron skipped: free=2 (ryzen7 only), ready 1 -> starving", ev["unlimited_one"]["free"] == 2 and ev["unlimited_one"]["starving"])
    chk("all unlimited: free=0 -> not starving", ev["all_unlimited"]["free"] == 0 and not ev["all_unlimited"]["starving"])
    chk("full hosts: free=0 -> not starving", not ev["full"]["starving"])
    # state machine / dedupe
    t0, S = 1_000_000, ev["starved"]
    s, p = step({}, S, t0);                 chk("tick 0: episode starts, no ping", not p and s["episode_start"] == t0)
    s, p = step(s, S, t0 + 300);            chk("tick +5m: no ping", not p)
    s, p = step(s, S, t0 + 600);            chk("tick +10m: no ping", not p)
    s, p = step(s, S, t0 + 900);            chk("tick +15m: ONE ping", p and s["pinged"])
    s, p = step(s, S, t0 + 1200);           chk("tick +20m: deduped (no second ping)", not p)
    s, p = step(s, S, t0 + 1500);           chk("tick +25m: still deduped", not p)
    s, p = step(s, ev["ok"], t0 + 1800);    chk("episode ends when ready >= free", s["episode_start"] is None and not s["pinged"])
    s, p = step(s, S, t0 + 2100);           chk("new episode starts fresh (no instant ping)", not p and s["episode_start"] == t0 + 2100)
    s, p = step(s, S, t0 + 2100 + 900);     chk("new episode pings again after 15m", p)
    s2, p = step({"episode_start": t0, "last_seen": t0, "pinged": False}, S, t0 + 5000)
    chk("observation gap > 15m restarts the episode timer", not p and s2["episode_start"] == t0 + 5000)
    s3, p = step({"episode_start": t0, "last_seen": t0 + 800, "pinged": True}, ev["full"], t0 + 900)
    chk("free_slots=0 ends the episode", s3["episode_start"] is None)
    # breakdown + seed
    rows = [{"eligible": True, "reasons": []},
            {"eligible": False, "reasons": ["dir:built-prds"]}, {"eligible": False, "reasons": ["parked"]},
            {"eligible": False, "reasons": ["depends-unresolved:foo"]}, {"eligible": False, "reasons": ["depends-unresolved:bar"]},
            {"eligible": False, "reasons": ["status:blocked"]}, {"eligible": False, "reasons": ["claimed-by:redbaron"]},
            {"eligible": False, "reasons": ["prefix-denied"]}]
    c = breakdown(rows)
    chk("breakdown excludes parked/built, groups by prefix",
        dict(c) == {"depends-unresolved": 2, "status:blocked": 1, "claimed-by": 1, "prefix-denied": 1})
    seed_ok = "## Family: a\n- covered-by: none\n\n## Family: b\n- covered-by: PRD-x.md\n"
    seed_ex = "## Family: a\n- covered-by: PRD-y.md\n"
    chk("seed counts undreamed", undreamed(seed_ok) == (1, 2) and undreamed(seed_ex) == (0, 1))
    m1 = compose(ev["starved"], 1020, rows, None, undreamed(seed_ex), None)
    chk("message: seed exhausted wording", "Seed exhausted - run a chain one-shot." in m1 and "depends-unresolved 2" in m1)
    m2 = compose(ev["starved"], 1020, None, "ssh ryzen7 rc=255", undreamed(seed_ok), None)
    chk("message: ssh failure degrades, undreamed count shown", "unavailable" in m2 and "1 undreamed families of 2" in m2)
    # end-to-end run() with fixtures: dedupe through the real files, no delivery side effects
    sd = os.path.join(d, "state"); nd = os.path.join(d, "notices")
    global deliver, gather
    sent = []
    real_deliver, real_gather = deliver, gather
    seats = []
    deliver = lambda msg, state_dir, now, **k: (sent.append(msg), seats.append(k.get("seat_text")),
                                                  real_deliver(msg, state_dir, now, notices_dir=nd, publish=False))[2]
    gather = lambda: (rows, None, undreamed(seed_ex), None)
    try:
        ns = lambda now, f="starved": argparse.Namespace(status=os.path.join(d, f + ".json"), state_dir=sd, now=now, dry_run=False)
        for off in (0, 300, 600, 900, 1200, 1500):
            run(ns(t0 + off))
        chk("run(): exactly one ping over 30 min of starvation", len(sent) == 1)
        chk("run(): pings.log has one line, notice file written",
            len(open(os.path.join(sd, "pings.log")).read().splitlines()) == 1 and len(os.listdir(nd)) == 1)
        run(ns(t0 + 1800, "ok")); run(ns(t0 + 2100)); run(ns(t0 + 3000))
        chk("run(): second episode pings once more (total 2)", len(sent) == 2)
        want = "queue-starve: queue_ready 0 < free slots 1; dream the next seed-A chunk now"
        chk("run(): r7 seat text carries queue_ready/free slots, once per episode", seats == [want, want])
        before = open(os.path.join(sd, "state.json")).read()
        a = ns(t0 + 9000); a.dry_run = True; run(a)
        chk("run(--dry-run): state untouched, nothing sent", open(os.path.join(sd, "state.json")).read() == before and len(sent) == 2)
    finally:
        deliver, gather = real_deliver, real_gather
    # r7 delivery through the REAL deliver() with the dry-run flag: exact tmux argv, nothing executed, publish off
    ch = real_deliver("m", sd, t0, notices_dir=nd, publish=False, seat_text=r7_text(ev["starved"]), seat_dry=True)
    r7ch = [c for c in ch if c.startswith("r7-dry:")]
    chk("r7 dry-run: exact `tmux send-keys -t r7 '<text>' Enter` command, not executed",
        r7ch == ["r7-dry:tmux send-keys -t r7 '" + want + "' Enter"] and "r7" not in ch)
    chk("r7 argv shape", r7_argv("x") == ["tmux", "send-keys", "-t", "r7", "x", "Enter"])
    chk("no seat_text -> no r7 channel", not [c for c in real_deliver("m", sd, t0, notices_dir=nd, publish=False) if c.startswith("r7")])
    print("selftest: %s" % ("PASS" if not fails else "FAIL (%s)" % ", ".join(fails)))
    return 1 if fails else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dry-run", action="store_true", help="evaluate + compose the message, write/send nothing")
    p.add_argument("--r7-dry-run", action="store_true", help="deliver as usual but only print the r7 tmux send-keys command")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--status", default=STATUS)
    p.add_argument("--state-dir", default=STATE_DIR)
    p.add_argument("--now", type=int, default=0, help="test hook: epoch seconds")
    a = p.parse_args()
    return selftest() if a.selftest else run(a)


if __name__ == "__main__":
    sys.exit(main())
