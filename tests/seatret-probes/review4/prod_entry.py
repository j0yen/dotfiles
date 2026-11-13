#!/usr/bin/env python3
"""Review 4 (R4-1 + seams_prod_clean): drives the REAL production entrypoint (.local/bin/worker-route.py executed as `__main__` through runpy, the same code path as
`python3 worker-route.py <cmd>`) with every test-seam env var forged, WITH and WITHOUT the WR_TEST_SEAMS switch, and proves production never moves onto a seam.
The only substitution is the passwd home (pwd.getpwuid patched to a scratch dir) so nothing is written under the real home; PATH holds recording stubs for
systemd-run / systemctl (never the real ones). Source-fixture evidence only: it does not prove the installed behaviour."""
import json, os, shutil, socket, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE + "/..")
import fakes
PROD = os.path.realpath(HERE + "/../../../.local/bin/worker-route.py")
BASE = os.path.join(fakes.BASE, "prod-entry"); shutil.rmtree(BASE, ignore_errors=True); os.makedirs(BASE)
HOST = socket.gethostname().split(".")[0]
RUNNER = ("import os, pwd, runpy, sys\n"
          "class PW: pw_dir = os.environ['WR_SCRATCH_PASSWD_HOME']\n"
          "pwd.getpwuid = lambda uid: PW()\n"
          "sys.argv = [sys.argv[1]] + sys.argv[2:]\n"
          "runpy.run_path(sys.argv[0], run_name='__main__')\n")
fails = 0
def ok(n): print("PASS " + n)
def bad(n, why):
    global fails; fails += 1; print("FAIL %s: %s" % (n, why))
def chk(n, cond, why=""):
    ok(n) if cond else bad(n, why)
REC = lambda log: "#!/bin/sh\necho \"$0 $*\" >> %s\nexit 1\n" % log
def mkexe(p, body): open(p, "w").write(body); os.chmod(p, 0o755)
def world(name):
    w = os.path.join(BASE, name); os.makedirs(w + "/stub"); os.makedirs(w + "/bin"); os.makedirs(w + "/forged"); os.makedirs(w + "/stubs-path")
    ph = w + "/passwd-home"; os.makedirs(ph + "/.local/bin")
    mkexe(w + "/bin/wm-asks", fakes.FAKE_ASKS)
    mkexe(ph + "/.local/bin/hold-gate.sh", "#!/bin/sh\nexit 0\n")
    mkexe(ph + "/.local/bin/rb-coder-launch.sh", "#!/bin/sh\necho child >> \"$STUB/child.log\"\nexit 0\n")
    for n in ("hold", "launcher", "start", "probe", "self", "decoy"):
        mkexe(w + "/forged/" + n, REC(w + "/forged/%s.called" % n))
    mkexe(w + "/forged/evil.sh", REC(w + "/forged/launcher.called"))
    mkexe(w + "/stubs-path/systemd-run", "#!/bin/sh\necho \"$*\" >> \"$STUB/sdrun.log\"\n[ -e \"$STUB/sdrun-fail\" ] && exit 1\nexit 0\n")
    mkexe(w + "/stubs-path/systemctl", "#!/bin/sh\necho \"$*\" >> \"$STUB/systemctl.log\"\nprintf 'LoadState=not-found\\nActiveState=inactive\\n'\nexit 0\n")
    json.dump({"A1": {"ask_id": "A1", "rev": 4, "owner": "r7", "status": "open", "claim": None, "waits_on": [],
                      "what": "t. worker-route: host=%s launcher=rb-coder-launch.sh arg=a1" % HOST}}, open(w + "/stub/db.json", "w"))
    return w
def forged_env(w, switch):
    e = dict(PATH=w + "/stubs-path:/usr/bin:/bin", HOME=w + "/forged-home", STUB=w + "/stub", WR_SCRATCH_PASSWD_HOME=w + "/passwd-home",
             WR_STATE=w + "/forged-state", WR_HOST="forged-host", WM_ASKS_CMD=w + "/forged/decoy", WR_ASKS_BINDING=w + "/forged/binding.json", HOLD_GATE=w + "/forged/hold",
             WR_LAUNCHERS="evil.sh", WR_LAUNCHER_DIR=w + "/forged", WR_START_CMD=w + "/forged/start", WR_UNIT_PROBE=w + "/forged/probe", WR_SELF=w + "/forged/self",
             WR_ASKS_TIMEOUT="1", WR_SRC=w + "/forged/evil.sh")
    if switch: e["WR_TEST_SEAMS"] = "1"
    return e
