"""Retained from the independent review-3 probes (S/in/review3-probes/own_probes2.py, copied unedited in logic; repointed at THIS clone: the scratch base comes from WR_PROBE_BASE (never /tmp), the worker-route path from this repo, and the explicit test switch WR_TEST_SEAMS=1 is added to every world). Fixtures do not prove installed behaviour."""
import sys, json, os
sys.argv = [sys.argv[0]]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import own_probes as P
from own_probes import World, dec, emit, newworld
def chain_consumed():
    w = newworld("x1"); w.flag("startfail")
    rc, ds, _ = w.run("launch", "A1"); w.unflag("startfail")
    rc2, ds2, _ = w.run("launch", "A1")        # B adopts A's held claim, runs, ok
    w.run("consume")
    rc3, ds3, _ = w.run("launch", "A1")        # relaunch AFTER B ran to completion and was consumed
    emit("x1_relaunch_after_adopted_run_consumed", first=(rc, dec(ds)), adopt=(rc2, dec(ds2)), relaunch=(rc3, dec(ds3)), children=[c for c in w.children() if c.startswith("a1")], receipts=w.receipts(), claim_calls=w.calls("asks claim A1"))
def chain_failed():
    w = newworld("x2"); w.flag("startfail")
    w.run("launch", "A1"); w.unflag("startfail"); w.env["RC"] = "1"
    w.run("launch", "A1"); w.run("consume")
    rc3, ds3, _ = w.run("launch", "A1")
    emit("x2_relaunch_after_adopted_run_worker_failed", relaunch=(rc3, dec(ds3)), children=[c for c in w.children() if c.startswith("a1")], receipts=w.receipts())
def chain_late():
    w = newworld("x3"); w.flag("startfail")
    w.run("launch", "A1")                      # A start-failed FINAL (proved)
    rc2, ds2, _ = w.run("launch", "A1")        # B adopts, start fails again, FINAL
    invs = w.invs(); B = [i for i in invs if json.load(open(w.w + "/state/launches/%s.json" % i)).get("adopts")][0]
    rec = json.load(open(w.w + "/state/launches/%s.json" % B))
    t = {"invocation": B, "nonce": rec["nonce"], "ask": "A1", "host": "h1", "rc": 0, "status": "ok", "effect": "x", "provenance": "unrecorded", "started": "s", "ended": "e"}
    json.dump(t, open(w.w + "/state/terminals/%s.json" % B, "w"))     # B's unit DID run after FINAL
    w.run("consume"); w.unflag("startfail")
    rc3, ds3, _ = w.run("launch", "A1")
    emit("x3_C_launch_after_B_late_terminal", B_final=w.receipts().get(B), consume_late=os.path.exists(w.w + "/state/consumed/%s.late-terminal.json" % B), launch=(rc3, dec(ds3)), children=[c for c in w.children() if c.startswith("a1")])
chain_consumed(); chain_failed(); chain_late()
