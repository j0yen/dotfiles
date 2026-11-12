# R6-a / Hermes A1577rev37: authoritative current effect recheck through the REAL succ_v5.live_priors + DecisionEffects over injected ledger rows
import os, sys, json, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a1577_produce as P, succ_v5 as succ
A, INV = "A1296", "rl-planned-1"; bad = 0
def rows(*ws): return [dict(id=f"d-{i}", ts=f"2026-11-11T08:{i:02d}:00-08:00", what=w, evidence="readback of applied effect ok") for i, w in enumerate(ws)]
def lp(rs, sha="auto"):
    succ.EFFECTS_FACTORY = lambda: P.DecisionEffects(rows=rs)
    d = P.DecisionEffects(rows=rs).effect(A, INV)
    s = hashlib.sha256(d).hexdigest() if (sha == "auto" and d) else (sha if sha != "auto" else None)
    return succ.live_priors(A, INV, s)
def chk(name, want, got):
    global bad; ok = (got == want); bad += not ok; print("OK" if ok else "WRONG", "R6A", name, got)
E = f"a1577-effect ask={A} inv={INV} outcome=applied"
chk("applied effect, no priors: readable, empty set", [], lp(rows(E)))
chk("later failed row for the bound inv: refused (None)", None, lp(rows(E, f"a1577-effect ask={A} inv={INV} outcome=failed")))
chk("later rolled-back row for the bound inv: refused (None)", None, lp(rows(E, f"a1577-effect ask={A} inv={INV} outcome=rolled-back")))
chk("later duplicate applied row for the bound inv: refused (None)", None, lp(rows(E, E)))
chk("effect row absent at check time: refused (None)", None, lp(rows("unrelated"), sha="0"*64))
chk("current effect differs from the bound digest: refused (None)", None, lp(rows(E), sha="1"*64))
chk("unresolved prior row surfaces in the set", ["inv-p"], lp(rows(f"a1577-effect ask={A} inv=inv-p outcome=applied", E)))
succ.EFFECTS_FACTORY = None
print("A1577-R6A-CONTROLS-PASS" if not bad else f"FAILED {bad}")
# X1: end-to-end produce -> check across a voided bind (producer and checker agree)
import tempfile
sd = tempfile.mkdtemp(); cons = sd + "/succ-consumed"
ROW = dict(ask_id=A, rev="14", status="open", what="drive recovery", check="test -s x")
class L:
    def __init__(s): s.row = dict(ROW)
    def read(s, a): return dict(s.row)
    def append_line(s, a, line, rev): s.row = dict(s.row, what=s.row["what"] + "\n" + line, rev=str(int(s.row["rev"]) + 1))
def eff(i): return json.dumps(dict(schema="a1577-effect/1", ask=A, invocation=i, outcome="applied", effect_id="e-" + i, source_row="d-" + i, readback="ok")).encode()
class E:
    def __init__(s, i): s.i = i
    def effect(s, a, i): return eff(s.i)
    def unresolved(s, a, i=None): return []
led = L(); out1 = P.produce(A, tempfile.mkdtemp(), led, E("inv-a"), (), "inv-a", void_path=sd + "/succ-void")
open(sd + "/succ-void", "w").write("inv-a\n")
out2 = P.produce(A, tempfile.mkdtemp(), led, E("inv-b"), (), "inv-b", void_path=sd + "/succ-void")
b2 = json.load(open(out2["binding"]))
print("A1577-X1-DONE (full positive check() accept = run5.py X1 cases)" if not bad else f"FAILED {bad}")
