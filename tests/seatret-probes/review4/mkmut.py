import os, shutil, sys
R = "/mnt/ssd/cargo-target/r7-seatrv4-20261113"; S = R + "/src"
M = {
 "m1_chain_claimant_only": ('r.get("worker") == token and r.get("invocation")', 'r.get("invocation") == token and r.get("invocation")'),
 "m2_no_reprobe_at_adoption": ('            if u != "absent":\n                decide(decision="adopt-blocked"', '            if False:\n                decide(decision="adopt-blocked"'),
 "m3_supervise_lock_noop": ('    lk = FileLock("start-" + inv)                              # serialized with finish_start: either the marker lands before the FINAL decision or the FINAL receipt is seen here\n    lk.acquire()', '    lk = FileLock("start-" + inv)\n    pass'),
 "m4_finish_start_lock_noop": ('    lk = FileLock("start-" + rec["invocation"])\n    lk.acquire()\n    try:\n        return _finish_start(rec, rc, err)', '    lk = FileLock("start-" + rec["invocation"])\n    try:\n        return _finish_start(rec, rc, err)'),
 "m5_chain_host_check_dropped": ('        if r.get("host") != HOST:\n            return "chain-member-other-host", []', '        if False:\n            return "chain-member-other-host", []'),
 "m6_start_evidence_otherhost_none": ('    if rec.get("host") != HOST:\n        return "unknown"\n    u = unit_probe', '    if rec.get("host") != HOST:\n        return "none"\n    u = unit_probe'),
 "m7_sha_recheck_dropped": ('        if file_sha(exe) != sha:\n            return 127, "", "ask executable changed after verification"', '        if False:\n            return 127, "", "ask executable changed after verification"'),
 "m8_row_keys_empty": ('ROW_KEYS = ("ask_id", "rev", "status", "claim")', 'ROW_KEYS = ()'),
 "m9_launcher_allowlist_recheck_dropped": ('    if launcher_path(lname) != rec.get("launcher"):', '    if False:'),
 "m10_trusted_file_true": ('    return os.path.isfile(path) and st.st_uid in (os.getuid(), 0) and not (st.st_mode & 0o002) \\\n        and not (st.st_mode & 0o020 and st.st_gid != os.getgid())', '    return True'),
 "m11_late_terminal_not_evidence": (', d("consumed", inv + ".late-terminal.json")))', '))'),
 "m12_probe_unknown_is_none": ('return {"present": "started", "absent": "none"}.get(u, "unknown")', 'return {"present": "started", "absent": "none"}.get(u, "none")'),
 "m13_adopt_readback_skipped": ('        if not back or claim_worker(back[0].get("claim")) != adopt:', '        if False:'),
 "m14_waits_on_missing_ok": ('        if "waits_on" not in row:', '        if False:'),
 "m15_chain_final_state_any": ('        if c.get("state") != "start-failed" or c.get("ask") != ask:', '        if c.get("ask") != ask:'),
 "m16_resume_host_check_dropped": ('rec.get("host") != HOST or (c is not None', 'False or (c is not None'),
 "m17_open_chain_member_ignored": ('        if c is None or c.get("state") not in FINAL:\n            return "open", r["invocation"]', '        if False:\n            return "open", r["invocation"]'),
 "m18_adopt_unit_unknown_passes": ('                return 5 if u == "present" else 7', '                return 5 if u == "present" else 0'),
}
for n, (a, b) in M.items():
    p = R + "/src/.local/bin/worker-route.py"; t = open(p).read()
    if t.count(a) != 1: print("BAD PATTERN", n, t.count(a)); continue
    d = R + "/tmp/mut/" + n
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d + "/.local"); shutil.copytree(S + "/.local/bin", d + "/.local/bin"); shutil.copytree(S + "/tests", d + "/tests")
    open(d + "/.local/bin/worker-route.py", "w").write(t.replace(a, b))
print("done", len(M))
