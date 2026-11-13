import os, sys, importlib.util, json, pwd, tempfile
# Retained from the independent review-4 probes (S/in/review4-probes/seams.py), repointed at THIS clone; scratch under WR_PROBE_BASE (never /tmp). Prints one JSON line.
HERE = os.path.dirname(os.path.abspath(__file__)); R = os.environ["WR_PROBE_BASE"] + "/seams"; os.makedirs(R + "/tmp", exist_ok=True)
SRC = os.environ.get("WR_SRC") or os.path.realpath(HERE + "/../../../.local/bin/worker-route.py")
for k in ("WR_STATE","WR_HOST","WM_ASKS_CMD","WR_ASKS_BINDING","HOLD_GATE","WR_LAUNCHERS","WR_LAUNCHER_DIR","WR_START_CMD","WR_UNIT_PROBE","WR_ASKS_TIMEOUT"):
    os.environ[k] = "/nonexistent/" + k if k not in ("WR_HOST","WR_ASKS_TIMEOUT","WR_LAUNCHERS") else {"WR_HOST":"evilhost","WR_ASKS_TIMEOUT":"1","WR_LAUNCHERS":"evil.sh"}[k]
os.environ["HOME"] = R + "/tmp/fakehome"; os.environ.pop("WR_TEST_SEAMS", None)
spec = importlib.util.spec_from_file_location("wr", SRC); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
out = dict(STATE=m.STATE, passwd_home=pwd.getpwuid(os.getuid()).pw_dir == m.HOME, HOME_env_used=m.HOME == os.environ["HOME"], HOST_is_env=m.HOST == "evilhost",
  ASKS_CMD=m.ASKS_CMD, HOLD_GATE=m.HOLD_GATE, LAUNCHERS=m.LAUNCHERS, LAUNCHER_DIR=m.LAUNCHER_DIR, ASKS_TIMEOUT=m.ASKS_TIMEOUT, BINDING=m.BINDING)
# probe/start client without seams: monkeypatch STATE to scratch so nothing real is written
sc = R + "/tmp/seam-start.sh"; open(sc, "w").write("#!/bin/sh\necho CALLED \"$@\" > %s/tmp/seam-start.called\nexit 0\n" % R); os.chmod(sc, 0o755)
os.environ["WR_START_CMD"] = sc
if os.path.exists(R + "/tmp/seam-start.called"): os.unlink(R + "/tmp/seam-start.called")
m.STATE = R + "/tmp/seam-state"; m.ensure()
rec = {"invocation": "wr-A1-4-deadbeef", "ask": "A1", "unit": "worker-route-wr-A1-4-deadbeef", "requested": {}, "state": "intent"}
rc = m.begin_start(rec)
out["WR_START_CMD_honoured_without_seams"] = os.path.exists(R + "/tmp/seam-start.called")
# unit probe without seams: default systemctl; env WR_UNIT_PROBE ignored?
import unittest.mock as um
seen = []
with um.patch.object(m, "sh", lambda argv, timeout=120, env=None: (seen.append(argv) or (3, "", ""))):
    m.unit_probe("u")
out["unit_probe_argv0_without_seams"] = seen[0][:3]
print(json.dumps(out, default=str, sort_keys=True))
