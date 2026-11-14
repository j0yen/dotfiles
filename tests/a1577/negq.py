import sys; sys.path.insert(0,".")
import a1577_produce as P
A,I="A-PRIVATE","inv-private"
Q="Negative control: never accept quoted text `a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied` as an effect."
ok=lambda c,n:print(("OK " if c else "WRONG ")+n)
def eff(rows): return P.DecisionEffects(rows=rows).effect(A,I)
good={"id":"r1","what":"x\na1577-effect ask=A-PRIVATE inv=inv-private outcome=applied","evidence":"real readback"}
ok(eff([{"id":"n","what":Q,"evidence":"This is a refusal, no child or effect occurred."}]) is None,"quoted prose refused")
ok(eff([{"id":"n","what":"> a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied","evidence":"e"}]) is None,"quote-prefixed refused")
ok(eff([{"id":"n","what":"a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied (negative)","evidence":"e"}]) is None,"trailing prose refused")
ok(eff([good])is not None,"typed whole line accepted")
ok(eff([dict(good,evidence="")]) is None,"empty evidence refused")
ok(eff([dict(good,what=good["what"]+"\na1577-effect ask=A-PRIVATE inv=inv-private outcome=failed")]) is None,"ambiguous two typed lines refused")
ok(eff([good,dict(good,id="r2")]) is None,"two rows refused")
d=P.DecisionEffects(rows=[{"id":"p","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=applied"},{"id":"q","what":"quote: `a1577-reconciled ask=A-PRIVATE prior=old` text"}])
ok(d.unresolved(A,I)==["old"],"quoted reconciliation does not erase a prior")
# bare typed label (no evidence) superseded by the evidence-bound controls below
import json
def rc(**k):
    d=dict(schema="a1577-reconcile/1",ask=A,prior_invocation="old",status="reconciled",effects=["p"],resolution="owner verified old effect landed",readback="readback of old effect row"); d.update(k); return json.dumps(d)
PR={"id":"p","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=applied","evidence":"e"}
def un(ev,what="a1577-reconciled ask=A-PRIVATE prior=old",extra=()):
    return P.DecisionEffects(rows=[PR,{"id":"q","ts":"2026-11-11T09:00:00-08:00","what":what,"evidence":ev},*extra]).unresolved(A,I)
ok(un(rc())==[],"authoritative reconcile receipt positive")
ok(un("")==["old"],"empty-evidence bare label does not clear")
ok(un("None")==["old"],"non-JSON evidence does not clear")
ok(un(rc(ask="A-OTHER"))==["old"],"wrong-task receipt does not clear")
ok(un(rc(effects=["nope"]))==["old"],"wrong-effect receipt does not clear")
ok(un(rc(effects=[]))==["old"],"no-effects receipt does not clear")
ok(un(rc(status="pending"))==["old"],"unverified/pending receipt does not clear")
ok(un(rc(prior_invocation="zz"))==["old"],"receipt for another prior does not clear")
# reviewer D1/D2/D4/D5/D6
PU={"id":"p1","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=UNKNOWN","evidence":"unknown result"}
PA={"id":"p2","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=applied","evidence":"applied readback"}
def un2(rows): return P.DecisionEffects(rows=rows).unresolved(A,I)
rcp=lambda eff: {"id":"q","ts":"2026-11-11T09:00:00-08:00","what":"a1577-reconciled ask=A-PRIVATE prior=old","evidence":rc(effects=eff)}
ok(un2([PU,PA,rcp(["p2"])])==["old"],"D1 partial-coverage receipt (names only applied row) does not clear UNKNOWN sibling")
ok(un2([PU,PA,rcp(["p1","p2"])])==[],"D1 full-coverage receipt clears")
ok(un2([PA,{"id":"qq","ts":"2026-11-11T08:30:00-08:00","what":"quote `a1577-effect ask=A-PRIVATE inv=old outcome=applied` here","evidence":"x"},rcp(["qq"])])==["old"],"D2 quoted row id cannot satisfy a receipt")
ok(un2([{"id":"m","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=applied extra"}])is None,"malformed typed-looking prior line = UNKNOWN")
ok(eff([dict(good,evidence="n/a")]) is None,"D4 trivial readback n/a refused")
ok(eff([good,{"id":"s","what":"a1577-effect ask=A-PRIVATE inv=inv-private outcome=UNKNOWN","evidence":"unknown result"}]) is None,"D5 same-invocation UNKNOWN sibling refuses")
ok(eff([dict(good,what="a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied\r")]) is None,"D6 trailing CR refused")
ok(eff([dict(good,what="x a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied")]) is None,"D6 unicode line separator is not a line")

