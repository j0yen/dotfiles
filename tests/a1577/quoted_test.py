import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a1577_produce as p
T = "a1577-effect ask=A-PRIVATE inv=inv-private outcome=applied"
EV = "This is a refusal, no child or effect occurred."
neg = {
 "hermes-exact": "Negative control: never accept quoted text `%s` as an effect." % T,
 "backtick-only": "`%s`" % T,
 "blockquote": "> " + T,
 "indented": "    " + T,
 "bullet": "- " + T,
 "trailing-prose": T + " as an effect",
 "double-quoted": '"%s"' % T,
 "after-prose-two-lines": "Negative control:\n`%s`\nnot an effect" % T,
}
bad = 0
for k, w in neg.items():
    r = [{"id": "owned-NON-EFFECT", "what": w, "evidence": EV}]
    got = p.DecisionEffects(rows=r).effect("A-PRIVATE", "inv-private")
    ok = got is None; bad += not ok; print(("OK " if ok else "WRONG ") + k, "" if ok else got)
pos = [{"id": "eff-real-1", "what": T, "evidence": "child pid 4242 wrote marker abc123"}]
g = p.DecisionEffects(rows=pos).effect("A-PRIVATE", "inv-private")
ok = g is not None and b'"source_row": "eff-real-1"' in g; bad += not ok; print(("OK " if ok else "WRONG ") + "typed positive control")
print("QUOTED-NEG-PASS" if not bad else "FAILED %d" % bad); sys.exit(bool(bad))
