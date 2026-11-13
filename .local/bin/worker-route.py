#!/usr/bin/env python3
"""worker-route.py launch <ask> | supervise <invocation> | consume | reconcile <invocation> --verdict present|absent --by <who>

Direct route (rb/r7 seat retirement, step 2): task -> authorized host worker -> durable exact-invocation terminal ->
named consumer -> next action, with no seat model turn in the loop. Reuses the canonical ask store (wm-asks) and the existing
launchers; adds no task store, scheduler, coordinator or signing authority. rb and r7 stay names (owner/host labels), not principals.

  task       = an open ask whose `what` carries `worker-route: host=<h> launcher=<name> [arg=<v> ...] [model=<m> effort=<e>]`.
               The text is DATA: only the allowlisted launcher basename (WR_LAUNCHERS) under WR_LAUNCHER_DIR is ever executed.
  launch     = host check -> hold gate -> claim (wm-asks claim --worker <invocation> --expect-rev) -> durable launch record (before the
               start) -> start the supervisor as a unit whose description carries PREMISE and EXPIRY. No runtime/turn/retry cap.
  supervise  = the unit body: runs the launcher child, then writes ONE immutable terminal terminals/<invocation>.json (O_EXCL link):
               rc, status, host, the invocation nonce, and the provenance the launcher itself wrote (WR_PROVENANCE_FILE), copied verbatim.
  consume    = the deterministic consumer: for each terminal -> identity (launch record, nonce, host, claim readback) -> effect ledger
               (BEGIN without END = UNKNOWN, held) -> receipt (never closes, resolves or accepts the ask) -> successor: an open, unclaimed
               ask whose waits_on tokens are all consumed asks and that carries its own worker-route spec is launched the same way.
  reconcile  = the owner's readback of an UNKNOWN effect: `present` (END) or `absent` (ABSENT); never inferred.
State: $WR_STATE (default ~/.local/state/worker-route): launches/ terminals/ consumed/ effects/ prov/ decisions.jsonl locks/.
Env seams: WM_ASKS_CMD HOLD_GATE WR_HOST WR_LAUNCHERS WR_LAUNCHER_DIR WR_START_CMD (<unit> <description> <cmd...>; default systemd-run --user).
Exit: 0 ok | 4 canonical ask store unavailable (nothing launched; retryable, no cap) | 5 ask claimed by another worker | 6 invocation still
open for this ask | 64 usage | 76 hold gate closed | 78 no/invalid spec | 79 wrong host | 1 start failed.
Provenance: model/effort/account are what the launcher recorded; absent = "unrecorded". This file reads no credential and infers no account.
"""
import fcntl
import glob
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
STATE = os.environ.get("WR_STATE") or os.path.join(HOME, ".local/state/worker-route")
HOST = os.environ.get("WR_HOST") or socket.gethostname().split(".")[0]
ASKS = shlex.split(os.environ.get("WM_ASKS_CMD") or "wm-asks")
HOLD_GATE = os.environ.get("HOLD_GATE") or os.path.join(HOME, ".local/bin/hold-gate.sh")
LAUNCHERS = (os.environ.get("WR_LAUNCHERS") or "rb-coder-launch.sh r7-run-coder.sh rb-run-coder.sh").replace(":", " ").split()
LAUNCHER_DIR = os.environ.get("WR_LAUNCHER_DIR") or os.path.join(HOME, ".local/bin")
SELF = os.path.realpath(__file__)
SPEC_RE = re.compile(r"worker-route:\s*([^\n]*)")
INV_RE = re.compile(r"^wr-[A-Za-z0-9]+-[0-9]+-[0-9a-f]{8}$")
ASK_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")
REFUSED_RC = (70, 72, 73, 74, 76, 77, 78, 79, 80)     # the launchers' refusal exits (rb-run-coder.sh header)
PROV_KEYS = ("model", "effort", "account", "session")
FINAL = ("consumed", "refused", "worker-failed", "worker-refused", "provider-outage", "absent-effect")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def d(*p):
    return os.path.join(STATE, *p)


