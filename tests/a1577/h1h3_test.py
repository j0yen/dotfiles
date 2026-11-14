import sys,json,tempfile,subprocess,os; sys.path.insert(0,'.')
import a1577_produce as P
A="A1"; E=lambda i:f"a1577-effect ask=A1 inv={i} outcome=applied"; T=lambda s:f"2026-11-11T08:{s:02d}:00-08:00"
RC=json.dumps(dict(schema="a1577-reconcile/1",ask=A,prior_invocation="X",status="reconciled",effects=["e1"],resolution="launched failed check ok",readback="seat running ok ok"))
rows=[dict(id="e1",what=E("X"),evidence="readback one ok",ts=T(1)),dict(id="r1",what="a1577-reconciled ask=A1 prior=X",evidence=RC,ts=T(2)),dict(id="e2",what=E("Y"),evidence="readback two ok",ts=T(3))]
d=tempfile.mkdtemp(); vp=d+"/succ-void"; cp=d+"/cons"; open(vp,"w").write("X\n"); open(d+"/succ-launched","w").write("X\n")
class L:
    row=dict(ask_id=A,status="open",rev="1",what="t\na1577-bind inv=X effect-sha="+"0"*64+" prior=none",check="c")
    def read(s,a): return dict(s.row)
    def append_line(s,a,l,r): s.row=dict(s.row,what=s.row["what"]+"\n"+l,rev="2")
try: P.produce(A,d,L(),P.DecisionEffects(rows=rows),(),"Y",consumed_path=cp,void_path=vp); print("H1 FAIL accepted"); sys.exit(1)
except P.Refused as e: print("OK H1 launched-but-voided X still live: refused:",str(e)[:80])
sh=open("ctl-relaunch.cand2.sh").read().splitlines()
l1=[l for l in sh if l.startswith("_KILLED=0; _NOVOID=0")][0]; l2=[l for l in sh if l.startswith('if [ -n "${WM_SUCC_INV:-}" ] && { case')][0]
h=tempfile.mkdtemp()
r=subprocess.run(["bash","-c","note(){ :; }; "+l1+"; "+l2+"; exit 76"],env=dict(os.environ,HOME=h,WM_SUCC_INV="liveX\nliveY zz"),capture_output=True)
v=h+"/.local/state/aide/succ-void"
assert r.returncode==78 and not os.path.exists(v), (r.returncode,)
print("OK H3 multi-line WM_SUCC_INV exit 78, nothing voided")
r=subprocess.run(["bash","-c","note(){ :; }; "+l1+"; "+l2+"; exit 76"],env=dict(os.environ,HOME=h,WM_SUCC_INV="okTok.1"),capture_output=True)
assert r.returncode==76 and open(v).read()=="okTok.1\n"; print("OK single token passes validation (then 76 voids it)")
print("H1H3-PASS")
