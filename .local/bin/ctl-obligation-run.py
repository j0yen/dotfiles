#!/usr/bin/env python3
"""ctl-obligation-run.py: the typed approved-action runner for a suggestion-only obligation (W4).
  run   --dir D --key K --approval N --action '<json>'   run ONE allow-listed verb under the approval; write D/K.run.json (verb, args, rc, approval, tail, ts); idempotent.
        D/K.inflight (O_EXCL: pid, start ticks, boot id) is the owner; a live owner or live child => print in-flight, exit 75 (retry later), nothing starts.
        The first receipt wins (link, never replace); a late finisher writes D/K.late.json only.
  check --dir D --key K                                  exit 0 only when D/K.run.json exists for K with rc 0 (the ledger done-check: work evidence, never a manual touch)
Verbs (argv lists only, no shell, no interpolation of the spec into a command string):
  named-test    {"name": "<[a-z0-9][a-z0-9-]*>"}   bash $OBL_TESTS_DIR/<name>.test.sh (default ~/dotfiles/tests); no kill timer unless the owner sets OBL_RUN_TIMEOUT_SEC (default none)
  service-state {"unit": "<name>.service|.timer"}  systemctl --user is-active -- <unit> (read-only; unit starts alphanumeric)
Anything else, a bad argument, or a missing target is recorded as a receipt with status "refused" and rc 126; nothing is launched."""
import fcntl
import json, os, re, subprocess, sys, datetime

EX_INFLIGHT = 75   # EX_TEMPFAIL: another live runner owns this key (retry later); never a failure, never a second execution

VERBS = {
    "named-test": ("name", re.compile(r"[a-z0-9][a-z0-9-]{0,63}")),
    "service-state": ("unit", re.compile(r"[A-Za-z0-9][A-Za-z0-9@._-]{0,79}\.(service|timer)")),
}


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


def claim(d, k):
    """Returns (marker, None) when we own the run, (None, 'inflight') when the owner is live OR UNKNOWN (empty/torn/unreadable marker): exit 75, retry later.
    The marker is published atomically (unique tmp file, then link() into place: EEXIST = someone owns it; no empty file is ever visible).
    A dead owner with no live child is taken over once: under <key>.claimlock the exact file judged dead (inode + bytes) is re-checked immediately
    before the rename; any change returns 'inflight'."""
    os.makedirs(d, exist_ok=True)
    ip = ipath(d, k)
    mine = {"pid": os.getpid(), "ticks": proc_ticks(os.getpid()), "boot": boot_id(), "ts": now()}
    lk = os.open(os.path.join(d, k + ".claimlock"), os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        tmp = os.path.join(d, "%s.inflight.tmp.%d.%s" % (k, os.getpid(), os.urandom(4).hex()))
        with open(tmp, "w") as f:
            f.write(json.dumps(mine, indent=1) + "\n")
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
    if set(spec) - {"verb", key}:
        return None, "unexpected fields: %s" % ",".join(sorted(set(spec) - {"verb", key}))
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
    mine, _ = claim(d, k)
    if mine is None:
        print(json.dumps({"key": k, "status": "in-flight", "result": "UNKNOWN", "retry": "later"}))
        return EX_INFLIGHT
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


def cmd_check(a):
    try:
        r = json.load(open(rpath(a["dir"], a["key"])))
    except (OSError, ValueError):
        return 1
    return 0 if r.get("key") == a["key"] and r.get("rc") == 0 else 1


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("run", "check"):
        print(__doc__, file=sys.stderr); return 64
    a, args = {}, sys.argv[2:]
    for i in range(0, len(args) - 1, 2):
        a[args[i].lstrip("-")] = args[i + 1]
    need = ("dir", "key") + (("approval", "action") if sys.argv[1] == "run" else ())
    if any(n not in a for n in need) or not re.fullmatch(r"[A-Za-z0-9._-]+", a["key"]):
        print("bad args", file=sys.stderr); return 64
    return cmd_run(a) if sys.argv[1] == "run" else cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