def ensure():
    for s in ("launches", "terminals", "consumed", "effects", "prov", "locks"):
        os.makedirs(d(s), exist_ok=True)


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load(path):
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def decide(**kw):
    kw["ts"] = now()
    kw["host"] = HOST
    line = json.dumps(kw, sort_keys=True)
    with open(d("decisions.jsonl"), "a") as f:
        f.write(line + "\n")
    print(line)


_LAST = {}


def decide_once(key, **kw):
    """One row per (key, state change): a standing condition is a single row, not one per consume pass."""
    path = d("blocked.json")
    cur = load(path) or {}
    sig = json.dumps(kw, sort_keys=True)
    if cur.get(key) == sig:
        return
    cur[key] = sig
    atomic_write(path, json.dumps(cur, sort_keys=True))
    decide(**kw)


def clear_once(key):
    path = d("blocked.json")
    cur = load(path) or {}
    if key in cur:
        del cur[key]
        atomic_write(path, json.dumps(cur, sort_keys=True))


def sh(argv, timeout=120, env=None):
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e)


def asks_query(*args):
    """Canonical read. List of rows, or None when the store is unavailable or malformed (no fallback)."""
    rc, out, _ = sh(ASKS + ["asks", "query", "--json"] + list(args))
    if rc != 0:
        return None
    try:
        rows = json.loads(out)
    except ValueError:
        return None
    if not isinstance(rows, list) or any(not isinstance(x, dict) for x in rows):
        return None
    return rows


def claim_worker(claim):
    return str(claim).split("@", 1)[0] if claim else ""


def hold_ok(ask):
    rc, _, _ = sh([HOLD_GATE, "worker-route:" + ask])
    return rc == 0


def parse_spec(row):
    m = SPEC_RE.search(row.get("what") or "")
    if not m:
        return None
    spec = {"args": []}
    for tok in m.group(1).split():
        if "=" not in tok:
            continue
        k, v = tok.split("=", 1)
        if k == "arg":
            spec["args"].append(v)
        elif k in ("host", "launcher", "model", "effort"):
            spec[k] = v
    return spec if spec.get("host") and spec.get("launcher") else None


def launcher_path(name):
    if "/" in name or name not in LAUNCHERS:
        return None
    p = os.path.join(LAUNCHER_DIR, name)
    return p if os.path.isfile(p) and os.access(p, os.X_OK) else None


class FileLock:
    def __init__(self, name):
        self.f = open(d("locks", name + ".lock"), "a")

    def try_acquire(self):
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def release(self):
        self.f.close()


def unknown_steps(inv):
    begun, closed = [], set()
    try:
        for line in open(d("effects", inv + ".effect")):
            p = line.split(None, 1)
            if len(p) == 2 and p[0] == "BEGIN":
                begun.append(p[1].strip())
            elif len(p) == 2 and p[0] in ("END", "ABSENT"):
                closed.add(p[1].strip())
    except OSError:
        return []
    return [s for s in begun if s not in closed]


def launch_open_for(ask):
    """An invocation of this ask that has no final receipt yet: the identity is in use, a second launch would reuse it."""
    for f in glob.glob(d("launches", "*.json")):
        r = load(f)
        if r and r.get("ask") == ask:
            c = load(d("consumed", r["invocation"] + ".json"))
            if c is None or c.get("state") not in FINAL:
                return r["invocation"]
    return None


