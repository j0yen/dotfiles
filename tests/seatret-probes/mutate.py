"""Mutation runner for tests/worker-route.test.sh (reviewer original in S/in/review2-probes/mutate.py, repointed at this clone and extended).
Each mutant is a one-edit copy of worker-route.py plus the test tree; a mutant is CAUGHT when the suite (all five worker-route test scripts) reports FAIL in BOTH runs.
usage: WR_MUT_BASE=<dir> mutate.py [names...]   (runs in parallel, WR_MUT_JOBS workers, default 4)"""
import os, sys, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.realpath(HERE + "/../..")
R = os.environ.get("WR_MUT_BASE")
if not R or R == "/tmp" or R.startswith(("/tmp/", "/var/tmp")):          # R3-5: no default scratch under /tmp
    sys.stderr.write("mutate.py: set WR_MUT_BASE to a scratch directory outside /tmp\n"); sys.exit(64)
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
 ("reclaim_always_conflict", '        if verdict != "ok":\n            decide(decision="claim-conflict"', '        if True:\n            decide(decision="claim-conflict"'),
 ("dead_ask_check", ' or c.get("ask") != ask:\n            return "chain-member-', ':\n            return "chain-member-'),
 # repair 2: partial start / UNKNOWN / resume / binding
 ("claim127_final", '    if back is not None:\n        # the store was READ', '    if back is not None or rc == 127:\n        # the store was READ'),
 ("start_unknown_final", 'if ev == "none":', 'if ev != "started":'),
 ("probe_unreachable_absent", '    if rc != 0:\n        return "unknown"\n    kv =', '    if rc != 0:\n        return "absent"\n    kv ='),
 ("marker_ignored", '(("started", ".json"), ("terminals", ".json"), ("effects", ".effect"), ("prov", ".json"))', '(("terminals", ".json"), ("effects", ".effect"), ("prov", ".json"))'),
 ("unit_present_ignored", '{"present": "started", "absent": "none"}.get(u, "unknown")', '{"present": "none", "absent": "none"}.get(u, "unknown")'),
 ("late_dropped", '            late_terminal(inv, t, prev)\n', '            pass\n'),
 ("adopt_late_evidence", 'if evidence_of_run(r["invocation"]):', 'if False:'),
 ("resume_any_claim", 'if back and claim_worker(back[0].get("claim")) == rec["worker"]:\n            decide(decision="claim-resumed"', 'if back:\n            decide(decision="claim-resumed"'),
 ("resume_unreadable_failed", 'decide(decision="resume-pending", invocation=inv, ask=ask, note="UNKNOWN: the canonical store is still unreadable; nothing changed")\n            return 4', 'fail_before_start(rec, "claim-failed", rc=None)\n            return 5'),
 ("supervise_final_guard", 'if fin is not None and fin.get("state") in FAILED_BEFORE_START:', 'if False:'),
 ("bind_sha_off", 'b.get("sha256") == ident[1] and ', ''),
 ("bind_host_off", ' and b.get("host") == HOST', ''),
 ("bind_store_off", '\n          and si is not None and si == b.get("store") and trusted_file(ident[0])', ' and trusted_file(ident[0])'),
 ("bind_exe_off", 'ok = (b.get("executable") == ident[0] and ', 'ok = (True and '),
 ("launch_unbound_ok", '    if not require_bound("launch"):\n        return 77\n', ''),
 ("consume_unbound_ok", '    if not require_bound("consume"):\n        return 77\n', ''),
 ("resume_unbound_ok", '    if not require_bound("resume"):\n        return 77\n', ''),
 ("resume_final_ok", ' or (c is not None and c.get("state") in FINAL)', ''),
 # repair 3 (R3-1..R3-6)
 ("r3_chain_claimant_only", 'r.get("worker") == token and r.get("invocation"):', 'r.get("worker") == token and r.get("invocation") == token:'),
 ("r3_chain_open_ignored", '        if c is None or c.get("state") not in FINAL:\n            return "open", r["invocation"]', '        if False:\n            return "open", r["invocation"]'),
 ("r3_chain_state_off", 'if c.get("state") != "start-failed" or c.get("ask") != ask:', 'if False:'),
 ("r3_chain_host_off", '        if r.get("host") != HOST:\n            return "chain-member-other-host", []', '        if False:\n            return "chain-member-other-host", []'),
 ("r3_reprobe_off", 'if u != "absent":', 'if False:'),
 ("r3_reprobe_unknown_as_conflict", 'return 5 if u == "present" else 7', 'return 5'),
 ("r3_finish_lock_off", 'lk = FileLock("start-" + rec["invocation"])\n    lk.acquire()\n    try:', 'lk = FileLock("start-" + rec["invocation"])\n    try:'),
 ("r3_supervise_lock_off", '    lk.acquire()\n    try:\n        fin = load(', '    try:\n        fin = load('),
 ("r3_seams_always", 'SEAMS = __name__ != "__main__" and os.environ.get("WR_TEST_SEAMS") == "1"', 'SEAMS = True'),
 ("r3_binding_env", 'BINDING = os.path.join(STATE, "asks-binding.json")', 'BINDING = os.environ.get("WR_ASKS_BINDING") or os.path.join(STATE, "asks-binding.json")'),
 ("r3_exec_by_name", 'return sh([exe] + list(args), timeout=ASKS_TIMEOUT)', 'return sh([(ASKS_CMD[0] if SEAMS else exe)] + list(args), timeout=ASKS_TIMEOUT)'),
 ("r3_sha_recheck_off", 'if file_sha(exe) != sha:', 'if False:'),
 ("r3_trusted_off", '    return os.path.isfile(path) and st.st_uid', '    return True or os.path.isfile(path) and st.st_uid'),
 ("r3_unit_probe_env", 'pc = _seam("WR_UNIT_PROBE")', 'pc = os.environ.get("WR_UNIT_PROBE")'),
 ("r3_shape_off", 'ROW_KEYS = ("ask_id", "rev", "status", "claim")', 'ROW_KEYS = ()'),
 ("r3_waits_unverified_off", 'if "waits_on" not in row:', 'if False:'),
 # the reviewer's own 12 mutants (S/in/review3-probes/own_mutate.py), patterns adapted to the repaired code where the guarded line moved (o6 -> chain host check)
 ("o1_resume_start_unknown_always_final", 'rc = finish_start(rec, None)\n    decide(decision="resumed"', 'fail_before_start(rec, "start-failed", rc=None, proof="x"); rc = 1\n    decide(decision="resumed"'),
 ("o2_trust_claim_rc_not_readback", 'if back and claim_worker(back[0].get("claim")) == inv:\n        return begin_start(rec)', 'if rc == 0:\n        return begin_start(rec)'),
 ("o3_unreadable_readback_is_success", '    # claim result unreadable AND the readback unavailable', '    if back is None:\n        return begin_start(rec)\n    # claim result unreadable AND the readback unavailable'),
 ("o4_started_evidence_ignored", 'if ev == "started":\n        rec["state"] = "launched"', 'if False:\n        rec["state"] = "launched"'),
 ("o5_own_inflight_check_dropped", '        if c is None or c.get("state") not in FINAL:\n            return "open", r["invocation"]', '        if False:\n            return "open", r["invocation"]'),   # adapted: the own-invocation check is now the chain-open check (the old `mine` branch was subsumed and removed)
 ("o6_adopt_host_check_dropped", '        if r.get("host") != HOST:\n            return "chain-member-other-host", []', '        if False:\n            return "chain-member-other-host", []'),
 ("o7_late_terminal_not_recorded", '    atomic_write(path, json.dumps(write_late, sort_keys=True, indent=1) + "\\n")\n    decide(decision="late-terminal"', '    pass\n    decide(decision="late-terminal"'),
 ("o8_missing_binding_passes", '    if not b or ident is None:\n        return False', '    if not b:\n        return True\n    if ident is None:\n        return False'),
 ("o9_resume_cross_host", 'or rec.get("host") != HOST or (c is not None', 'or (c is not None'),
 ("o10_other_host_evidence_none", '    if rec.get("host") != HOST:\n        return "unknown"', '    if rec.get("host") != HOST:\n        return "none"'),
 ("o11_binding_store_identity_ignored", 'and si is not None and si == b.get("store") and trusted_file', 'and si is not None and trusted_file'),
 ("o12_timeout_127_final", '    if back is not None:\n        # the store was READ', '    if back is not None or rc == 127:\n        # the store was READ'),
 # repair 4 (R4-1..R4-5, seams, m11): the reviewer's own 18 (S/in/review4-probes/mkmut.py, patterns unchanged) + new mutants for the classes this repair closes
 ("m1_chain_claimant_only", 'r.get("worker") == token and r.get("invocation")', 'r.get("invocation") == token and r.get("invocation")'),
 ("m2_no_reprobe_at_adoption", '            if u != "absent":\n                decide(decision="adopt-blocked"', '            if False:\n                decide(decision="adopt-blocked"'),
 ("m3_supervise_lock_noop", '    lk = FileLock("start-" + inv)                              # serialized with finish_start: either the marker lands before the FINAL decision or the FINAL receipt is seen here\n    lk.acquire()', '    lk = FileLock("start-" + inv)\n    pass'),
 ("m4_finish_start_lock_noop", '    lk = FileLock("start-" + rec["invocation"])\n    lk.acquire()\n    try:\n        return _finish_start(rec, rc, err)', '    lk = FileLock("start-" + rec["invocation"])\n    try:\n        return _finish_start(rec, rc, err)'),
 ("m5_chain_host_check_dropped", '        if r.get("host") != HOST:\n            return "chain-member-other-host", []', '        if False:\n            return "chain-member-other-host", []'),
 ("m6_start_evidence_otherhost_none", '    if rec.get("host") != HOST:\n        return "unknown"\n    u = unit_probe', '    if rec.get("host") != HOST:\n        return "none"\n    u = unit_probe'),
 ("m7_sha_recheck_dropped", '        if file_sha(exe) != sha:\n            return 127, "", "ask executable changed after verification"', '        if False:\n            return 127, "", "ask executable changed after verification"'),
 ("m8_row_keys_empty", 'ROW_KEYS = ("ask_id", "rev", "status", "claim")', 'ROW_KEYS = ()'),
 ("m9_launcher_allowlist_recheck_dropped", '    if launcher_path(lname) != rec.get("launcher"):', '    if False:'),
 ("m10_trusted_file_true", '    return os.path.isfile(path) and st.st_uid in (os.getuid(), 0) and not (st.st_mode & 0o002) \\\n        and not (st.st_mode & 0o020 and st.st_gid != os.getgid())', '    return True'),
 ("m11_late_terminal_not_evidence", ', d("consumed", inv + ".late-terminal.json")))', '))'),
 ("m12_probe_unknown_is_none", 'return {"present": "started", "absent": "none"}.get(u, "unknown")', 'return {"present": "started", "absent": "none"}.get(u, "none")'),
 ("m13_adopt_readback_skipped", '        if not back or claim_worker(back[0].get("claim")) != adopt:', '        if False:'),
 ("m14_waits_on_missing_ok", '        if "waits_on" not in row:', '        if False:'),
 ("m15_chain_final_state_any", '        if c.get("state") != "start-failed" or c.get("ask") != ask:', '        if c.get("ask") != ask:'),
 ("m16_resume_host_check_dropped", 'rec.get("host") != HOST or (c is not None', 'False or (c is not None'),
 ("m17_open_chain_member_ignored", '        if c is None or c.get("state") not in FINAL:\n            return "open", r["invocation"]', '        if False:\n            return "open", r["invocation"]'),
 ("m18_adopt_unit_unknown_passes", '                return 5 if u == "present" else 7', '                return 5 if u == "present" else 0'),
 ("r4_start_cmd_raw_env", '    sc = _seam("WR_START_CMD")', '    sc = os.environ.get("WR_START_CMD")'),
 ("r4_main_gate_off", 'SEAMS = __name__ != "__main__" and os.environ', 'SEAMS = os.environ'),
 ("r4_self_raw_env", 'SELF = _seam("WR_SELF") or', 'SELF = os.environ.get("WR_SELF") or'),
 ("r4_state_raw_env", 'STATE = _seam("WR_STATE") or', 'STATE = os.environ.get("WR_STATE") or'),
 ("r4_host_raw_env", 'HOST = _seam("WR_HOST") or', 'HOST = os.environ.get("WR_HOST") or'),
 ("r4_holdgate_raw_env", 'HOLD_GATE = _seam("HOLD_GATE") or', 'HOLD_GATE = os.environ.get("HOLD_GATE") or'),
 ("r4_launcher_dir_raw_env", 'LAUNCHER_DIR = _seam("WR_LAUNCHER_DIR") or', 'LAUNCHER_DIR = os.environ.get("WR_LAUNCHER_DIR") or'),
 ("r4_adopt_empty_readback_ok", 'if not back or claim_worker(back[0].get("claim")) != adopt:', 'if back and claim_worker(back[0].get("claim")) != adopt:'),
 ("r4_adopt_unreadable_ok", '        if back is None:\n            decide(decision="canonical-unavailable", ask=ask, op="adopt")\n            return 4\n', '        if False:\n            return 4\n'),
 ("r4_evidence_terminal_ignored", 'd("terminals", inv + ".json"), d("effects", inv + ".effect"),\n                                           d("prov", inv + ".json"), d("consumed"', 'd("effects", inv + ".effect"),\n                                           d("prov", inv + ".json"), d("consumed"'),
 ("r4_evidence_effects_ignored", 'd("effects", inv + ".effect"),\n                                           d("prov", inv + ".json"), d("consumed"', 'd("prov", inv + ".json"), d("consumed"'),
 ("r4_evidence_prov_ignored", 'd("prov", inv + ".json"), d("consumed", inv + ".late-terminal.json")', 'd("consumed", inv + ".late-terminal.json")'),
 ("r4_evidence_marker_ignored", 'd("started", inv + ".json"), d("terminals", inv + ".json"), d("effects"', 'd("terminals", inv + ".json"), d("effects"'),
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
    for i in range(2):                    # repair 4: the suite = ALL five scripts (the reviewer's runmut.sh ran four); a run stops at the first script that reports FAIL
        rows = []
        for sc in ("worker-route-review4", "worker-route-probes", "worker-route-review3", "worker-route-hygiene", "worker-route"):
            out = subprocess.run(["bash", D + "/tests/%s.test.sh" % sc], capture_output=True, text=True, env=dict(os.environ, TMPDIR=R + "/tmp", WR_TEST_TMP=R + "/tmp")).stdout
            open(R + "/out/mut-%s.%d.%s.log" % (n, i, sc), "w").write(out)
            rows = [sc + ": " + l[:100] for l in out.splitlines() if l.startswith("FAIL ")]
            if rows: break
        fails.append(rows)
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
