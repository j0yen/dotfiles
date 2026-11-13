"""Mutation runner for tests/worker-route.test.sh (reviewer original in S/in/review2-probes/mutate.py, repointed at this clone and extended).
Each mutant is a one-edit copy of worker-route.py plus the test tree; a mutant is CAUGHT when the suite reports FAIL in BOTH runs.
usage: WR_MUT_BASE=<dir> mutate.py [names...]   (runs in parallel, WR_MUT_JOBS workers, default 4)"""
import os, sys, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.realpath(HERE + "/../..")
R = os.environ.get("WR_MUT_BASE") or "/tmp/wr-mut"
os.makedirs(R + "/tmp", exist_ok=True); os.makedirs(R + "/out", exist_ok=True)
M = [
 # review 1 (12 named) + review 2 (5 new)
 ("nonce", 't.get("nonce") != rec.get("nonce") or ', ''),
 ("host", 'if t.get("host") != HOST or rec.get("host") != HOST:', 'if False:'),
 ("unkhold", 'if prev is not None and prev.get("state") == "unknown-effect" and unknown_steps(inv):', 'if False:'),
 ("failedworker", 'if t.get("status") != "ok":', 'if False:'),
 ("holdgate", 'if not hold_ok(ask):', 'if False:'),
 ("claimmismatch", 'if not rows or claim_worker(rows[0].get("claim")) != rec["worker"]:', 'if not rows:'),
 ("allowlist", 'if "/" in name or name not in LAUNCHERS:', 'if False:'),
 ("expectrev", ', "--expect-rev", str(row.get("rev"))', ''),
 ("provinfer", '"provenance": prov or "unrecorded"', '"provenance": prov or {"account": "inferred"}'),
 ("allwaits", 'if not all(w in done for w in waits):', 'if False:'),
 ("finalreturn", 'if prev is not None and prev.get("state") in FINAL:\n        if prev.get("state") in FAILED_BEFORE_START:\n            late_terminal(inv, t, prev)\n        return', 'if False:\n        return'),
 ("unkrecheck", "        steps = unknown_steps(inv)\n        if steps:", "        steps = []\n        if steps:"),
 ("supervise_recheck", 'if launcher_path(lname) != rec.get("launcher"):', 'if False:'),
 ("startfailed_final", 'fail_before_start(rec, "start-failed", rc=rc, error=err.strip()[:200], proof="no-start-proven")', 'decide(decision="start-failed", ask=ask, invocation=inv, rc=rc)'),
 ("claimunknown_off", '    if back is not None:\n        # the store was READ', '    if True:\n        # the store was READ'),
 ("reclaim_always_conflict", 'if not (dead and dead.get("state") == "start-failed" and dead.get("ask") == ask)', 'if True or not (dead and dead.get("state") == "start-failed" and dead.get("ask") == ask)'),
 ("dead_ask_check", ' and dead.get("ask") == ask', ''),
 # repair 2: partial start / UNKNOWN / resume / binding
 ("claim127_final", '    if back is not None:\n        # the store was READ', '    if back is not None or rc == 127:\n        # the store was READ'),
 ("start_unknown_final", 'if ev == "none":', 'if ev != "started":'),
 ("probe_unreachable_absent", '    if rc != 0:\n        return "unknown"\n    kv =', '    if rc != 0:\n        return "absent"\n    kv ='),
 ("marker_ignored", '(("started", ".json"), ("terminals", ".json"), ("effects", ".effect"), ("prov", ".json"))', '(("terminals", ".json"), ("effects", ".effect"), ("prov", ".json"))'),
 ("unit_present_ignored", '{"present": "started", "absent": "none"}.get(u, "unknown")', '{"present": "none", "absent": "none"}.get(u, "unknown")'),
 ("late_dropped", '            late_terminal(inv, t, prev)\n', '            pass\n'),
 ("adopt_late_evidence", '\\\n                or evidence_of_run(claim_worker(cur)):', ':'),
 ("resume_any_claim", 'if back and claim_worker(back[0].get("claim")) == rec["worker"]:\n            decide(decision="claim-resumed"', 'if back:\n            decide(decision="claim-resumed"'),
 ("resume_unreadable_failed", 'decide(decision="resume-pending", invocation=inv, ask=ask, note="UNKNOWN: the canonical store is still unreadable; nothing changed")\n            return 4', 'fail_before_start(rec, "claim-failed", rc=None)\n            return 5'),
 ("supervise_final_guard", 'if fin is not None and fin.get("state") in FAILED_BEFORE_START:', 'if False:'),
 ("bind_sha_off", 'b.get("sha256") == ident[1] and ', ''),
 ("bind_host_off", ' and b.get("host") == HOST', ''),
 ("bind_store_off", '\n            and si is not None and si == b.get("store"))', ')'),
 ("bind_exe_off", 'return (b.get("executable") == ident[0] and ', 'return (True and '),
 ("launch_unbound_ok", '    if not require_bound("launch"):\n        return 77\n', ''),
 ("consume_unbound_ok", '    if not require_bound("consume"):\n        return 77\n', ''),
 ("resume_unbound_ok", '    if not require_bound("resume"):\n        return 77\n', ''),
 ("resume_final_ok", ' or (c is not None and c.get("state") in FINAL)', ''),
]
def one(n, o, nw):
    D = R + "/tmp/mut-" + n; shutil.rmtree(D, ignore_errors=True); os.makedirs(D)
    ig = shutil.ignore_patterns("*.pyc", "__pycache__")
    shutil.copytree(REPO + "/.local", D + "/.local", ignore=ig); shutil.copytree(REPO + "/tests", D + "/tests", ignore=ig)
    p = D + "/.local/bin/worker-route.py"; s = open(p).read()
    if s.count(o) < 1:
        return n, None, ["PATTERN MISSING"]
    open(p, "w").write(s.replace(o, nw, 1))
    fails = []
    for i in range(2):
        out = subprocess.run(["bash", D + "/tests/worker-route.test.sh"], capture_output=True, text=True, env=dict(os.environ, TMPDIR=R + "/tmp")).stdout
        open(R + "/out/mut-%s.%d.log" % (n, i), "w").write(out)
        fails.append([l[:110] for l in out.splitlines() if l.startswith("FAIL ")])
    return n, fails, None
which = sys.argv[1:]
todo = [m for m in M if not which or m[0] in which]
with ThreadPoolExecutor(int(os.environ.get("WR_MUT_JOBS") or 4)) as ex:
    res = list(ex.map(lambda m: one(*m), todo))
caught = 0
for n, fails, err in res:
    if err:
        print(n, err[0]); continue
    c = bool(fails[0]) and bool(fails[1]); caught += c
    print("%-26s %s runs=%d/%d | first: %s" % (n, "CAUGHT" if c else "SURVIVED", len(fails[0]), len(fails[1]), (fails[0] or fails[1] or ["-"])[0]))
print("caught %d/%d" % (caught, len(res)))
