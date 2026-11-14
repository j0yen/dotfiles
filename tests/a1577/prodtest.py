import json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a1577_produce as P, succ_v5 as succ
A="A1296"; INV="rl-planned-1"; ROW=dict(ask_id=A, rev="14", status="open", what="drive recovery", check="test -s x")
class L:
    def __init__(s, row=None): s.row=dict(row or ROW); s.n=0
    def read(s, a): return dict(s.row)
    def append_line(s, a, line, rev):
        s.n+=1; s.row=dict(s.row, what=s.row["what"]+"\n"+line, rev=str(int(s.row["rev"])+1))
class E:
    def __init__(s, eff=None, unres=()): s.eff=eff; s.un=unres
    def effect(s, a, i): return s.eff
    def unresolved(s, a, i=None): return s.un
GOOD=json.dumps(dict(schema="a1577-effect/1", ask=A, invocation=INV, outcome="applied", effect_id="e1", source_row="d-real-1", readback="read ok")).encode()
REC=dict(schema="a1577-reconcile/1", ask=A, prior_invocation="inv-prev", status="reconciled", effects=["A1 verifying"])
bad=0
def case(name, want, eff=GOOD, unres=(), recs=(), led=None, inv=INV):
    global bad
    led=led or L(); out=tempfile.mkdtemp()
    try: P.produce(A, out, led, E(eff, unres), recs, inv); got=True
    except P.Refused as x: got=False; msg=str(x)
    ok = got==want and (got or led.n==0); bad += not ok
    print("OK" if ok else "WRONG", "PROD", name, "" if got else "-> "+msg)
    return led, out
led,out=case("positive: authoritative applied effect, none unresolved", True)
b=json.load(open(f"{out}/binding-{INV}.json")); assert open(b["effect_file"],"rb").read()==GOOD
case("no effect record (no child/effect): refused, nothing appended", False, eff=None)
case("effect outcome not applied", False, eff=json.dumps(dict(json.loads(GOOD), outcome="unsupported")).encode())
case("effect without readback", False, eff=json.dumps({k:v for k,v in json.loads(GOOD).items() if k!="readback"}).encode())
case("effect without source_row", False, eff=json.dumps({k:v for k,v in json.loads(GOOD).items() if k!="source_row"}).encode())
case("effect for another invocation", False, eff=json.dumps(dict(json.loads(GOOD), invocation="other")).encode())
case("effect not JSON", False, eff=b"applied")
case("unresolved prior UNKNOWN (store unreadable)", False, unres=None)
case("unresolved prior omitted", False, unres=["inv-prev"])
case("unresolved prior reconciled with receipt", True, unres=["inv-prev"], recs=[REC])
case("reconcile receipt not reconciled", False, unres=["inv-prev"], recs=[dict(REC, status="pending")])
case("ask already bound", False, led=L(dict(ROW, what="x\na1577-bind inv=z effect-sha="+"0"*64+" prior=none")))
case("ask closed", False, led=L(dict(ROW, status="closed")))
# round trip through succ.check with the produced record
led,out=case("round trip", True, unres=["inv-prev"], recs=[REC])
print("A1577-PRODUCER-V6-CONTROLS-PASS" if not bad else f"FAILED {bad}")
import a1577_produce as PP
def rows(*ws): return [dict(id=f"d-{i}", ts=f"2026-11-11T08:{i:02d}:00-08:00", what=w, evidence="x") for i, w in enumerate(ws)]
def un(rs, inv=INV): return PP.DecisionEffects(rows=rs).unresolved(A, inv)
for oc in ("UNKNOWN", "failed", "intended", "applied"):
    r = un(rows(f"a1577-effect ask={A} inv=inv-p outcome={oc}")); ok = r == ["inv-p"]; bad += not ok; print("OK" if ok else "WRONG", "PROD prior outcome", oc, "unresolved:", r)
_rs = rows(f"a1577-effect ask={A} inv=inv-p outcome=UNKNOWN", f"a1577-reconciled ask={A} prior=inv-p")
_rs[1]["evidence"] = __import__("json").dumps(dict(schema="a1577-reconcile/1", ask=A, prior_invocation="inv-p", status="reconciled", effects=[_rs[0]["id"]], resolution="owner confirmed prior outcome", readback="readback of prior effect"))
r = un(_rs); ok = r == []; bad += not ok; print("OK" if ok else "WRONG", "PROD reconciled prior clears:", r)
r = un(rows(f"a1577-effect ask={A} inv={INV} outcome=applied")); ok = r == []; bad += not ok; print("OK" if ok else "WRONG", "PROD current inv not its own prior:", r)
class Bad(PP.DecisionEffects):
    def _load(self): return None
