#!/usr/bin/env python3
"""ctl-obligation-run.py: the typed approved-action runner for a suggestion-only obligation (W4).
  run   --dir D --key K --approval N --action '<json>'   run ONE allow-listed verb under the approval; write D/K.run.json (verb, args, rc, approval, tail, ts); idempotent.
        D/K.inflight (pid, start ticks, boot id, key, action digest, intent "started") is the durable started record, written and fsynced BEFORE the action begins.
        A live owner or live child => print in-flight, exit 75, nothing starts. A DEAD owner with a started record and no receipt is UNKNOWN (the effect may or may not have
        happened): print status unknown-started, write D/K.unknown.json once (surface-once marker), exit 75; never a takeover, never a second execution. Only `reconcile` or an
        approved idempotent action (below) releases it. A torn/empty marker stays 75 as before. The first receipt wins (link, never replace); a late finisher writes D/K.late.json only.
  reconcile --dir D --key K --approval N --action '<json>' --evidence '<json>'
        Evidence-bound release of an UNKNOWN key; executes NO caller-supplied command. evidence = {"key":K,"action_digest":<sha256 of the canonical action spec>,"approval":"#N",
        "proves":"done"|"not-done","recipe":<one allow-listed verb spec below, different from the action>}; the recipe is built by the same VERBS allow-list, rc 0 = the proof holds.
        Approval N must exist in approvals.log (approval-check.sh --id) and name the full key; the digest must equal the started record's (revision-bound). proves done => receipt
        status "reconciled-done" rc 0 (the action is NOT re-run); proves not-done => the started record is retired to K.released-*.json so the next `run` executes once.
        Missing, wrong (recipe rc != 0), stale (digest/key mismatch) or unapproved evidence changes nothing and exits 75.
  Idempotent action: a spec may carry "idempotent":"#N"; a dead-owner started record is retired and the action re-run ONLY when approval #N names the full key and the record's
        digest equals this spec's digest. A declared key or flag alone never reruns anything.
  check --dir D --key K                                  exit 0 only when D/K.run.json exists for K with rc 0 (the ledger done-check: work evidence, never a manual touch)
Verbs (argv lists only, no shell, no interpolation of the spec into a command string):
  named-test    {"name": "<[a-z0-9][a-z0-9-]*>"}   bash $OBL_TESTS_DIR/<name>.test.sh (default ~/dotfiles/tests); no kill timer unless the owner sets OBL_RUN_TIMEOUT_SEC (default none)
  service-state {"unit": "<name>.service|.timer"}  systemctl --user is-active -- <unit> (read-only; unit starts alphanumeric)
Anything else, a bad argument, or a missing target is recorded as a receipt with status "refused" and rc 126; nothing is launched."""
import fcntl
import hashlib
import json, os, re, subprocess, sys, datetime

EX_INFLIGHT = 75   # EX_TEMPFAIL: another live runner owns this key (retry later); never a failure, never a second execution

VERBS = {
    "named-test": ("name", re.compile(r"[a-z0-9][a-z0-9-]{0,63}")),
    "service-state": ("unit", re.compile(r"[A-Za-z0-9][A-Za-z0-9@._-]{0,79}\.(service|timer)")),
}


APPR_BIN = os.environ.get("OBL_APPROVAL_BIN") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "approval-check.sh")


