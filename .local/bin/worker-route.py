#!/usr/bin/env python3
"""worker-route.py bind --executable <path> --store <path> --by <who> | launch <ask> | resume <invocation> --by <who> | supervise <invocation> | consume | reconcile <invocation> --verdict present|absent --by <who>

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
State: $WR_STATE (default ~/.local/state/worker-route): launches/ terminals/ consumed/ effects/ prov/ started/ decisions.jsonl locks/ asks-binding.json.
Test seams (review 4): the production script has no seams. Run as a program (`__main__`: the shebang, `python3 worker-route.py`, the systemd unit that supervises) the state root is under
the passwd home (never $HOME), the host is the machine's hostname, the ask executable is the BOUND one, the launcher dir, allowlist and hold gate are fixed, the start client is systemd-run
and the unit probe is `systemctl --user show`: no env var, argument or file changes any of it, WR_TEST_SEAMS included. The seams exist only when this file is IMPORTED as a module (not
`__main__`) AND WR_TEST_SEAMS=1, and the one importer is the test-only entrypoint tests/lib/worker-route-seamed.py: WM_ASKS_CMD (one executable) HOLD_GATE WR_HOST WR_STATE WR_LAUNCHERS
WR_LAUNCHER_DIR WR_START_CMD (<unit> <description> <cmd...>) WR_UNIT_PROBE (<unit> -> `LoadState=`/`ActiveState=` lines) WR_ASKS_TIMEOUT (seconds, default 120) WR_SELF (the supervisor program
the start client is given). There is no override for the binding file: it is always <state>/asks-binding.json.
Exit: 0 ok | 3 resume/reconcile refused | 4 canonical ask store unavailable or claim UNKNOWN (retryable, no cap) | 5 ask claimed by another worker or claim
not held | 6 invocation still open for this ask | 7 start UNKNOWN (blocks) | 64 usage | 76 hold gate closed | 77 ask entrypoint not bound | 78 no/invalid spec |
79 wrong host | 1 start failed (no start PROVEN).
Real claim semantics (asks.claim, cli.py do_asks): ANY existing claim, the same worker's included, is Conflict (rc 66, nothing changed), Refused is rc 2,
and the claim COMMITS before the client prints, so rc 75, rc 1, a kill or a timeout can follow a committed claim. There is no release or resume verb, so this
route never re-claims, never releases and never clears a claim; only the READBACK of the claim decides (this invocation holds it, nobody does, someone else does).
Failed before start: claim-failed = the readback was READABLE and shows this invocation does not hold the claim (FINAL, relaunchable with a fresh claim).
A claim whose result AND readback are unreadable (timeout, exit 127 and rc 75 included) is claim-unknown: blocks (exit 6), reported UNKNOWN, never retried; `resume`
reads the canonical store back: claim = this invocation -> the SAME invocation starts (no second claim); claim absent or another worker's -> FINAL claim-failed;
unreadable -> stays UNKNOWN. A nonzero start-client return NEVER proves nothing started: the route reconciles host, unit, invocation and child evidence (the
started/ marker the supervisor writes first, a terminal, the effect ledger, the provenance file, the unit as `WR_UNIT_PROBE` reports it). Any of it present = started
(the unit may still be running; its terminal is consumed normally); none present AND the unit inspected absent = no-start PROVEN: FINAL start-failed (recorded with the
proof); anything else = start-unknown (UNKNOWN, blocks, exit 7; `resume` reconciles again). A launch after a PROVEN no-start ADOPTS the held claim of its own
start-failed invocation of the same ask (a new invocation id, the claim holder token carried as `worker`, no claim call); a terminal that arrives after a
start-failed FINAL is preserved and surfaced as UNKNOWN late-terminal, and blocks adoption. ADOPTION IS CHAIN-AWARE: the claim token is carried by the claimant and by every
adopter after it; a claim is adopted only while EVERY invocation that ever carried the token is a FINAL start-failed on this host with no evidence of a run (marker, terminal,
effect ledger, provenance, late terminal) AND every one of their units is re-inspected absent at adoption time (an absence read once is never reused: present -> refused 5,
not inspectable -> refused 7 UNKNOWN). After an adopter ran, failed or left a late terminal the claim stays with the owner (claim-conflict 5). finish_start and the
supervisor's marker are serialized on one per-invocation lock, so a supervisor either records its marker before the FINAL decision (-> started) or sees the FINAL receipt
and runs no child. At fixture level a unit admitted late therefore cannot run a child after a FINAL start-failed receipt (decision supervise-after-final). NOT PROVEN, installed behaviour only: real
systemd admission timing and units queued by an older supervisor build. supervise re-checks the launcher allowlist at execution time
(launcher-not-allowed -> terminal rc 78 refused, nothing executed) and refuses to start a child for an invocation that already has a FINAL start-failed receipt.
Binding: `bind` records the resolved executable path + sha256, the host and the store file identity (owner attestation; the executable and the store must be regular files owned by
this user or root and not world-writable and not writable by a foreign group); launch, consume and resume verify all four on every call and refuse (77) on any mismatch; no binding = refused. Every ask call
then executes the VERIFIED REALPATH (sha256 re-read immediately before the exec), never a PATH or symlink name. Not proven: that the bound store is the canonical ledger the
executable opens (the supplied source gives decisions.sqlite via paths.p only) and the sha-check-to-exec window is not zero.
Ask API binding (source: S/in/api/claim-api-source.json, deployed carbon asks.py/cli.py): query = cli.py:289-296 (`asks query --json [--ids csv] [--status s]`; a row carries ask_id status
owner due rev what, cli.py:296); claim = cli.py:280-282 + asks.py:211-232 (`--worker --by --expect-rev`; Conflict rc 66 cli.py:302-304, Refused rc 2 cli.py:253-257, committed-but-
unpublished rc 75 cli.py:250-252); update = cli.py:278-279 (`--append`). Row shape: the supplied read-only carbon snapshot in/wm-asks-open-rb-r7.json (2026-11-13 2:24 AM, 253 rows) shows
every row with ask_id check claim due key owner ready rev row_id status waits_on what (waits_on a list; claim null or a holder-token string), so the `claim` and `waits_on` keys are checked
against that snapshot, not assumed. NOT proven, a TRUE LIMIT of the supplied inputs (the asks.query source is not supplied): the `--status` value domain; `--status all` is used to read a
terminal's ask, and if `all` is refused the consume path reads canonical-unavailable (exit 4) forever, loud and fail-closed, with no wrong action. A row without ask_id/rev/status/claim still
makes the whole read UNKNOWN (canonical-shape-unverified, nothing claimed, nothing started) and a row without `waits_on` never starts a successor (waits-on-unverified): both kept as guards
against an API change. The real claim tokens in that snapshot look like `host:carbon:unit:<unit>@<ts>`, not a route invocation id: such a claim is never adopted (token-not-an-invocation, exit 5).
Provenance: model/effort/account are what the launcher recorded; absent = "unrecorded". This file reads no credential and infers no account.
"""
import fcntl
import glob
import hashlib
import json
import os
import pwd
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SEAMS = __name__ != "__main__" and os.environ.get("WR_TEST_SEAMS") == "1"     # seams: an IMPORTED module plus the switch (tests/lib/worker-route-seamed.py); the program run as `__main__` never has them
HOME = pwd.getpwuid(os.getuid()).pw_dir                  # the passwd home: $HOME is not consulted