def start(row, successor=False):
    """Claim + record + start one invocation for an open ask row. Returns an exit code (0 = started)."""
    ask = str(row.get("ask_id", ""))
    spec = parse_spec(row)
    if not ASK_RE.match(ask) or spec is None:
        decide(decision="refused", reason="no-valid-worker-route-spec", ask=ask[:40])
        return 78
    if spec["host"] != HOST:
        decide_once("wrong-host:" + ask, decision="wrong-host", ask=ask, spec_host=spec["host"])
        return 79
    lp = launcher_path(spec["launcher"])
    if lp is None:
        decide_once("consumer-unavailable:" + ask, decision="consumer-unavailable", ask=ask, launcher=spec["launcher"][:60])
        return 78
    if not hold_ok(ask):
        decide_once("held:" + ask, decision="held", ask=ask)
        return 76
    cur = row.get("claim")
    if cur:
        mine = launch_open_for(ask)
        if mine and claim_worker(cur) == mine:
            decide(decision="refused", reason="invocation-in-use", ask=ask, invocation=mine)
            return 6
        decide(decision="claim-conflict", ask=ask, claim=cur)
        return 5
    if launch_open_for(ask):
        decide(decision="refused", reason="invocation-in-use", ask=ask)
        return 6
    nonce = os.urandom(8).hex()
    inv = "wr-%s-%s-%s" % (ask, row.get("rev", 0), nonce[:8])
    rec = {"invocation": inv, "ask": ask, "rev": row.get("rev"), "nonce": nonce, "host": HOST, "worker": inv, "launcher": lp,
           "args": spec["args"], "requested": {k: spec[k] for k in ("model", "effort") if k in spec},
           "unit": "worker-route-" + inv, "state": "intent", "created": now(), "successor": successor}
    atomic_write(d("launches", inv + ".json"), json.dumps(rec, sort_keys=True, indent=1) + "\n")     # durable intent BEFORE any effect
    rc, _, _ = sh(ASKS + ["asks", "claim", ask, "--worker", inv, "--by", "worker-route", "--expect-rev", str(row.get("rev"))])
    back = asks_query("--ids", ask) if rc == 0 else None
    if rc != 0 or not back or claim_worker(back[0].get("claim")) != inv:
        rec["state"] = "claim-failed"
        atomic_write(d("launches", inv + ".json"), json.dumps(rec, sort_keys=True, indent=1) + "\n")
        decide(decision="claim-failed", ask=ask, invocation=inv, rc=rc)
        return 5 if rc != 0 else 4
    desc = ("PREMISE worker-route %s ask %s host %s: one task-bound worker; EXPIRY none: no runtime/turn/retry cap, "
            "ends when the worker exits and its terminal is consumed" % (inv, ask, HOST))
    sc = os.environ.get("WR_START_CMD")
    if sc:
        argv = shlex.split(sc) + [rec["unit"], desc, SELF, "supervise", inv]
    else:
        argv = ["systemd-run", "--user", "--collect", "--unit", rec["unit"], "--description", desc, "-p", "TasksMax=infinity",
                "--setenv=WR_STATE=" + STATE, "--setenv=WR_HOST=" + HOST, SELF, "supervise", inv]
    rec["state"] = "launched"
    atomic_write(d("launches", inv + ".json"), json.dumps(rec, sort_keys=True, indent=1) + "\n")
    rc, _, err = sh(argv, timeout=None)
    if rc != 0:
        decide(decision="start-failed", ask=ask, invocation=inv, rc=rc, error=err.strip()[:200])
        return 1
    decide(decision="launched", ask=ask, invocation=inv, unit=rec["unit"], requested=rec["requested"])
    return 0


def cmd_launch(ask):
    ensure()
    rows = asks_query("--ids", ask)
    if rows is None:
        decide(decision="canonical-unavailable", ask=ask[:40], op="launch")
        return 4
    if not rows or rows[0].get("status", "open") != "open":
        decide(decision="refused", reason="ask-not-open", ask=ask[:40])
        return 78
    return start(rows[0])