def prod(w, env, *args):
    p = subprocess.run([sys.executable, "-I", "-c", RUNNER, PROD] + list(args), env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
    return p.returncode, [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")], p.stderr
def dec(ds): return [d["decision"] for d in ds]
def called(w, n): return os.path.exists("%s/forged/%s.called" % (w, n))
def readlog(p):
    try: return open(p).read().splitlines()
    except OSError: return []

for switch in (False, True):
    tag = "switch" if switch else "no-switch"
    w = world(tag); env = forged_env(w, switch)
    rc0, d0, _ = prod(w, env, "launch", "A1")
    chk("S1 %s: production launch with NO binding is refused 77, the forged WM_ASKS_CMD decoy never runs" % tag, rc0 == 77 and not called(w, "decoy") and dec(d0) == ["asks-unbound"], "rc=%s %s" % (rc0, dec(d0)))
    rcb, db_, err = prod(w, env, "bind", "--executable", os.path.realpath(w + "/bin/wm-asks"), "--store", w + "/stub/db.json", "--by", "owner")
    sd = w + "/passwd-home/.local/state/worker-route"
    chk("S2 %s: production bind writes the binding under the PASSWD home state dir; the forged WR_STATE / HOME / WR_ASKS_BINDING are never created or used" % tag,
        rcb == 0 and os.path.exists(sd + "/asks-binding.json") and not os.path.exists(w + "/forged-state") and not os.path.exists(w + "/forged-home") and not os.path.exists(w + "/forged/binding.json"), "rc=%s err=%s" % (rcb, err[-200:]))
    rc, ds, err = prod(w, env, "launch", "A1")
    sd_log = readlog(w + "/stub/sdrun.log")
    chk("S3 %s: production launch honours the real hostname (forged WR_HOST ignored), the real hold gate (forged HOLD_GATE not run), the bound executable (decoy not run), the default launcher allowlist/dir (forged WR_LAUNCHERS/WR_LAUNCHER_DIR ignored)" % tag,
        rc == 0 and dec(ds)[-1:] == ["launched"] and not called(w, "hold") and not called(w, "decoy") and not called(w, "launcher"), "rc=%s %s err=%s" % (rc, dec(ds), err[-200:]))
    chk("S4 %s (R4-1): the start client is systemd-run on PATH, run once, for THIS production script as supervisor; the forged WR_START_CMD and WR_SELF are never run" % tag,
        len(sd_log) == 1 and sd_log[0].startswith("--user --collect --unit worker-route-wr-A1-4-") and sd_log[0].split()[-2:-1] == ["supervise"] and PROD in sd_log[0] and not called(w, "start") and not called(w, "self"), "sdrun=%s start=%s self=%s" % (sd_log, called(w, "start"), called(w, "self")))
    # the unit probe seam: a failed start client is reconciled with the DEFAULT systemctl (PATH stub), never the forged WR_UNIT_PROBE
    w2 = world(tag + "-probe"); env2 = forged_env(w2, switch)
    prod(w2, env2, "bind", "--executable", os.path.realpath(w2 + "/bin/wm-asks"), "--store", w2 + "/stub/db.json", "--by", "owner"); open(w2 + "/stub/sdrun-fail", "w").close()
    rcp, dsp, _ = prod(w2, env2, "launch", "A1")
    chk("S5 %s: a failed start client is reconciled by the default `systemctl --user show` (PATH stub); the forged WR_UNIT_PROBE is never run" % tag,
        any(l.startswith("--user show") for l in readlog(w2 + "/stub/systemctl.log")) and not called(w2, "probe"), "rc=%s %s systemctl=%s probe=%s" % (rcp, dec(dsp), readlog(w2 + "/stub/systemctl.log"), called(w2, "probe")))
# R4-1 class, one variable at a time WITHOUT the switch: no single env var moves production
for var in ("WR_START_CMD", "WR_UNIT_PROBE", "WR_SELF", "HOLD_GATE", "WR_LAUNCHERS", "WR_LAUNCHER_DIR", "WR_HOST", "WR_STATE", "WM_ASKS_CMD", "WR_ASKS_BINDING", "WR_ASKS_TIMEOUT", "WR_SRC"):
    w = world("one-" + var); full = forged_env(w, False)
    env = {k: v for k, v in full.items() if k in ("PATH", "HOME", "STUB", "WR_SCRATCH_PASSWD_HOME", var)}
    prod(w, env, "bind", "--executable", os.path.realpath(w + "/bin/wm-asks"), "--store", w + "/stub/db.json", "--by", "owner")
    rc, ds, _ = prod(w, env, "launch", "A1")
    sdl = readlog(w + "/stub/sdrun.log")
    chk("S6 %s alone (no switch): production still launches through systemd-run exactly once and runs no forged program" % var,
        rc == 0 and len(sdl) == 1 and not any(called(w, n) for n in ("hold", "launcher", "start", "probe", "self", "decoy")) and not os.path.exists(w + "/forged-state"),
        "rc=%s %s sdrun=%d forged=%s" % (rc, dec(ds), len(sdl), [n for n in ("hold", "launcher", "start", "probe", "self", "decoy") if called(w, n)]))
# static class: every os.environ read in the production source is either the switch (import-only), systemd's INVOCATION_ID record, the child environment copy, or a _seam
import re
src = open(PROD).read()
reads = [l for l in src.splitlines() if "os.environ" in l]
allowed = ("WR_TEST_SEAMS", "INVOCATION_ID", "dict(os.environ)", "os.environ.get(name)")
rogue = [r for r in reads if not any(a in r for a in allowed) and not r.lstrip().startswith("#")]
direct = [r for r in re.findall(r"os\.environ\.get\(\"(WR_[A-Z_]+|WM_[A-Z_]+|HOLD_GATE)\"", src) if r != "WR_TEST_SEAMS"]
chk("S7: no production-code env read other than the import-only switch, INVOCATION_ID and the child env copy (a seam is read only through _seam)", not rogue and not direct, "rogue=%s direct=%s" % (rogue, direct))
print("ALL PASS" if not fails else "FAILURES: %d" % fails)
sys.exit(1 if fails else 0)