def _seam(name):
    return (os.environ.get(name) or None) if SEAMS else None


STATE = _seam("WR_STATE") or os.path.join(HOME, ".local/state/worker-route")
HOST = _seam("WR_HOST") or socket.gethostname().split(".")[0]
ASKS_CMD = shlex.split(_seam("WM_ASKS_CMD") or "wm-asks") if SEAMS else None      # production: None = the bound executable and nothing else
HOLD_GATE = _seam("HOLD_GATE") or os.path.join(HOME, ".local/bin/hold-gate.sh")
LAUNCHERS = (_seam("WR_LAUNCHERS") or "rb-coder-launch.sh r7-run-coder.sh rb-run-coder.sh").replace(":", " ").split()
LAUNCHER_DIR = _seam("WR_LAUNCHER_DIR") or os.path.join(HOME, ".local/bin")
SELF = _seam("WR_SELF") or os.path.realpath(__file__)     # the supervisor program the start client runs (a seam only for the test entrypoint)
SPEC_RE = re.compile(r"worker-route:\s*([^\n]*)")
INV_RE = re.compile(r"^wr-[A-Za-z0-9]+-[0-9]+-[0-9a-f]{8}$")
ASK_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")
REFUSED_RC = (70, 72, 73, 74, 76, 77, 78, 79, 80)     # the launchers' refusal exits (rb-run-coder.sh header)
PROV_KEYS = ("model", "effort", "account", "session")
ASKS_TIMEOUT = float(_seam("WR_ASKS_TIMEOUT") or 120)
BINDING = os.path.join(STATE, "asks-binding.json")        # no env override
_VERIFIED = {}                                            # realpath + sha256 of the ask executable, set by bound_ok() on every verified call
FINAL = ("consumed", "refused", "worker-failed", "worker-refused", "provider-outage", "absent-effect", "claim-failed", "start-failed")
FAILED_BEFORE_START = ("claim-failed", "start-failed")      # claim-failed: claim not held (readback). start-failed: no start PROVEN; the claim stays held and is adopted by the next launch


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def d(*p):
    return os.path.join(STATE, *p)