def cmd_supervise(inv):
    ensure()
    rec = load(d("launches", inv + ".json")) if INV_RE.match(inv) else None
    if rec is None:
        decide(decision="refused", reason="unknown-invocation", invocation=inv[:80])
        return 64
    tpath = d("terminals", inv + ".json")
    if os.path.exists(tpath):
        decide(decision="duplicate-terminal", invocation=inv, ask=rec["ask"])
        return 0
    env = dict(os.environ)
    prov_path = d("prov", inv + ".json")
    env.update(WR_INVOCATION=inv, WR_NONCE=rec["nonce"], WR_EFFECT_FILE=d("effects", inv + ".effect"), WR_PROVENANCE_FILE=prov_path)
    started = now()
    try:
        rc = subprocess.run([rec["launcher"]] + rec.get("args", []), env=env, stdin=subprocess.DEVNULL).returncode
    except OSError:
        rc = 127
    status = "ok" if rc == 0 else "provider-outage" if rc == 75 else "refused" if rc in REFUSED_RC else "failed"
    raw = load(prov_path) or {}
    prov = {k: raw[k] for k in PROV_KEYS if isinstance(raw.get(k), str)}      # copied verbatim; nothing inferred
    term = {"invocation": inv, "nonce": rec["nonce"], "ask": rec["ask"], "host": HOST, "rc": rc, "status": status,
            "effect": d("effects", inv + ".effect"), "provenance": prov or "unrecorded", "started": started, "ended": now()}
    fd, tmp = tempfile.mkstemp(dir=d("terminals"), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(term, sort_keys=True, indent=1) + "\n")
        f.flush()
        os.fsync(f.fileno())
    try:
        os.link(tmp, tpath)                  # immutable: the first terminal wins, a second writer cannot replace it
    except FileExistsError:
        decide(decision="duplicate-terminal", invocation=inv, ask=rec["ask"])
    finally:
        os.unlink(tmp)
    return 0


def write_receipt(inv, state, **kw):
    r = {"invocation": inv, "state": state, "consumer": "worker-route", "ts": now()}
    r.update(kw)
    atomic_write(d("consumed", inv + ".json"), json.dumps(r, sort_keys=True, indent=1) + "\n")


def process_terminal(path, flags):
    t = load(path)
    if t is None:
        return
    inv = t.get("invocation", "")
    if not INV_RE.match(str(inv)):
        decide_once("badterm:" + os.path.basename(path), decision="refused", reason="bad-invocation-id", file=os.path.basename(path)[:80])
        return
    prev = load(d("consumed", inv + ".json"))
    if prev is not None and prev.get("state") in FINAL:
        return
    lk = FileLock("inv-" + inv)
    if not lk.try_acquire():
        return
    try:
        rec = load(d("launches", inv + ".json"))
        if rec is None or t.get("nonce") != rec.get("nonce") or t.get("ask") != rec.get("ask"):
            write_receipt(inv, "refused", reason="stale-identity", ask=t.get("ask"))
            decide(decision="stale-identity", invocation=inv, ask=str(t.get("ask"))[:40])
            return
        if t.get("host") != HOST or rec.get("host") != HOST:
            decide_once("wrong-host:" + inv, decision="wrong-host", invocation=inv, terminal_host=str(t.get("host"))[:40])
            return
        if prev is not None and prev.get("state") == "unknown-effect" and unknown_steps(inv):
            return                                                # UNKNOWN stays UNKNOWN until reconcile
        rows = asks_query("--ids", rec["ask"], "--status", "all")
        if rows is None:
            decide_once("canon:" + inv, decision="canonical-unavailable", invocation=inv, ask=rec["ask"])
            flags["unavailable"] = True
            return
        clear_once("canon:" + inv)
        if not rows or claim_worker(rows[0].get("claim")) != rec["worker"]:
            write_receipt(inv, "refused", reason="claim-mismatch", ask=rec["ask"], claim=(rows[0].get("claim") if rows else None))
            decide(decision="claim-mismatch", invocation=inv, ask=rec["ask"])
            return
        common = dict(ask=rec["ask"], claim=rows[0].get("claim"), ask_status=rows[0].get("status"), provenance=t.get("provenance", "unrecorded"),
                      requested=rec.get("requested", {}), rc=t.get("rc"), terminal_status=t.get("status"))
        if t.get("status") != "ok":
            state = {"refused": "worker-refused", "provider-outage": "provider-outage"}.get(t.get("status"), "worker-failed")
            write_receipt(inv, state, **common)
            sh(ASKS + ["asks", "update", rec["ask"], "--append", "worker-route %s %s rc=%s (ask stays open; no successor)" % (inv, state, t.get("rc"))])
            decide(decision=state, invocation=inv, ask=rec["ask"], rc=t.get("rc"))
            return
        steps = unknown_steps(inv)
        if steps:
            write_receipt(inv, "unknown-effect", unknown_steps=steps, **common)
            decide(decision="unknown-effect", invocation=inv, ask=rec["ask"], steps=steps)
            return
        write_receipt(inv, "consumed", **common)
        decide(decision="consumed", invocation=inv, ask=rec["ask"], provenance=common["provenance"])
    finally:
        lk.release()


