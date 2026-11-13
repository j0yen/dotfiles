"""Expected results of the retained review-2 probes (probe_addendum.py, probe_f.py) at the repaired route. Each line pins one reviewer scenario."""
import json, os, sys
res = json.load(open(os.path.join(os.environ["WR_PROBE_BASE"], "probe_addendum.json")))
fout = open(os.path.join(os.environ["WR_PROBE_BASE"], "probe_f.out")).read()
bad = []
def want(tag, cond, what):
    if not cond:
        bad.append("%s: %s (got %s)" % (tag, what, json.dumps(res.get(tag), sort_keys=True)))
def r(tag): return res.get(tag, {})
# (a) partial start: client error after the unit/child ran is NOT a FINAL start-failed; the terminal is consumed; effects stay UNKNOWN; no second worker
want("a1_partial_start", r("a1_partial_start").get("rc") == 0 and "start-failed" not in r("a1_partial_start").get("receipts", {}).values() and r("a1_partial_start").get("children") == 1, "reconciled as started, one child")
want("a1_consume_after", list(r("a1_consume_after").get("receipts", {}).values()) == ["consumed"], "late terminal consumed after the partial start")
want("a2_partial_with_unknown_effect", list(r("a2_partial_with_unknown_effect").get("receipts", {}).values()) == ["unknown-effect"], "BEGIN-without-END surfaced UNKNOWN")
want("a3_late_terminal", r("a3_late_terminal").get("children") == 0 and r("a3_late_terminal").get("terminals") == [], "a unit started after a FINAL no-start never runs a child")
want("a4_relaunch_after_partial_permissive_store", r("a4_relaunch_after_partial_permissive_store").get("rc") == 6 and r("a4_relaunch_after_partial_permissive_store").get("children") == 1, "no second worker even against a re-claim-permissive store")
# (b) claim readback failure / after-commit errors
want("b1_claim_ok_readback_down", r("b1_claim_ok_readback_down").get("rc") == 4 and r("b1_claim_ok_readback_down").get("rec_state") == "claim-unknown", "claim-unknown")
want("b1_relaunch_after_store_back", r("b1_relaunch_after_store_back").get("rc") == 6, "relaunch still blocked, no silent retry")
want("b1_resume_claim_unknown", r("b1_resume_claim_unknown").get("rc") == 0 and r("b1_resume_claim_unknown").get("claim_calls") == 1 and r("b1_resume_claim_unknown").get("children") == 1, "explicit resume: same invocation, no second claim")
want("b1_consume", list(r("b1_consume").get("receipts", {}).values()) == ["consumed"], "resumed invocation consumed")
for k in ("b2_after_commit_rc75_readback_ok", "b2_after_commit_rc1_readback_ok"):
    want(k, r(k).get("rc") == 0 and r(k).get("children") == 1, "after-commit nonzero exit with a readable store proceeds on the readback")
for k in ("b3_after_commit_rc75_readback_down", "s3_timeout_after_commit_readback_down"):
    want(k, r(k).get("rc") == 4 and r(k).get("decisions") == ["claim-unknown"] and r(k).get("receipts") == {}, "UNKNOWN, never FINAL claim-failed")
want("s3_relaunch_later", r("s3_relaunch_later").get("rc") == 6 and r("s3_relaunch_later").get("children") == 0, "later launch refused invocation-in-use, not claim-conflict")
# (c) client unreachable and unit not inspectable
want("c1_start_client_unreachable_127", r("c1_start_client_unreachable_127").get("rc") == 7 and r("c1_start_client_unreachable_127").get("receipts") == {}, "UNKNOWN, no FINAL receipt")
want("c1_relaunch", r("c1_relaunch").get("rc") == 6, "blocked")
want("c1_resume_still_unreachable", r("c1_resume_still_unreachable").get("rc") == 7, "resume stays UNKNOWN while uninspectable")
want("c1_resume_proved_absent", r("c1_resume_proved_absent").get("rc") == 1 and "start-failed" in r("c1_resume_proved_absent").get("receipts", {}).values(), "FINAL only on the exact no-start proof")
want("c2_reconciliation_code_present", r("c2_reconciliation_code_present").get("unit_probe_modes") == ["absent", "present", "unknown"], "the unit probe seam is exercised structurally: absent, present, unknown")
# (d) proved no-start then retry, REAL claim semantics (rc 66 on any existing claim) and the re-claim-permissive fixture
want("d1_first_launch_startfail", r("d1_first_launch_startfail").get("rc") == 1 and r("d1_first_launch_startfail").get("children") == 0, "proved no-start")
want("d2_retry_against_REAL_claim_semantics", r("d2_retry_against_REAL_claim_semantics").get("rc") == 0 and r("d2_retry_against_REAL_claim_semantics").get("children") == 1 and "adopt-failed-start-claim" in r("d2_retry_against_REAL_claim_semantics").get("decisions", []), "retry works with the real claim API (held claim adopted)")
want("d3_retry_again_real", r("d3_retry_again_real").get("rc") == 6, "no second worker")
want("d4_retry_against_AUTHOR_fixture_semantics(permissive_reclaim)", r("d4_retry_against_AUTHOR_fixture_semantics(permissive_reclaim)").get("rc") == 0, "retry works")
# binding
want("e1_asks_resolution", r("e1_asks_resolution").get("bound_ok") is True and r("e1_asks_resolution").get("validated_target") is True, "bound entrypoint verified")
want("e2_unbound_cmd_unreadable", r("e2_unbound_cmd_unreadable").get("rc") == 77, "unbound refused")
want("e3_decoy_executable_refused", r("e3_decoy_executable_refused").get("rc") == 77 and r("e3_decoy_executable_refused").get("children") == 0, "decoy refused")
# probe_f: F1 claim-failed on a genuine pre-commit rc 66 refusal is FINAL and relaunches
if "F1 claim-failed (no mutation, rc66): 5 ['claim-failed']" not in fout or "F1 relaunch after claim-failed: 0 ['launched'] children 1" not in fout:
    bad.append("probe_f: " + fout[:300])
if bad:
    print("\n".join("FAIL probe expectation " + b for b in bad)); sys.exit(1)
print("PASS %d probe expectations" % (len(res) + 2))