def ensure():
    for s in ("launches", "terminals", "consumed", "effects", "prov", "started", "locks"):
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


def asks_call(*args):
    """Run the ask store through the VERIFIED realpath (sha256 re-read immediately before the exec). Never a PATH or symlink name; unbound = exit 127, nothing run."""
    if not _VERIFIED:
        bound_ok()                                        # never run an ask call on an unverified entrypoint, whichever entry point reached it
    exe, sha = _VERIFIED.get("exe"), _VERIFIED.get("sha")
    if not exe:
        return 127, "", "ask entrypoint not verified"
    try:
        if file_sha(exe) != sha:
            return 127, "", "ask executable changed after verification"
    except OSError as e:
        return 127, "", str(e)
    return sh([exe] + list(args), timeout=ASKS_TIMEOUT)


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(65536), b""):
            h.update(blk)
    return h.hexdigest()


def asks_identity(path=None):
    """(realpath, sha256) of the ONE ask executable: `path` when given (bind, production), else the seam-named one (tests) or the BOUND one (production). None when unresolvable."""
    if path is None:
        if SEAMS:
            if len(ASKS_CMD) != 1:
                return None
            path = shutil.which(ASKS_CMD[0])
        else:
            path = (load(BINDING) or {}).get("executable")
    if not path:
        return None
    rp = os.path.realpath(path)
    try:
        return rp, file_sha(rp)
    except OSError:
        return None