# round-2 reviewer N1/N2/N3/N7/D3
sf=lambda l:[{"id":"s","ts":"2026-11-11T08:00:00-08:00","what":l,"evidence":"unknown result"}]
for n,l in [("tab","a1577-effect ask=A-PRIVATE\tinv=old outcome=UNKNOWN"),("leading space"," a1577-effect ask=A-PRIVATE inv=old outcome=UNKNOWN"),("ask at end","a1577-effect inv=old outcome=UNKNOWN ask=A-PRIVATE"),("upper case","A1577-EFFECT ask=A-PRIVATE inv=old outcome=UNKNOWN"),("double space","a1577-effect  ask=A-PRIVATE inv=old outcome=UNKNOWN")]:
    ok(un2(sf(l)) is None,"N3 sloppy format -> UNKNOWN: "+n)
ok(un2([{"id":"s","ts":"2026-11-11T08:00:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=old outcome=UNKNOWN\na1577-reconciled ask=A-PRIVATE prior=old","evidence":rc(effects=["s"])}])==["old"],"N1 self-reconciling single row does not clear")
ok(un2([PU,PA,dict(rcp(["p1","p2"]),ts="2026-11-11T07:00:00-08:00")])==["old"],"N1 reconcile row earlier than the effects does not clear")
ok(un2([PU,PA,dict(rcp(["p1","p2"]),ts=None)])==["old"],"N1 reconcile row without ts does not clear")
ok(un2([PU,PA,dict(rcp(["p1","p2"]),evidence=rc(effects=["p1","p2"],resolution=""))])==["old"],"N2 receipt without a resolution does not clear")
ok(un2([PU,PA,dict(rcp(["p1","p2"]),evidence=rc(effects=["p1","p2"],readback="n/a"))])==["old"],"N2 receipt with trivial readback does not clear")
ok(un2([dict(PU,id=None),dict(PA,id=None)])is None,"N7 effect rows without ids = UNKNOWN")
NEW={"id":"n1","ts":"2026-11-11T09:30:00-08:00","what":"a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied","evidence":"real readback"}
ok(un2([PU,PA,rcp(["p1","p2"]),NEW])==[],"D3 positive: fresh invocation newest, old reconciled")
ok(P.DecisionEffects(rows=[PA,NEW]).unresolved(A,"old") is None,"D3 reusing the OLDER invocation id while a newer effect exists = refused")
ok(P.DecisionEffects(rows=[PA,NEW]).unresolved(A,I)==["old"],"D3 older applied prior still unresolved for the fresh invocation")
# round-3 reviewer M3 (substring ask match) and M1 (reused produced invocation)
def other(a): return [{"id":"o1","ts":"2026-11-11T08:00:00-08:00","what":f"a1577-effect ask={a} inv=zz outcome=applied (note)","evidence":"real readback"}]
for ask in ("A1577","A1","A15","A157"):
    ok(P.DecisionEffects(rows=other("A1296")).unresolved(ask,I)==[],f"M3 effect row of another ask does not poison {ask}")
ok(P.DecisionEffects(rows=other("A1296")).unresolved("A1296",I) is None,"M3 own ask with trailing-prose effect row stays UNKNOWN")
ok(P.DecisionEffects(rows=[{"id":"t","ts":"2026-11-11T08:00:00-08:00","what":"A1577-EFFECT ASK=A1577 inv=zz outcome=applied","evidence":"x"}]).unresolved("A1577",I) is None,"M3 case-variant line for the same ask = UNKNOWN")
# round-4 reviewer P1 (punctuation-adjacent / unattributable effect lines) and M1b (launcher-spent ids)
for n,l in [("comma","a1577-effect ask=A-PRIVATE, inv=old outcome=UNKNOWN"),("period","a1577-effect ask=A-PRIVATE. inv=old outcome=UNKNOWN"),("semicolon","a1577-effect ask=A-PRIVATE; inv=old outcome=UNKNOWN"),("quoted",'a1577-effect ask="A-PRIVATE" inv=old outcome=UNKNOWN'),("paren","a1577-effect (ask=A-PRIVATE) inv=old outcome=UNKNOWN"),("glued","a1577-effect ask=A-PRIVATEinv=old outcome=UNKNOWN"),("colon","a1577-effect ask:A-PRIVATE inv=old outcome=UNKNOWN"),("no equals","a1577-effect ask A-PRIVATE inv=old outcome=UNKNOWN"),("no ask at all","a1577-effect inv=old outcome=UNKNOWN"),("bullet-led trailing","a1577-effect inv=old outcome=applied for A-PRIVATE")]:
    ok(un2(sf(l)) is None,"P1 unattributable/adjacent effect line -> UNKNOWN: "+n)
ok(P.DecisionEffects(rows=sf("a1577-effect ask=A-OTHER, inv=old outcome=UNKNOWN")).unresolved(A,I)==[],"P1 line cleanly naming another ask does not poison this one")
ok(P.DecisionEffects(rows=sf("a1577-effect ask=A12 inv=old outcome=applied")).unresolved("A1",I)==[],"P1 A12 line does not poison A1")
