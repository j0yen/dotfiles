"""walk_guard_selftest.py -- case table for walk-guard, run through the REAL walk-guard.sh entry point.

Every case: (name, host, command, expect) with expect in pass | warn | refuse. A refuse case must
print a rewritten command (W7) and that rewritten command must itself pass the hook (pass or warn).
`--write-state` writes ~/.local/state/watchers/_walkhook.json. A deliberately broken engine
(WALK_GUARD_FAULT=1) is also exercised: it must refuse an ssh to a build host and pass the rest.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ENTRY = os.path.join(HERE, "walk-guard.sh")
BEGIN = "--- rewritten command (run this) ---"
END = "--- end rewritten command ---"
WRAP = "ionice -c3 nice -n19 timeout 600"

CASES = [
    # --- (b) ssh forms, run from carbon ---
    ("ssh single-quoted grep -r", "carbon",
     "ssh redbaron 'grep -rlE \"EXPIRES=|PREMISE=\" /mnt/data/hand ~/.local/bin'", "refuse"),
    ("ssh double-quoted grep -r", "carbon", 'ssh ryzen7 "grep -rl foo /mnt/ssd/hand"', "refuse"),
    ("ssh heredoc bash -s", "carbon",
     "ssh redbaron 'bash -s' <<EOF\ngrep -r foo /mnt/data/hand\nEOF", "refuse"),
    ("ssh heredoc with host flags", "carbon",
     "ssh -o BatchMode=yes -T redbaron bash -s <<'EOF'\necho hi\nfind /mnt/data -name x\nEOF", "refuse"),
    ("ssh find", "carbon", "ssh redbaron 'find /mnt/data/hand -name \"*.sh\"'", "refuse"),
    ("ssh find with -o expression", "carbon",
     "ssh redbaron 'find /mnt/data/hand -name a -o -name b'", "refuse"),
    ("ssh du", "carbon", "ssh redbaron 'du -sh /mnt/data'", "refuse"),
    ("ssh rg", "carbon", "ssh redbaron 'rg EXPIRES /mnt/data/hand'", "refuse"),
    ("ssh ls -R", "carbon", "ssh redbaron 'ls -R /mnt/ssd'", "refuse"),
    ("ssh partially wrapped (no timeout)", "carbon",
     "ssh redbaron 'ionice -c3 nice -n19 grep -r foo /mnt/data/hand'", "refuse"),
    ("ssh timeout over cap", "carbon",
     "ssh redbaron 'ionice -c3 nice -n19 timeout 3600 grep -r foo /mnt/data/hand'", "refuse"),
    ("ssh home walk", "carbon", "ssh redbaron 'grep -r foo ~'", "refuse"),
    ("ssh pipeline after ssh", "carbon", "ssh redbaron 'grep -r foo /mnt/data/hand' | head -5", "refuse"),
    ("ssh ancestor root /", "carbon", "ssh redbaron 'find / -name x'", "refuse"),
    # --- W5: fully wrapped = allow + WARN ---
    ("W5 fully wrapped du", "carbon",
     "ssh redbaron 'ionice -c3 nice -n19 timeout 600 du -x --max-depth=1 /mnt/data'", "warn"),
    ("W5 fully wrapped grep with prunes", "carbon",
     "ssh redbaron 'ionice -c3 nice -n19 timeout 600 grep -r --exclude-dir=target --exclude-dir=.cargo foo /mnt/data/hand'", "warn"),
    ("W5 wrapped, shorter timeout", "carbon",
     "ssh redbaron 'ionice -c3 nice -n19 timeout 120 grep -rl foo /mnt/ssd'", "warn"),
    ("W5 wt/<slug>/src passes", "carbon",
     "ssh redbaron 'grep -r foo /mnt/data/wm-build/wt/some-slug/src'", "pass"),
    ("W5 wt root exactly is guarded", "carbon",
     "ssh redbaron 'find /mnt/data/wm-build/wt -maxdepth 1'", "refuse"),
    ("W5 /mnt/data/hand unwrapped refused", "carbon", "ssh redbaron 'grep -r x /mnt/data/hand'", "refuse"),
    ("small named dir passes", "carbon", "ssh redbaron 'grep -r foo /etc/systemd'", "pass"),
    ("non-recursive grep passes", "carbon", "ssh redbaron 'grep foo /mnt/data/hand/one.txt'", "pass"),
    ("ls without -R passes", "carbon", "ssh redbaron 'ls /mnt/data'", "pass"),
    ("ssh to a non-build host passes", "carbon", "ssh hub 'grep -r foo /mnt/data/hand'", "pass"),
    ("ssh to orch passes", "carbon", "ssh orch 'grep -r foo /mnt/data/hand'", "pass"),
    ("ssh no command passes", "carbon", "ssh redbaron", "pass"),
    # --- W4: hosts ---
    ("W4 carbon local walk passes", "carbon", "grep -r foo /mnt/data/hand", "pass"),
    ("W4 carbon local find home passes", "carbon", "find ~ -name x", "pass"),
    ("W4 redbaron local grep refused", "redbaron", "grep -r foo /mnt/data/hand", "refuse"),
    ("W4 ryzen7 local find refused", "ryzen7", "find /mnt/ssd -name x", "refuse"),
    ("W4 redbaron local wrapped warns", "redbaron",
     "ionice -c3 nice -n19 timeout 300 find /mnt/data/hand -name x", "warn"),
    ("W4 redbaron local small dir passes", "redbaron", "grep -r foo /etc", "pass"),
    ("W4 redbaron cd then relative walk", "redbaron", "cd /mnt/data/hand && grep -r foo .", "refuse"),
    ("W4 redbaron bash -c walk", "redbaron", "bash -c 'grep -r foo /mnt/data/hand'", "refuse"),
    ("W4 redbaron command substitution walk", "redbaron", "n=$(grep -rl foo /mnt/data/hand | wc -l)", "refuse"),
    ("W4 orch local walk passes", "orch", "grep -r foo /mnt/data/hand", "pass"),
    ("W4 orch ssh walk passes", "orch", "ssh redbaron 'grep -r foo /mnt/data/hand'", "pass"),
    # --- W2: client-side bypass forms are known-pass (the remote watcher is the real guard) ---
    ("W2 ssh bash script file", "carbon", "ssh redbaron bash /home/jsy/x.sh", "pass"),
    ("W2 ssh bash -c variable", "carbon", "CMD='grep -r foo /mnt/data/hand'; ssh redbaron bash -c \"$CMD\"", "pass"),
    ("W2 ssh python os.walk", "carbon",
     "ssh redbaron 'python3 -c \"import os; list(os.walk(\\\"/mnt/data\\\"))\"'", "pass"),
    ("W2 ssh variable command", "carbon", "CMD='find /mnt/data'; ssh redbaron \"$CMD\"", "pass"),
    ("W2 scp passes", "carbon", "scp redbaron:/mnt/data/hand/x.txt /tmp/", "pass"),
    # --- unrelated commands pass ---
    ("plain ls passes", "redbaron", "ls -la /mnt/data/hand", "pass"),
    ("git status passes", "carbon", "git -C ~/dotfiles status --short", "pass"),
    ("empty-ish command passes", "carbon", "true", "pass"),
]


def run(host, command, extra_env=None, payload=None):
    env = dict(os.environ)
    env["WALK_GUARD_HOST"] = host
    env.pop("WALK_GUARD_FAULT", None)
    env.update(extra_env or {})
    data = payload if payload is not None else json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    p = subprocess.run(["bash", ENTRY], input=data, capture_output=True, text=True, env=env, timeout=30)
    return p.returncode, p.stdout, p.stderr


def classify(rc, out, err):
    if rc == 2:
        return "refuse"
    if rc == 0 and "walk-hook WARN" in out:
        return "warn"
    if rc == 0 and not out.strip():
        return "pass"
    return "other(rc=%s)" % rc


def rewritten(err):
    if BEGIN not in err or END not in err:
        return None
    return err.split(BEGIN, 1)[1].split(END, 1)[0].strip("\n")


def main(argv):
    results, fails = [], []
    for name, host, cmd, expect in CASES:
        rc, out, err = run(host, cmd)
        got = classify(rc, out, err)
        ok = got == expect
        detail = ""
        if ok and expect == "refuse":
            new = rewritten(err)
            if new is None:
                ok, detail = False, "refusal printed no rewritten command"
            elif WRAP not in new:
                ok, detail = False, "rewritten command lacks wrappers: %r" % new
            else:
                rc2, out2, err2 = run(host, new)
                got2 = classify(rc2, out2, err2)
                if got2 not in ("pass", "warn"):
                    ok, detail = False, "W7: printed line is %s, not pass/warn: %r" % (got2, new)
        results.append({"case": name, "host": host, "expect": expect, "got": got, "ok": ok, "detail": detail})
        if not ok:
            fails.append("%s: expected %s, got %s %s | cmd=%r | err=%r" % (name, expect, got, detail, cmd, err[-300:]))

    # internal error behaviour (W3): a broken engine blocks an ssh to a build host, passes the rest
    fault = {"WALK_GUARD_SELFTEST": "1", "WALK_GUARD_FAULT": "1"}
    for name, host, cmd, want in (
            ("W3 fault + ssh build host -> internal error", "carbon", "ssh redbaron 'ls /tmp'", 2),
            ("W3 fault + non-matching passes", "carbon", "git status", 0)):
        rc, out, err = run(host, cmd, fault)
        ok = rc == want and (want == 0 or "walk-hook internal error" in err)
        results.append({"case": name, "host": host, "expect": "rc=%d" % want, "got": "rc=%d" % rc, "ok": ok, "detail": ""})
        if not ok:
            fails.append("%s: rc=%s err=%r" % (name, rc, err[-200:]))

    # W7 spot check: the printed refusal for the canonical scout command is the exact documented shape
    rc, out, err = run("carbon", "ssh redbaron 'grep -rlE \"EXPIRES=|PREMISE=\" /mnt/data/hand'")
    new = rewritten(err) or ""
    shape = "ionice -c3 nice -n19 timeout 600 grep" in new and "--exclude-dir=target" in new and "--exclude-dir=.cargo" in new
    results.append({"case": "W7 canonical rewrite shape", "host": "carbon", "expect": "shape", "got": new, "ok": shape, "detail": ""})
    if not shape:
        fails.append("canonical rewrite shape wrong: %r" % new)

    n_ok = sum(1 for r in results if r["ok"])
    for line in fails:
        print("FAIL " + line)
    print("walk-guard selftest: %d/%d passed" % (n_ok, len(results)))
    if "--write-state" in argv:
        write_state(n_ok, len(results), fails)
    return 0 if not fails else 1


def write_state(n_ok, n, fails):
    d = os.path.join(os.path.expanduser("~"), ".local", "state", "watchers")
    os.makedirs(d, exist_ok=True)
    doc = {"watcher": "walkhook", "ts": int(time.time()), "ok": not fails, "passed": n_ok, "total": n,
           "failed": [f.split(":")[0] for f in fails],
           "alarm": None if not fails else "walk-hook-selftest-failed",
           "premise": "walk-guard contract + hook installed by dotfiles", "expires": None}
    tmp = os.path.join(d, "._walkhook.json.tmp")
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(tmp, os.path.join(d, "_walkhook.json"))