def store_identity(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return {"path": os.path.realpath(path), "dev": st.st_dev, "ino": st.st_ino}


def trusted_file(path):
    """A regular file owned by this user or root, not world-writable and not group-writable by any group but the user's own."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    return os.path.isfile(path) and st.st_uid in (os.getuid(), 0) and not (st.st_mode & 0o002) \
        and not (st.st_mode & 0o020 and st.st_gid != os.getgid())


def cmd_bind(exe, store, by):
    ensure()
    ident = asks_identity() if SEAMS else (asks_identity(exe) if exe and os.path.isabs(exe) else None)
    si = store_identity(store) if store else None
    if not by or not exe or ident is None or si is None or os.path.realpath(exe) != ident[0] or not trusted_file(ident[0]) or not trusted_file(si["path"]):
        decide(decision="bind-refused", reason="executable-or-store-not-verifiable", executable=exe[:120])
        return 3
    atomic_write(BINDING, json.dumps({"executable": ident[0], "sha256": ident[1], "host": HOST, "store": si, "by": by, "ts": now()},
                                     sort_keys=True, indent=1) + "\n")
    decide(decision="bound", executable=ident[0], sha256=ident[1], store=si["path"], by=by)
    return 0


def bound_ok():
    """The ask entrypoint is the bound one: executable path + sha256, host, store identity. Nothing is taken from a default or a PATH name; on success the
    verified realpath + sha256 are what asks_call executes."""
    _VERIFIED.clear()
    b = load(BINDING)
    ident = asks_identity()
    if not b or ident is None:
        return False
    si = store_identity((b.get("store") or {}).get("path", ""))
    ok = (b.get("executable") == ident[0] and b.get("sha256") == ident[1] and b.get("host") == HOST
          and si is not None and si == b.get("store") and trusted_file(ident[0]) and trusted_file(si["path"]))
    if ok:
        _VERIFIED.update(exe=ident[0], sha=ident[1])
    return ok


def require_bound(op):
    if bound_ok():
        clear_once("asks-unbound:" + op)
        return True
    decide_once("asks-unbound:" + op, decision="asks-unbound", op=op, note="ask entrypoint is not the bound executable/host/store; nothing was read or written")
    return False


def asks_query(*args):
    """Canonical read. List of rows, or None when the store is unavailable or malformed (no fallback)."""
    rc, out, _ = asks_call("asks", "query", "--json", *args)
    if rc != 0:
        return None
    try:
        rows = json.loads(out)
    except ValueError:
        return None
    if not isinstance(rows, list) or any(not isinstance(x, dict) for x in rows):
        return None
    if any(k not in x for x in rows for k in ROW_KEYS):       # a shape the supplied API source does not give is UNKNOWN, never assumed (module docstring)
        decide_once("shape:" + " ".join(args), decision="canonical-shape-unverified", args=" ".join(args)[:80], need=" ".join(ROW_KEYS),
                    note="UNKNOWN: a row lacks a key this route needs; nothing was claimed or started on it")
        return None
    return rows


ROW_KEYS = ("ask_id", "rev", "status", "claim")


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

    def acquire(self):
        fcntl.flock(self.f, fcntl.LOCK_EX)

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


def fail_before_start(rec, state, **kw):
    """A launch that failed before any child could exist (claim-failed: the readback shows the claim is not held; start-failed: no start PROVEN):
    the record becomes a FINAL terminal of its own (receipt + decision), the failure stays in history, and the ask is relaunchable under a new invocation id."""
    rec["state"] = state
    save_rec(rec)
    write_receipt(rec["invocation"], state, ask=rec["ask"], **kw)
    decide(decision=state, ask=rec["ask"], invocation=rec["invocation"], **kw)


def save_rec(rec):
    atomic_write(d("launches", rec["invocation"] + ".json"), json.dumps(rec, sort_keys=True, indent=1) + "\n")


def unit_probe(unit):
    """The unit as the host reports it: 'present' | 'absent' | 'unknown' (probe unreachable, malformed or not a clean answer)."""
    pc = _seam("WR_UNIT_PROBE")
    argv = (shlex.split(pc) + [unit]) if pc else ["systemctl", "--user", "show", "--property=LoadState,ActiveState", unit]
    rc, out, _ = sh(argv, timeout=20)
    if rc != 0:
        return "unknown"
    kv = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    if kv.get("LoadState") == "not-found":
        return "absent"
    if kv.get("LoadState") in ("loaded", "masked", "error") or kv.get("ActiveState") in ("active", "activating", "deactivating", "failed", "reloading"):
        return "present"
    return "unknown"


def start_evidence(rec):
    """Exact host/unit/invocation/child/effect reconciliation for one invocation: 'started' | 'none' | 'unknown'.
    started = the supervisor marker, a terminal, an effect ledger, a provenance file or the unit exists. none = ALL absent AND the unit was inspected on this
    host and is absent. Anything else (other host, probe unreachable) is unknown."""
    inv = rec["invocation"]
    if any(os.path.exists(d(sub, inv + ext)) for sub, ext in (("started", ".json"), ("terminals", ".json"), ("effects", ".effect"), ("prov", ".json"))):
        return "started"
    if rec.get("host") != HOST:
        return "unknown"
    u = unit_probe(rec["unit"])
    return {"present": "started", "absent": "none"}.get(u, "unknown")


def finish_start(rec, rc, err=""):
    """The start client returned nonzero (or a resume re-reads a start that was never settled): decide only on the reconciled evidence. The evidence read and the
    decision are one step under the per-invocation start lock the supervisor takes around its marker (R3-4: no supervisor can slip between them)."""
    lk = FileLock("start-" + rec["invocation"])
    lk.acquire()
    try:
        return _finish_start(rec, rc, err)
    finally:
        lk.release()


def _finish_start(rec, rc, err):
    ev = start_evidence(rec)
    ask, inv = rec["ask"], rec["invocation"]
    if ev == "started":
        rec["state"] = "launched"
        save_rec(rec)
        decide(decision="start-reconciled", ask=ask, invocation=inv, unit=rec["unit"], client_rc=rc, verdict="started",
               note="start client returned nonzero but the unit/child exists; its terminal is consumed normally, no second worker")
        return 0
    if ev == "none":
        fail_before_start(rec, "start-failed", rc=rc, error=err.strip()[:200], proof="no-start-proven")
        return 1
    rec["state"] = "start-unknown"
    save_rec(rec)
    decide(decision="start-unknown", ask=ask, invocation=inv, unit=rec["unit"], client_rc=rc,
           note="UNKNOWN: a unit or child may exist; blocks, reconcile with `resume`; never retried or finalized by a client exit code")
    return 7


def begin_start(rec):
    """Start the supervisor unit for an invocation whose claim is HELD (proved by readback). Returns an exit code (0 = started)."""
    inv, ask = rec["invocation"], rec["ask"]
    desc = ("PREMISE worker-route %s ask %s host %s: one task-bound worker; EXPIRY none: no runtime/turn/retry cap, "
            "ends when the worker exits and its terminal is consumed" % (inv, ask, HOST))
    sc = _seam("WR_START_CMD")
    if sc:
        argv = shlex.split(sc) + [rec["unit"], desc, SELF, "supervise", inv]
    else:
        argv = ["systemd-run", "--user", "--collect", "--unit", rec["unit"], "--description", desc, "-p", "TasksMax=infinity",
                SELF, "supervise", inv]
    rec["state"] = "launched"
    save_rec(rec)
    rc, _, err = sh(argv, timeout=None)
    if rc != 0:
        return finish_start(rec, rc, err)
    decide(decision="launched", ask=ask, invocation=inv, unit=rec["unit"], requested=rec["requested"])
    return 0


def evidence_of_run(inv):
    """Anything showing the dead invocation's unit or child ran: blocks adoption of its claim."""
    return any(os.path.exists(p) for p in (d("started", inv + ".json"), d("terminals", inv + ".json"), d("effects", inv + ".effect"),
                                           d("prov", inv + ".json"), d("consumed", inv + ".late-terminal.json")))


def adoption_chain(ask, token):
    """('ok', [launch records]) when EVERY invocation that carried the claim token (the claimant and each adopter) is a FINAL start-failed receipt of THIS ask on this host
    with no evidence of a run; ('open', invocation) when one of them is still unsettled; else (reason, [])."""
    if not INV_RE.match(token):
        return "token-not-an-invocation", []
    chain = []
    for f in sorted(glob.glob(d("launches", "*.json"))):
        r = load(f)
        if r and r.get("ask") == ask and r.get("worker") == token and r.get("invocation"):
            chain.append(r)
    if not any(r["invocation"] == token for r in chain):
        return "claimant-record-missing", []
    for r in chain:
        c = load(d("consumed", r["invocation"] + ".json"))
        if c is None or c.get("state") not in FINAL:
            return "open", r["invocation"]
    for r in chain:
        c = load(d("consumed", r["invocation"] + ".json"))
        if c.get("state") != "start-failed" or c.get("ask") != ask:
            return "chain-member-%s-%s" % (r["invocation"], c.get("state")), []
        if r.get("host") != HOST:
            return "chain-member-other-host", []
        if evidence_of_run(r["invocation"]):
            return "chain-member-ran", []
    return "ok", chain


def start(row, successor=False):
    """Claim (or adopt) + record + start one invocation for an open ask row. Returns an exit code (0 = started)."""
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
    adopt = None
    if cur:
        verdict, chain = adoption_chain(ask, claim_worker(cur))
        if verdict == "open":
            decide(decision="refused", reason="invocation-in-use", ask=ask, invocation=chain)
            return 6
        if verdict != "ok":
            decide(decision="claim-conflict", ask=ask, claim=cur, reason=verdict)
            return 5
        for rec0 in chain:                 # an absence read once is not proof later: every unit of the chain is re-inspected NOW (R3-4)
            u = unit_probe(rec0["unit"])
            if u != "absent":
                decide(decision="adopt-blocked", ask=ask, claim=cur, invocation=rec0["invocation"], unit_state=u,
                       note="the no-start proof is re-read at adoption time: a unit that is present or not inspectable blocks the adoption")
                return 5 if u == "present" else 7
        adopt = claim_worker(cur)          # every invocation that carried this token is a PROVEN no-start of this ask: the claim is held, a new claim is impossible (rc 66), so it is adopted
    if launch_open_for(ask):
        decide(decision="refused", reason="invocation-in-use", ask=ask)
        return 6
    nonce = os.urandom(8).hex()
    inv = "wr-%s-%s-%s" % (ask, row.get("rev", 0), nonce[:8])
    rec = {"invocation": inv, "ask": ask, "rev": row.get("rev"), "nonce": nonce, "host": HOST, "worker": adopt or inv, "launcher": lp,
           "args": spec["args"], "requested": {k: spec[k] for k in ("model", "effort") if k in spec},
           "unit": "worker-route-" + inv, "state": "intent", "created": now(), "successor": successor}
    if adopt:
        back = asks_query("--ids", ask)
        if back is None:
            decide(decision="canonical-unavailable", ask=ask, op="adopt")
            return 4
        if not back or claim_worker(back[0].get("claim")) != adopt:
            decide(decision="claim-conflict", ask=ask, claim=(back[0].get("claim") if back else None))
            return 5
        rec["adopts"] = adopt
        save_rec(rec)
        decide(decision="adopt-failed-start-claim", ask=ask, dead_invocation=adopt, invocation=inv)
        return begin_start(rec)
    save_rec(rec)                                            # durable intent BEFORE any effect
    rc, _, _ = asks_call("asks", "claim", ask, "--worker", inv, "--by", "worker-route", "--expect-rev", str(row.get("rev")))
    back = asks_query("--ids", ask)
    if back and claim_worker(back[0].get("claim")) == inv:
        return begin_start(rec)
    if back is not None:
        # the store was READ and this invocation does not hold the claim (rc 66/2 refusals leave nothing; a timeout or 127 is settled by the readback too)
        fail_before_start(rec, "claim-failed", rc=rc)
        return 5 if rc != 0 else 4
    # claim result unreadable AND the readback unavailable (a timeout or exit 127 included): the claim may have landed. UNKNOWN, still blocks, never retried.
    rec["state"] = "claim-unknown"
    save_rec(rec)
    decide(decision="claim-unknown", ask=ask, invocation=inv, rc=rc, note="UNKNOWN: claim may be held by this invocation; `resume` reads the canonical store back")
    return 4


def cmd_resume(inv, by):
    """The supported same-owner resume of an UNSETTLED invocation: decided only by reading the canonical store / host evidence back. Never claims again,
    never releases a claim."""
    ensure()
    if not require_bound("resume"):
        return 77
    rec = load(d("launches", inv + ".json")) if INV_RE.match(inv) else None
    c = load(d("consumed", inv + ".json")) if rec else None
    if rec is None or not by or rec.get("host") != HOST or (c is not None and c.get("state") in FINAL) or rec.get("state") not in ("intent", "claim-unknown", "start-unknown", "launched"):
        decide(decision="resume-refused", invocation=inv[:80], reason="not-resumable")
        return 3
    ask = rec["ask"]
    if rec["state"] in ("intent", "claim-unknown"):
        back = asks_query("--ids", ask)
        if back is None:
            decide(decision="resume-pending", invocation=inv, ask=ask, note="UNKNOWN: the canonical store is still unreadable; nothing changed")
            return 4
        if back and claim_worker(back[0].get("claim")) == rec["worker"]:
            decide(decision="claim-resumed", invocation=inv, ask=ask, by=by, note="readback proves this invocation holds the claim; no second claim")
            return begin_start(rec)
        fail_before_start(rec, "claim-failed", rc=None, note="readback: the claim is not held by this invocation", claim=(back[0].get("claim") if back else None))
        return 5
    rc = finish_start(rec, None)
    decide(decision="resumed", invocation=inv, ask=ask, by=by, verdict=rec["state"])
    return rc


def cmd_launch(ask):
    ensure()
    if not require_bound("launch"):
        return 77
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
    lk = FileLock("start-" + inv)                              # serialized with finish_start: either the marker lands before the FINAL decision or the FINAL receipt is seen here
    lk.acquire()
    try:
        fin = load(d("consumed", inv + ".json"))
        if fin is not None and fin.get("state") in FAILED_BEFORE_START:
            decide(decision="supervise-after-final", invocation=inv, ask=rec["ask"], final=fin.get("state"), note="a FINAL failed-before-start invocation never starts a child")
            return 0
        try:                                                  # the first supervisor wins: the marker is the child-began evidence the start reconciliation reads
            fd = os.open(d("started", inv + ".json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            decide(decision="duplicate-supervisor", invocation=inv, ask=rec["ask"])
            return 0
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps({"invocation": inv, "host": HOST, "pid": os.getpid(), "unit": rec.get("unit"), "systemd_invocation_id": os.environ.get("INVOCATION_ID", ""),
                                "started": now()}, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        lk.release()
    env = dict(os.environ)
    prov_path = d("prov", inv + ".json")
    env.update(WR_INVOCATION=inv, WR_NONCE=rec["nonce"], WR_EFFECT_FILE=d("effects", inv + ".effect"), WR_PROVENANCE_FILE=prov_path)
    started = now()
    lname = os.path.basename(str(rec.get("launcher", "")))
    if launcher_path(lname) != rec.get("launcher"):          # the state file is data: re-check the allowlist at execution time
        decide(decision="launcher-not-allowed", invocation=inv, ask=rec["ask"], launcher=str(rec.get("launcher"))[:80])
        rc = 78
    else:
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


def late_terminal(inv, t, prev):
    """A terminal for an invocation that was finalized failed-before-start: the unit/child DID run. The terminal file stays untouched, the FINAL receipt is not
    rewritten; the contradiction is recorded once as UNKNOWN and blocks any adoption of the claim."""
    path = d("consumed", inv + ".late-terminal.json")
    if os.path.exists(path):
        return
    write_late = {"invocation": inv, "state": "late-terminal", "ask": t.get("ask"), "prior_state": prev.get("state"), "terminal_rc": t.get("rc"),
                  "terminal_status": t.get("status"), "unknown_steps": unknown_steps(inv), "consumer": "worker-route", "ts": now(),
                  "note": "UNKNOWN: a terminal arrived after the invocation was finalized failed-before-start; the unit ran; owner reconciles, nothing is retried"}
    atomic_write(path, json.dumps(write_late, sort_keys=True, indent=1) + "\n")
    decide(decision="late-terminal", invocation=inv, ask=t.get("ask"), prior_state=prev.get("state"), terminal_rc=t.get("rc"), steps=write_late["unknown_steps"])


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
        if prev.get("state") in FAILED_BEFORE_START:
            late_terminal(inv, t, prev)
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
            asks_call("asks", "update", rec["ask"], "--append", "worker-route %s %s rc=%s (ask stays open; no successor)" % (inv, state, t.get("rc")))
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
        if "waits_on" not in row:
            decide_once("waits-on:" + str(row.get("ask_id")), decision="waits-on-unverified", ask=str(row.get("ask_id"))[:40],
                        note="UNKNOWN: the supplied ask API source does not give a waits_on key; no successor is started on this row")
            continue
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
    if not require_bound("consume"):
        return 77
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
    if cmd == "bind":
        return cmd_bind(opt("--executable"), opt("--store"), opt("--by"))
    if cmd == "resume" and a:
        return cmd_resume(a[0], opt("--by"))
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
