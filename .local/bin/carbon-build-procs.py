#!/usr/bin/env python3
"""carbon-build-procs.py - carbon's build-process alarm (Joe 10-27 "Nothing should be built nor coded on carbon", approvals #47).

Samples the local process table and writes ~/.cache/fleet-dash/carbon-build-procs.json; the fleet-dash collector reads that file
(the disk-health.json pattern) and merges `carbon.build_procs` into status.json. Two consecutive non-zero samples raise the alarm
`carbon-build-proc`.

MATCH (exact basename of comm or argv[0], never a substring): cargo rustc pytest wm-verify-run tsc make go; python running pytest
(`-m pytest` or a pytest script); plus any `tests/*.test.sh` argument when the process is bash/sh. EXCLUDED: this process, ssh, tmux,
grep/pgrep/rg/ps (an ssh client whose remote command is a cargo run counts 0 here). Command lines are redacted (40+ char token runs
become <redacted>).

  carbon-build-procs.py                 sample, write the file, print one summary line
  carbon-build-procs.py --json          sample, write the file, print it
  carbon-build-procs.py --ps-file F     read `ps -eo pid=,comm=,args=` output from F instead of running ps (tests)
Env: CBP_OUT (file; default ~/.cache/fleet-dash/carbon-build-procs.json) CBP_HOST (host label; default `hostname -s`)
"""
import json, os, re, subprocess, sys, time

NAMES = {"cargo", "rustc", "pytest", "wm-verify-run", "tsc", "make", "go"}
SHELLS = {"bash", "sh", "dash", "zsh"}
EXCLUDE = {"ssh", "tmux", "grep", "egrep", "pgrep", "rg", "ps", "sshd"}
TEST_SH = re.compile(r"(?:^|/)tests/[^\s]*\.test\.sh$")
REDACT = re.compile(r"[A-Za-z0-9_-]{40,}")


def host():
    h = os.environ.get("CBP_HOST")
    if h:
        return h
    try:
        return subprocess.run(["hostname", "-s"], capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def matches(comm, argv):
    a0 = os.path.basename(argv[0]) if argv else ""
    c = os.path.basename(comm)
    if c in EXCLUDE or a0 in EXCLUDE:
        return False
    if c in NAMES or a0 in NAMES:
        return True
    if re.match(r"^python[\d.]*$", c) or re.match(r"^python[\d.]*$", a0):
        rest = argv[1:]
        if rest and os.path.basename(rest[0]) in ("pytest", "py.test"):
            return True
        return len(rest) >= 2 and rest[0] == "-m" and rest[1] == "pytest"
    if c in SHELLS or a0 in SHELLS:
        return any(TEST_SH.search(x) for x in argv[1:])
    return False


def sample(text, me):
    procs = []
    for line in text.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        pid, comm = int(parts[0]), parts[1]
        args = parts[2] if len(parts) > 2 else comm
        if pid == me:
            continue
        if matches(comm, args.split()):
            procs.append(REDACT.sub("<redacted>", args)[:200])
    return procs


def main():
    argv = sys.argv[1:]
    ps_file = None
    if "--ps-file" in argv:
        ps_file = argv[argv.index("--ps-file") + 1]
    if ps_file:
        text = open(ps_file).read()
    else:
        text = subprocess.run(["ps", "-eo", "pid=,comm=,args="], capture_output=True, text=True, timeout=30).stdout
    procs = sample(text, os.getpid())
    path = os.environ.get("CBP_OUT") or os.path.expanduser("~/.cache/fleet-dash/carbon-build-procs.json")
    prev = 0
    try:
        prev = int(json.load(open(path)).get("consecutive", 0))
    except Exception:
        pass
    consec = prev + 1 if procs else 0
    now = time.time()
    doc = {"host": host(), "ts": int(now), "ts_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
           "carbon": {"build_procs": {"count": len(procs), "first3": procs[:3]}},
           "consecutive": consec, "alarms": ["carbon-build-proc"] if consec >= 2 else []}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(doc, f)
    os.replace(tmp, path)
    print(json.dumps(doc) if "--json" in argv else "carbon-build-procs: count=%d consecutive=%d%s" % (len(procs), consec, " ALARM carbon-build-proc" if consec >= 2 else ""))


main()