def digest(spec):
    return hashlib.sha256(json.dumps(spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def approval_ok(appr, key):
    """The canonical record, not a caller label: #N must exist in approvals.log and its record must name the FULL key (id.rev.fp = revision-bound)."""
    if not isinstance(appr, str) or not re.fullmatch(r"#[0-9]+", appr):
        return False
    try:
        p = subprocess.run([APPR_BIN, "--id", appr[1:]], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return False
    return p.returncode == 0 and re.search(r"(?<![A-Za-z0-9._-])" + re.escape(key) + r"(?![A-Za-z0-9._-])", p.stdout) is not None


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def rpath(d, k):
    return os.path.join(d, k + ".run.json")


def ipath(d, k):
    return os.path.join(d, k + ".inflight")


def proc_ticks(pid):
    """Process start time in clock ticks since boot (/proc/<pid>/stat field 22); None when the pid is gone or a zombie."""
    try:
        st = open("/proc/%d/stat" % pid).read()
        f = st[st.rindex(")") + 2:].split()
        return None if f[0] == "Z" else int(f[19])
    except (OSError, ValueError, IndexError):
        return None


def boot_id():
    try:
        return open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        return ""


def owner_alive(o):
    """A marker's owner is live only when its pid exists, its start ticks match and the boot is the same (pid reuse and reboot both read dead)."""
    try:
        return o.get("boot") == boot_id() and proc_ticks(int(o["pid"])) == o["ticks"]
    except (KeyError, TypeError, ValueError):
        return False


def child_alive(owner_pid):
    """True when any process other than ourselves is still in the dead owner's session/process group (the runner setsid()s, so its test tree shares it)."""
    me = os.getpid()
    for e in os.listdir("/proc"):
        if not e.isdigit() or int(e) == me:
            continue
        try:
            f = open("/proc/%s/stat" % e).read()
            f = f[f.rindex(")") + 2:].split()
            if f[0] != "Z" and (int(f[2]) == owner_pid or int(f[3]) == owner_pid):
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def read_marker(ip):
    """(raw bytes, parsed dict, stat) of a visible marker; parsed is None when empty/torn/not an object with an int pid (UNKNOWN, never dead). FileNotFoundError propagates."""
    with open(ip, "rb") as f:
        st = os.fstat(f.fileno())
        raw = f.read()
    try:
        o = json.loads(raw.decode())
    except ValueError:
        return raw, None, st
    return raw, (o if isinstance(o, dict) and isinstance(o.get("pid"), int) else None), st


def claim(d, k, spec=None):
    """Returns (marker, None) when we own the run, (None, 'inflight') when the owner is live OR UNKNOWN (empty/torn/unreadable marker): exit 75, retry later.
    The marker is published atomically (unique tmp file, then link() into place: EEXIST = someone owns it; no empty file is ever visible).
    A dead owner with no live child is taken over once: under <key>.claimlock the exact file judged dead (inode + bytes) is re-checked immediately
    before the rename; any change returns 'inflight'."""
    os.makedirs(d, exist_ok=True)
    ip = ipath(d, k)
    dg = digest(spec)
    mine = {"pid": os.getpid(), "ticks": proc_ticks(os.getpid()), "boot": boot_id(), "ts": now(), "key": k, "action_digest": dg, "intent": "started"}
    lk = os.open(os.path.join(d, k + ".claimlock"), os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        tmp = os.path.join(d, "%s.inflight.tmp.%d.%s" % (k, os.getpid(), os.urandom(4).hex()))
        with open(tmp, "w") as f:
            f.write(json.dumps(mine, indent=1) + "\n")
            f.flush(); os.fsync(f.fileno())   # the started record is durable before the action begins
        try:
            for _ in range(3):
                try:
                    os.link(tmp, ip)
                    return mine, None
                except FileExistsError:
                    pass
                try:
                    raw, o, st = read_marker(ip)
                except FileNotFoundError:
                    continue
                except OSError:
                    return None, "inflight"
                if o is None or owner_alive(o) or child_alive(o["pid"]):
                    return None, "inflight"
                if not (isinstance(spec, dict) and spec.get("idempotent") and o.get("action_digest") == dg and approval_ok(spec["idempotent"], k)):
                    return None, "unknown"   # dead owner, started record, no receipt: the effect may be done; no takeover without approved proof of idempotency
                try:   # identity re-check right before the rename: same inode, same bytes, or it is not the file we judged
                    raw2, _, st2 = read_marker(ip)
                except OSError:
                    return None, "inflight"
                if (st2.st_ino, st2.st_dev) != (st.st_ino, st.st_dev) or raw2 != raw:
                    return None, "inflight"
                stale = os.path.join(d, "%s.stale-%s-%s.json" % (k, o.get("pid"), o.get("ticks")))
                try:
                    os.rename(ip, stale)
                    o["taken_over_by"] = mine
                    with open(stale, "w") as f:
                        f.write(json.dumps(o, indent=1) + "\n")
                except FileNotFoundError:
                    pass
            return None, "inflight"
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    finally:
        os.close(lk)


def mark_unknown(d, k):
    """Surface-once marker: True only for the call that creates D/K.unknown.json (link, never replace)."""
    tmp = os.path.join(d, "%s.unknown.tmp.%d" % (k, os.getpid()))
    try:
        with open(tmp, "w") as f:
            f.write(json.dumps({"key": k, "state": "UNKNOWN", "reason": "dead owner left a started record and no receipt", "ts": now()}, indent=1) + "\n")
        try:
            os.link(tmp, os.path.join(d, k + ".unknown.json"))
            return True
        except FileExistsError:
            return False
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def release(d, k, mine):
    try:
        o = json.load(open(ipath(d, k)))
        if o.get("pid") == mine["pid"] and o.get("ticks") == mine["ticks"]:
            os.unlink(ipath(d, k))
    except (OSError, ValueError):
        pass


def write(d, k, obj):
    """First completed receipt wins: link() fails with EEXIST rather than replace. A later finisher is recorded as <key>.late.json only."""
    os.makedirs(d, exist_ok=True)
    tmp = rpath(d, k) + ".tmp%d" % os.getpid()
    open(tmp, "w").write(json.dumps(obj, indent=1) + "\n")
    try:
        os.link(tmp, rpath(d, k))
    except FileExistsError:
        os.replace(tmp, os.path.join(d, k + ".late.json"))
        return
    os.unlink(tmp)


def build(spec):
    """(argv, None) for an allowed spec, (None, reason) otherwise."""
    verb = spec.get("verb") if isinstance(spec, dict) else None
    if verb not in VERBS:
        return None, "verb not in allow-list: %r" % (verb,)
    key, rx = VERBS[verb]
    if set(spec) - {"verb", key, "idempotent"}:
        return None, "unexpected fields: %s" % ",".join(sorted(set(spec) - {"verb", key, "idempotent"}))
    if "idempotent" in spec and not (isinstance(spec["idempotent"], str) and re.fullmatch(r"#[0-9]+", spec["idempotent"])):
        return None, "bad idempotent"
    val = spec.get(key)
    if not isinstance(val, str) or not rx.fullmatch(val):
        return None, "bad %s" % key
    if verb == "named-test":
        path = os.path.join(os.environ.get("OBL_TESTS_DIR") or os.path.expanduser("~/dotfiles/tests"), val + ".test.sh")
        if not os.path.isfile(path):
            return None, "no such test"
        return ["bash", path], None
    return ["systemctl", "--user", "is-active", "--", val], None


def cmd_run(a):
    d, k = a["dir"], a["key"]
    if os.path.exists(rpath(d, k)):
        return 0   # replay after a restart: the receipt is the record, nothing runs twice
    try:
        spec = json.loads(a["action"])
    except (ValueError, TypeError):
        spec = None
    argv, why = build(spec)
    rec = {"key": k, "approval": a["approval"], "verb": (spec or {}).get("verb") if isinstance(spec, dict) else None, "spec": spec, "ts": now()}
    if argv is None:
        rec.update(status="refused", rc=126, reason=why, tail="")
        write(d, k, rec)
        return 0
    try:
        os.setsid()   # own session: the test tree is findable by session id (= our pid) after we die; EPERM = already a group leader, whose pgid is our pid
    except OSError:
        pass
    mine, why = claim(d, k, spec)
    if mine is None:
        out = {"key": k, "status": "in-flight", "result": "UNKNOWN", "retry": "later"}
        if why == "unknown":
            out["status"] = "unknown-started"
            out["first"] = mark_unknown(d, k)
        print(json.dumps(out))
        return EX_INFLIGHT
    try:
        os.unlink(os.path.join(d, k + ".unknown.json"))   # we own the key again (approved idempotent takeover or a reconciled release)
    except OSError:
        pass
    if os.path.exists(rpath(d, k)):   # the previous owner finished between our first look and our claim
        release(d, k, mine)
        return 0
    try:
        tmo = os.environ.get("OBL_RUN_TIMEOUT_SEC", "")   # owner-set hang guard; unset/empty/0 = none (no caps that only save time, Joe 11-01 #195)
        tmo = int(tmo) if tmo.isdigit() and int(tmo) > 0 else None
        p = subprocess.run(argv, capture_output=True, text=True, timeout=tmo, stdin=subprocess.DEVNULL)
        rec.update(status="ran", rc=p.returncode, tail=(p.stdout + p.stderr)[-500:])
    except subprocess.TimeoutExpired:
        rec.update(status="ran", rc=124, tail="owner-set timeout %s s" % tmo)
    except OSError as e:
        rec.update(status="ran", rc=127, tail=str(e)[:200])
    write(d, k, rec)
    release(d, k, mine)
    return 0


def cmd_reconcile(a):
    """Evidence-bound release of an UNKNOWN key (see the module doc). rc 0 = released/closed; 75 = still UNKNOWN (evidence missing, wrong, stale or unapproved); 64 = bad args."""
    d, k = a["dir"], a["key"]
    ip = ipath(d, k)
    def refuse(why):
        print(json.dumps({"key": k, "status": "unknown-started", "result": "UNKNOWN", "reconcile": "refused", "why": why}))
        return EX_INFLIGHT
    if os.path.exists(rpath(d, k)):
        return 0
    try:
        spec, ev = json.loads(a["action"]), json.loads(a.get("evidence", ""))
    except (ValueError, TypeError):
        return refuse("evidence-missing")
    if not isinstance(spec, dict) or not isinstance(ev, dict) or build(spec)[0] is None:
        return refuse("evidence-missing")
    recipe = ev.get("recipe")
    if set(ev) != {"key", "action_digest", "approval", "proves", "recipe"} or ev["proves"] not in ("done", "not-done") or not isinstance(recipe, dict):
        return refuse("evidence-malformed")
    rargv, _ = build(recipe)
    if rargv is None or {x: y for x, y in recipe.items() if x != "idempotent"} == {x: y for x, y in spec.items() if x != "idempotent"}:
        return refuse("recipe-not-allow-listed-or-not-independent")
    lk = os.open(os.path.join(d, k + ".claimlock"), os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            raw, o, st = read_marker(ip)
        except OSError:
            return refuse("no-started-record")
        if o is None or owner_alive(o) or child_alive(o["pid"]):
            return refuse("owner-live-or-marker-torn")
        if ev["key"] != k or o.get("key") != k or ev["action_digest"] != digest(spec) or o.get("action_digest") != ev["action_digest"]:
            return refuse("stale-evidence")
        if ev["approval"] != a["approval"] or not approval_ok(a["approval"], k):
            return refuse("unapproved-evidence")
        try:
            tmo = os.environ.get("OBL_RUN_TIMEOUT_SEC", "")
            p = subprocess.run(rargv, capture_output=True, text=True, timeout=int(tmo) if tmo.isdigit() and int(tmo) > 0 else None, stdin=subprocess.DEVNULL)
            proven, tail = p.returncode == 0, (p.stdout + p.stderr)[-300:]
        except (OSError, subprocess.SubprocessError):
            proven, tail = False, "recipe could not run"
        if not proven:
            return refuse("evidence-not-proven")
        try:
            raw2, _, st2 = read_marker(ip)
        except OSError:
            return refuse("marker-changed")
        if raw2 != raw or (st2.st_ino, st2.st_dev) != (st.st_ino, st.st_dev):
            return refuse("marker-changed")
        o["reconciled"] = {"approval": a["approval"], "proves": ev["proves"], "recipe": recipe, "ts": now()}
        if ev["proves"] == "done":
            write(d, k, {"key": k, "approval": a["approval"], "verb": spec.get("verb"), "spec": spec, "status": "reconciled-done", "rc": 0, "tail": tail, "evidence": o["reconciled"], "ts": now()})
        gone = os.path.join(d, "%s.released-%s-%s.json" % (k, o.get("pid"), o.get("ticks")))
        os.rename(ip, gone)
        with open(gone, "w") as f:
            f.write(json.dumps(o, indent=1) + "\n")
        try:
            os.unlink(os.path.join(d, k + ".unknown.json"))
        except OSError:
            pass
        print(json.dumps({"key": k, "status": "reconciled-" + ev["proves"], "result": "RELEASED"}))
        return 0
    finally:
        os.close(lk)


def cmd_check(a):
    try:
        r = json.load(open(rpath(a["dir"], a["key"])))
    except (OSError, ValueError):
        return 1
    return 0 if r.get("key") == a["key"] and r.get("rc") == 0 else 1


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("run", "check", "reconcile"):
        print(__doc__, file=sys.stderr); return 64
    a, args = {}, sys.argv[2:]
    for i in range(0, len(args) - 1, 2):
        a[args[i].lstrip("-")] = args[i + 1]
    need = ("dir", "key") + (("approval", "action") if sys.argv[1] == "run" else ("approval", "action") if sys.argv[1] == "reconcile" else ())
    if any(n not in a for n in need) or not re.fullmatch(r"[A-Za-z0-9._-]+", a["key"]):
        print("bad args", file=sys.stderr); return 64
    return {"run": cmd_run, "check": cmd_check, "reconcile": cmd_reconcile}[sys.argv[1]](a)


if __name__ == "__main__":
    sys.exit(main())
