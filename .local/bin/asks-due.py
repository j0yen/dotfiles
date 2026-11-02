#!/usr/bin/env python3
"""asks-due.py (A10): the mechanical half of the ask ledger, run by seat-ask-due.timer on carbon.

For each open row of open-asks.tsv (above "# CLOSED"; 7 columns id asked owner due key check what):
  1. run the check column as a command (bash -c, 60 s cap); rc 0 = pass. Prose checks are skipped (not run).
     A pass moves the row under "# CLOSED" with column 2 = "MET <now>" and the output tail appended to what.
  2. an open row past due is re-pinged ONCE (ASK_BIN <owner> "<id> overdue ...") and, at 2x due
     (now - asked >= 2 * (due - asked)), routed once to ctl. Pings are remembered in <STATE>/pings.tsv.
  3. writes <FLEET_DASH_DIR>/asks.json: per-owner open/overdue counts and alarm (true when any row is overdue).
Whether a passing check discharged the ask stays a judgment: the MET row is listed in the owner's next turn.
Env: OPEN_ASKS, ASKS_DUE_STATE (default ~/.local/state/asks-due), FLEET_DASH_DIR (default ~/.cache/fleet-dash),
ASK_BIN (default ~/.local/bin/seat-ask.sh), ASKS_DUE_NOW (epoch, tests), ASKS_DUE_DRY=1 (no pings).
"""
import fcntl, json, os, re, subprocess, sys, time
from datetime import datetime

def runnable(check):
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import importlib.util
    spec = importlib.util.spec_from_file_location("ask_row", os.path.join(os.path.dirname(os.path.realpath(__file__)), "ask-row.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m.runnable(check)

def epoch(s):
    try:
        return datetime.fromisoformat(s.strip()).timestamp()
    except ValueError:
        return None

def parse(lines):
    """-> (open_rows [(index, cols)], closed_index)"""
    ci = lines.index("# CLOSED") if "# CLOSED" in lines else len(lines)
    rows = []
    for i, l in enumerate(lines[:ci]):
        c = l.split("\t")
        if l.startswith("#") or len(c) < 7 or not re.match(r"A\d+$", c[0]):
            continue
        if re.match(r"(MET|DONE|CANCELLED|MOOT)", c[1]):
            continue
        rows.append((i, c))
    return rows

def read(path):
    if not os.path.exists(path):
        return []
    ls = open(path).read().split("\n")
    if ls and ls[-1] == "":
        ls.pop()
    return ls

def write(path, lines):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, path)

def main():
    path = os.environ.get("OPEN_ASKS") or os.path.expanduser("~/.cache/aide/open-asks.tsv")
    state = os.environ.get("ASKS_DUE_STATE") or os.path.expanduser("~/.local/state/asks-due")
    dash = os.environ.get("FLEET_DASH_DIR") or os.path.expanduser("~/.cache/fleet-dash")
    ask_bin = os.environ.get("ASK_BIN") or os.path.expanduser("~/.local/bin/seat-ask.sh")
    now = float(os.environ.get("ASKS_DUE_NOW") or time.time())
    stamp = datetime.fromtimestamp(now).strftime("%Y-%m-%dT%H:%M")
    os.makedirs(state, exist_ok=True); os.makedirs(dash, exist_ok=True)
    lock = open(path + ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    snap = parse(read(path))
    fcntl.flock(lock, fcntl.LOCK_UN)
    results = {}
    for _, c in snap:
        if not runnable(c[5]):
            continue
        try:
            p = subprocess.run(["bash", "-c", c[5]], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            rc, out = p.returncode, (p.stdout + p.stderr)
        except subprocess.TimeoutExpired:
            rc, out = 124, "timeout 60s"
        tail = " / ".join(out.strip().splitlines()[-2:])[:200] if out.strip() else ""
        results[c[0]] = (rc, tail)
    with open(os.path.join(state, "checks.jsonl"), "a") as fh:
        for i, (rc, tail) in results.items():
            fh.write(json.dumps({"ts": stamp, "id": i, "rc": rc, "tail": tail}) + "\n")
    # re-read under the lock and apply: move passing rows, count the rest
    fcntl.flock(lock, fcntl.LOCK_EX)
    lines = read(path)
    moved = []
    for i, c in reversed(parse(lines)):
        r = results.get(c[0])
        if r and r[0] == 0 and lines[i] == "\t".join(c):
            c[1] = "MET " + stamp
            c[6] = c[6] + " | MET " + stamp + " check passed: " + (r[1] or "rc 0")
            moved.append("\t".join(c)); del lines[i]
    if moved:
        at = lines.index("# CLOSED") if "# CLOSED" in lines else len(lines)
        if at == len(lines):
            lines.append("# CLOSED")
        for k, m in enumerate(reversed(moved)):
            lines.insert(lines.index("# CLOSED") + 1 + k, m)
        write(path, lines)
    rows = parse(lines)
    fcntl.flock(lock, fcntl.LOCK_UN)
    # pings
    pings_p = os.path.join(state, "pings.tsv")
    seen = set(l.strip() for l in read(pings_p))
    owners = {}
    for _, c in rows:
        o = owners.setdefault(c[2], {"open": 0, "overdue": 0})
        o["open"] += 1
        due, asked = epoch(c[3]), epoch(c[1])
        if due is None or now <= due:
            continue
        o["overdue"] += 1
        todo = []
        if c[0] + ":owner" not in seen:
            todo.append((c[2], c[0] + ":owner", "%s overdue since %s (key %s): run its check or report MISSED with the earliest real time. check: %s" % (c[0], c[3], c[4], c[5][:120])))
        if asked is not None and now - asked >= 2 * (due - asked) and c[0] + ":ctl" not in seen:
            todo.append(("ctl", c[0] + ":ctl", "%s (owner %s) is at 2x its due %s and still open: route or reassign." % (c[0], c[2], c[3])))
        for seat, mark, text in todo:
            if os.environ.get("ASKS_DUE_DRY") != "1":
                r = subprocess.run([ask_bin, seat, text], capture_output=True, text=True)
                if r.returncode not in (0,):
                    continue
            with open(pings_p, "a") as fh:
                fh.write(mark + "\n")
            seen.add(mark)
    out = {"ts": stamp, "owners": owners, "open": sum(o["open"] for o in owners.values()),
           "overdue": sum(o["overdue"] for o in owners.values()), "closed_this_run": len(moved)}
    out["alarm"] = out["overdue"] > 0
    tmp = os.path.join(dash, "asks.json.tmp")
    json.dump(out, open(tmp, "w")); os.replace(tmp, os.path.join(dash, "asks.json"))
    return 0

if __name__ == "__main__":
    sys.exit(main())
