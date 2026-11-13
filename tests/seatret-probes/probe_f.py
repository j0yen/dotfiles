import sys, json, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fakes import *
w = world("f1-claimfail"); m = load_mod(); real = m.sh
def sh_nc(argv, timeout=120, env=None):
    if "claim" in argv: return 66, "", "Conflict: transient (no mutation)"      # genuine pre-commit refusal, ledger untouched
    return real(argv, timeout, env)
m.sh = sh_nc
rc, ds = call(m.start, db(w)["A1"]); print("F1 claim-failed (no mutation, rc66):", rc, [d["decision"] for d in ds], receipts(w))
m.sh = real; rc2, ds2 = call(m.cmd_launch, "A1"); print("F1 relaunch after claim-failed:", rc2, [d["decision"] for d in ds2], "children", len(children(w)))
# F6: tampered record
w = world("f6"); flag(w, "startfail"); m = load_mod(); unflag(w, "startfail")
os.environ["WR_START_CMD"] = w + "/bin/fake-start"; flag(w, "noop")
open(w + "/stub/noop", "w"); 
