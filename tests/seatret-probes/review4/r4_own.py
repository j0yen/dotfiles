#!/usr/bin/env python3
"""Same-author tests for review-4 findings R4-3, R4-4, R4-5 and the surviving reviewer mutant m11 (fake worlds from w4.py; no systemd, claim store or ledger; fixtures
are source-only evidence and do not prove the installed behaviour). One PASS/FAIL line each."""
import ast, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from w4 import World, dec, SRC
fails = 0
def chk(name, cond, why=""):
    global fails
    if cond: print("PASS " + name)
    else: fails += 1; print("FAIL %s: %s" % (name, why))
def after_startfail(tag, *flags):
    w = World(tag); w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail")
    for f in flags: w.flag(f); 
    if flags: open(w.w + "/stub/qn", "w").write("0")
    return w
# R4-3: the adoption readback (claim re-read and compared to the adopted token) is pinned: a claim that changed hands, vanished or became unreadable between the
# launch query and the adoption readback never starts a worker (reviewer mutant m13 = guard dropped)
w = after_startfail("r43-ctl"); rc, ds, _ = w.run("launch", "A1")
chk("R4-3 control: with a stable claim the no-start adopter adopts (exit 0, one child, one claim call)", rc == 0 and dec(ds) == ["adopt-failed-start-claim", "launched"] and len(w.children()) == 1 and w.calls("asks claim") == 1, "%s %s" % (rc, dec(ds)))
w = after_startfail("r43-flip", "flip"); rc, ds, _ = w.run("launch", "A1")
chk("R4-3a: the claim flips to another holder before the adoption readback: claim-conflict 5, no child, no new claim", rc == 5 and dec(ds) == ["claim-conflict"] and not w.children() and w.calls("asks claim") == 1, "%s %s %s" % (rc, dec(ds), w.children()))
w = after_startfail("r43-vanish", "flip-vanish"); rc, ds, _ = w.run("launch", "A1")
chk("R4-3b: the ask is gone at the adoption readback (empty rows): claim-conflict 5, no child", rc == 5 and dec(ds) == ["claim-conflict"] and not w.children(), "%s %s %s" % (rc, dec(ds), w.children()))
w = after_startfail("r43-down", "flip-down"); rc, ds, _ = w.run("launch", "A1")
chk("R4-3c: the store is unreadable at the adoption readback: canonical-unavailable 4 (retryable), no child, nothing adopted", rc == 4 and dec(ds) == ["canonical-unavailable"] and not w.children(), "%s %s %s" % (rc, dec(ds), w.children()))
w.unflag("flip-down"); open(w.w + "/stub/qn", "w").write("0"); w.unflag("flip"); rc, ds, _ = w.run("launch", "A1")
chk("R4-3d: once the store is readable again the same ask adopts (the refusal left no state behind)", rc == 0 and len(w.children()) == 1, "%s %s" % (rc, dec(ds)))
# m11: every kind of run evidence blocks adoption, the late-terminal marker ON ITS OWN included (no terminal file, no marker, no effect, no provenance)
def evidence_world(tag, plant):
    w = World(tag); w.flag("startfail"); w.run("launch", "A1"); A = w.invs()[0]; w.unflag("startfail")
    plant(w, A); rc, ds, _ = w.run("launch", "A1"); return w, rc, ds
for name, plant in (("late-terminal marker only", lambda w, A: open(w.w + "/state/consumed/%s.late-terminal.json" % A, "w").write("{}")),
                    ("terminal file only", lambda w, A: open(w.w + "/state/terminals/%s.json" % A, "w").write("{}")),
                    ("started marker only", lambda w, A: open(w.w + "/state/started/%s.json" % A, "w").write("{}")),
                    ("provenance file only", lambda w, A: open(w.w + "/state/prov/%s.json" % A, "w").write("{}")),
                    ("effect ledger only", lambda w, A: open(w.w + "/state/effects/%s.effect" % A, "w").write("BEGIN x\n"))):
    w, rc, ds = evidence_world("m11-" + name.split()[0], plant)
    chk("m11 class: %s on the dead invocation blocks adoption (claim-conflict 5, no child, no new claim)" % name, rc == 5 and dec(ds) == ["claim-conflict"] and not w.children() and w.calls("asks claim") == 1,
        "%s %s %s" % (rc, dec(ds), w.children()))
    chk("m11 class: %s: the decision names the chain member as having run" % name, any(d.get("reason", "").endswith("chain-member-ran") or "chain-member-ran" in d.get("reason", "") for d in ds), str(ds))
w, rc, ds = evidence_world("m11-none", lambda w, A: None)
chk("m11 control: no evidence planted -> adopts (exit 0, one child)", rc == 0 and len(w.children()) == 1, "%s %s" % (rc, dec(ds)))
# R4-4: the real snapshot's row shape (S/in/wm-asks-open-rb-r7.json: ask_id check claim due key owner ready rev row_id status waits_on what, 253/253 rows) is accepted;
# a real-looking host:...:unit:... claim token is not an invocation of this route, so it is never adopted (conservative, no claim call)
w = World("r44-shape"); w.db["A1"].update(check="c", due="2026-11-13T09:00", key="k", ready=True, row_id=7); w.save(); rc, ds, _ = w.run("launch", "A1")
chk("R4-4a: a row with every key of the real snapshot shape launches (no canonical-shape-unverified)", rc == 0 and "canonical-shape-unverified" not in dec(ds) and len(w.children()) == 1, "%s %s" % (rc, dec(ds)))
w = World("r44-token"); w.db["A1"]["claim"] = "host:carbon:unit:r7-dqte-211011@2026-11-12T21:11"; w.save(); rc, ds, _ = w.run("launch", "A1")
chk("R4-4b: a snapshot-style claim token (host:carbon:unit:...@ts) is not an invocation: claim-conflict 5 token-not-an-invocation, no claim call, no child", rc == 5 and [d.get("reason") for d in ds] == ["token-not-an-invocation"] and w.calls("asks claim") == 0 and not w.children(), "%s %s" % (rc, ds))
# R4-4 / R4-5 are statements in the module docstring: they must say what the code and the supplied inputs show
doc = ast.get_docstring(ast.parse(open(SRC).read())) or ""
chk("R4-4c: the docstring cites the supplied snapshot for the claim / waits_on row keys and no longer lists them as missing from the supplied inputs", "wm-asks-open-rb-r7.json" in doc and "NOT in the supplied source: the row keys `claim` and `waits_on`" not in doc, doc[doc.find("Ask API binding"):][:700])
chk("R4-4d: the docstring still names the `--status` value domain as the unverified true limit (asks.query source not supplied)", "`--status`" in doc and "true limit" in doc.lower(), "")
chk("R4-5a: the docstring does not claim an admitted-late unit 'can still run' a child after a FINAL start-failed receipt; it states the fixture-level result and the installed-only residual", "can still run" not in doc and "supervise-after-final" in doc and "installed" in doc.lower(), "")
chk("R4-1a: the docstring says the seams exist only for an IMPORTED module with the switch and that the production script (run as __main__) has none", "__main__" in doc and "no seams" in doc.lower() and "honoured ONLY with WR_TEST_SEAMS=1" not in doc, "")
print("ALL PASS" if not fails else "FAILURES: %d" % fails)
sys.exit(1 if fails else 0)
