"""Expected results of the retained review-3 probes (own_probes.py rows, own_probes2.py x1-x3, own_probes3.py y1) at the repaired route.
Reads the JSON lines the probes emitted ($WR_PROBE_BASE/out-*.jsonl)."""
import json, os, sys
B = os.environ["WR_PROBE_BASE"]
rows = {}
for f in ("out-own1.jsonl", "out-own2.jsonl", "out-own3.jsonl"):
    for l in open(os.path.join(B, f)):
        if l.startswith("{"):
            d = json.loads(l); rows[d["row"]] = d
bad = []
def want(tag, cond, what):
    if not cond: bad.append("%s: %s (got %s)" % (tag, what, json.dumps(rows.get(tag), sort_keys=True)))
def r(tag): return rows.get(tag, {})
# R3-1: chain-aware adoption: no second adopter after a run, a failure or a late terminal
x1 = r("x1_relaunch_after_adopted_run_consumed"); want("x1_relaunch_after_adopted_run_consumed", x1.get("relaunch", [None])[0] == 5 and len(x1.get("children", [])) == 1 and x1.get("claim_calls") == 1, "no second worker after a consumed adopted run")
x2 = r("x2_relaunch_after_adopted_run_worker_failed"); want("x2_relaunch_after_adopted_run_worker_failed", x2.get("relaunch", [None])[0] == 5 and len(x2.get("children", [])) == 1, "no relaunch after the adopter failed")
x3 = r("x3_C_launch_after_B_late_terminal"); want("x3_C_launch_after_B_late_terminal", x3.get("launch", [None])[0] == 5 and x3.get("children") == [] and x3.get("consume_late") is True, "no adoption after a late terminal")
# R3-3: the binding is not forgeable through env; forged binding + decoy executable never runs a child
f = r("bind_env_WR_ASKS_BINDING_forged_accepted"); want("bind_env_WR_ASKS_BINDING_forged_accepted", f.get("rc") == 77 and f.get("children") == 0, "a forged binding file named by env is refused")
for t in ("bind_missing_binding_file", "bind_decoy_on_PATH_no_cmd", "bind_other_executable_path", "bind_executable_changed_hash", "bind_other_host", "bind_store_replaced",
          "bind_symlink_retargeted_same_content", "bind_symlink_retargeted_other_content", "bind_fresh_state_no_binding", "bind_corrupt_binding_file", "bind_store_field_emptied"):
    want(t, r(t).get("rc") == 77, "binding drift refused 77")
want("bind_exec_uses_verified_path", r("bind_exec_uses_verified_path").get("src_uses_realpath_for_exec") is True, "calls no longer exec the PATH name")
# review-2 rows the reviewer kept
want("a2_partial_unit_running_no_marker", r("a2_partial_unit_running_no_marker").get("relaunch_rc") == 6 and r("a2_partial_unit_running_no_marker").get("children") == 0, "unit queued: relaunch blocked")
want("a4_late_terminal_after_final", r("a4_late_terminal_after_final").get("relaunch_rc") == 5, "late terminal blocks the relaunch")
want("a5_start_unknown_blocks_and_resumes", r("a5_start_unknown_blocks_and_resumes").get("relaunch_rc") == 6, "UNKNOWN start blocks")
want("b2_after_commit_rc75_readback_down", r("b2_after_commit_rc75_readback_down").get("rc") == 4 and r("b2_after_commit_rc75_readback_down").get("children") == 0, "after-commit rc75, readback down: UNKNOWN")
want("s1_second_launch_over_own_claim", r("s1_second_launch_over_own_claim").get("rc") == 6 and r("s1_second_launch_over_own_claim").get("children") == 1, "no second worker over the own claim")
want("s1_claim_held_after_worker_failed", r("s1_claim_held_after_worker_failed").get("rc") == 5, "claim stays with the owner after a failed worker")
want("s3_timeout_after_commit_readback_down", r("s3_timeout_after_commit_readback_down").get("rc") == 4, "timeout after commit, readback down: UNKNOWN")
want("y1_start_unknown_then_terminal", "y1_start_unknown_then_terminal" in rows, "y1 ran")
if len(rows) < 36: bad.append("expected at least 36 probe rows, got %d" % len(rows))
if bad:
    print("\n".join("FAIL review3 probe expectation " + b for b in bad)); sys.exit(1)
print("PASS %d review-3 probe rows, expectations met" % len(rows))
