"""Retained from the independent review-3 probes (S/in/review3-probes/own_probes3.py, copied unedited in logic; repointed at THIS clone: the scratch base comes from WR_PROBE_BASE (never /tmp), the worker-route path from this repo, and the explicit test switch WR_TEST_SEAMS=1 is added to every world). Fixtures do not prove installed behaviour."""
import sys, json, os
sys.argv = [sys.argv[0]]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from own_probes import World, dec, emit, newworld
w = newworld("y1"); w.flag("gone"); w.flag("probe-down")
rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
rs, ds_s, _ = w.run("supervise", inv)         # the unit actually ran (client lost)
rc2, ds2, _ = w.run("consume")
rr, dr, _ = w.run("resume", inv, "--by", "rev")
emit("y1_start_unknown_then_terminal", launch=(rc, w.lstate(inv)), consume=dec(ds2), receipts=w.receipts(), resume_after=(rr, dec(dr)), b_children=[c for c in w.children() if "b1" in c])