def consumed_asks():
    out = set()
    for f in glob.glob(d("consumed", "*.json")):
        r = load(f)
        if r and r.get("state") == "consumed":
            out.add(r.get("ask"))
    return out


def run_successors(flags):
    done = consumed_asks()
    if not done:
        return
    rows = asks_query("--status", "open")
    if rows is None:
        decide_once("canon:successors", decision="canonical-unavailable", op="successors")
        flags["unavailable"] = True
        return
    clear_once("canon:successors")
    for row in rows:
        waits = row.get("waits_on") or []
        if row.get("claim") or row.get("status", "open") != "open" or not waits or not set(waits) & done:
            continue
        if not all(w in done for w in waits):
            continue                                              # a token this route cannot satisfy: never guessed
        if parse_spec(row) is None:
            continue
        rc = start(row, successor=True)
        if rc == 0:
            for k in list(load(d("blocked.json")) or {}):
                if k.endswith(":" + str(row.get("ask_id"))):
                    clear_once(k)


def cmd_consume():
    ensure()
    flags = {}
    for p in sorted(glob.glob(d("terminals", "wr-*.json"))):
        process_terminal(p, flags)
    run_successors(flags)
    return 4 if flags.get("unavailable") else 0


def cmd_reconcile(inv, verdict, by):
    ensure()
    c = load(d("consumed", inv + ".json")) if INV_RE.match(inv) else None
    if c is None or c.get("state") != "unknown-effect" or verdict not in ("present", "absent") or not by:
        decide(decision="reconcile-refused", invocation=inv[:80], reason="not-reconcilable-or-bad-verdict")
        return 3
    steps = unknown_steps(inv)
    word = "END" if verdict == "present" else "ABSENT"
    with open(d("effects", inv + ".effect"), "a") as f:
        for s in steps:
            f.write("%s %s\n" % (word, s))
        f.write("RECONCILED %s by %s at %s\n" % (verdict, by, now()))
        f.flush()
        os.fsync(f.fileno())
    if verdict == "present":
        os.unlink(d("consumed", inv + ".json"))                  # the next consume re-reads the terminal and proceeds
    else:
        write_receipt(inv, "absent-effect", ask=c.get("ask"), reconciled_by=by, note="effect never happened; owner decides the relaunch")
    decide(decision="reconciled", invocation=inv, verdict=verdict, by=by, steps=steps)
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    a = argv[2:]
    opt = lambda n: a[a.index(n) + 1] if n in a and a.index(n) + 1 < len(a) else ""
    if cmd == "launch" and len(a) == 1:
        return cmd_launch(a[0])
    if cmd == "supervise" and len(a) == 1:
        return cmd_supervise(a[0])
    if cmd == "consume" and not a:
        return cmd_consume()
    if cmd == "reconcile" and a:
        return cmd_reconcile(a[0], opt("--verdict"), opt("--by"))
    print(__doc__.split("\n")[0], file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