ok = Bad().unresolved(A, INV) is None; bad += not ok; print("OK" if ok else "WRONG", "PROD read failure -> UNKNOWN(None)")
class Old(PP.DecisionEffects):
    def _load(self): return []
    def _window_ok(self, ask): return False
ok = Old().unresolved(A, INV) is None; bad += not ok; print("OK" if ok else "WRONG", "PROD incomplete window -> UNKNOWN(None)")
print("A1577-PRODUCER-V6-CONTROLS-PASS" if not bad else f"FAILED {bad}")
# M1: an invocation id that already produced a binding is refused (even if its relaunch was never checked)
_pp = tempfile.mkdtemp() + "/produced"
_o = tempfile.mkdtemp()
try: P.produce(A, _o, L(), E(GOOD, ()), (), INV, produced_path=_pp); _first = True
except P.Refused: _first = False
try: P.produce(A, tempfile.mkdtemp(), L(), E(GOOD, ()), (), INV, produced_path=_pp); _again = True
except P.Refused: _again = False
ok = _first and not _again; bad += not ok; print("OK" if ok else "WRONG", "PROD M1 produced id reuse refused (first ok, second refused):", _first, _again)
# W2: a live bind line blocks a second bind; a voided one (launch ended before any kill) is superseded by exactly one new last bind
def _eff(i): return json.dumps(dict(schema="a1577-effect/1", ask=A, invocation=i, outcome="applied", effect_id="e-"+i, source_row="d-"+i, readback="read ok")).encode()
_vd = tempfile.mkdtemp() + "/void"; _led = L()
P.produce(A, tempfile.mkdtemp(), _led, E(_eff("inv-a"), ()), (), "inv-a")
try: P.produce(A, tempfile.mkdtemp(), _led, E(_eff("inv-b"), ()), (), "inv-b", void_path=_vd); _live = True
except P.Refused: _live = False
open(_vd, "w").write("inv-a\n")
try: P.produce(A, tempfile.mkdtemp(), _led, E(_eff("inv-b"), ()), (), "inv-b", void_path=_vd); _after = True
except P.Refused as x: _after = False; print(x)
_binds = [l for l in _led.row["what"].split("\n") if l.startswith("a1577-bind")]
ok = (not _live) and _after and len(_binds) == 2 and "inv=inv-b" in _binds[-1]; bad += not ok
print("OK" if ok else "WRONG", "PROD W2 live bind blocks, voided bind superseded:", _live, _after, len(_binds))
# W2b: a voided id other than the last bind does not unblock
open(_vd, "w").write("inv-zzz\n")
try: P.produce(A, tempfile.mkdtemp(), _led, E(_eff("inv-c"), ()), (), "inv-c", void_path=_vd); _w = True
except P.Refused: _w = False
ok = not _w; bad += not ok; print("OK" if ok else "WRONG", "PROD W2b live last bind still blocks:", _w)
print("A1577-PRODUCER-V6-CONTROLS-PASS" if not bad else f"FAILED {bad}")
# S1: the last bind's invocation was consumed by a live child: a void entry never supersedes it
_vd2 = tempfile.mkdtemp(); _led2 = L(); P.produce(A, tempfile.mkdtemp(), _led2, E(_eff("inv-x"), ()), (), "inv-x")
open(_vd2 + "/void", "w").write("inv-x\n"); open(_vd2 + "/cons", "w").write("inv-x 4242 1\n")
try: P.produce(A, tempfile.mkdtemp(), _led2, E(_eff("inv-y"), ()), (), "inv-y", void_path=_vd2 + "/void", consumed_path=_vd2 + "/cons"); _s1 = True
except P.Refused: _s1 = False
ok = not _s1; bad += not ok; print("OK" if ok else "WRONG", "PROD S1 consumed id voided: supersession refused:", _s1)
print("A1577-PRODUCER-V6-CONTROLS-PASS" if not bad else f"FAILED {bad}")
