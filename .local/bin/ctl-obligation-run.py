#!/usr/bin/env python3
"""ctl-obligation-run.py: the typed approved-action runner for a suggestion-only obligation (W4).
  run   --dir D --key K --approval N --action '<json>'   run ONE allow-listed verb under the approval; write D/K.run.json (verb, args, rc, approval, tail, ts); idempotent
  check --dir D --key K                                  exit 0 only when D/K.run.json exists for K with rc 0 (the ledger done-check: work evidence, never a manual touch)
Verbs (argv lists only, no shell, no interpolation of the spec into a command string):
  named-test    {"name": "<[a-z0-9][a-z0-9-]*>"}   bash $OBL_TESTS_DIR/<name>.test.sh (default ~/dotfiles/tests); no kill timer unless the owner sets OBL_RUN_TIMEOUT_SEC (default none)
  service-state {"unit": "<name>.service|.timer"}  systemctl --user is-active -- <unit> (read-only; unit starts alphanumeric)
Anything else, a bad argument, or a missing target is recorded as a receipt with status "refused" and rc 126; nothing is launched."""
import json, os, re, subprocess, sys, datetime

VERBS = {
    "named-test": ("name", re.compile(r"[a-z0-9][a-z0-9-]{0,63}")),
    "service-state": ("unit", re.compile(r"[A-Za-z0-9][A-Za-z0-9@._-]{0,79}\.(service|timer)")),
}


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def rpath(d, k):
    return os.path.join(d, k + ".run.json")


def write(d, k, obj):
    os.makedirs(d, exist_ok=True)
    tmp = rpath(d, k) + ".tmp%d" % os.getpid()
    open(tmp, "w").write(json.dumps(obj, indent=1) + "\n")
    os.replace(tmp, rpath(d, k))


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
        tmo = os.environ.get("OBL_RUN_TIMEOUT_SEC", "")   # owner-set hang guard; unset/empty/0 = none (no caps that only save time, Joe 11-01 #195)
        tmo = int(tmo) if tmo.isdigit() and int(tmo) > 0 else None
        p = subprocess.run(argv, capture_output=True, text=True, timeout=tmo, stdin=subprocess.DEVNULL)
        rec.update(status="ran", rc=p.returncode, tail=(p.stdout + p.stderr)[-500:])
    except subprocess.TimeoutExpired:
        rec.update(status="ran", rc=124, tail="owner-set timeout %s s" % tmo)
    except OSError as e:
        rec.update(status="ran", rc=127, tail=str(e)[:200])
    write(d, k, rec)
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
