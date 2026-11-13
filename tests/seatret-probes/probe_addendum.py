import os, sys, json, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fakes import *
res = {}
def show(tag, **kw): print(tag, json.dumps(kw, sort_keys=True)); res[tag] = kw

# ---------- (a) partial start: client returns nonzero AFTER the unit/child ran (and the late variant: child runs after the nonzero return)
w = world("a-partial"); flag(w, "partial"); m = load_mod()
rc, ds = call(m.start, db(w)["A1"])
inv = [f[:-5] for f in os.listdir(w + "/state/launches")][0]
show("a1_partial_start", rc=rc, decisions=[d["decision"] for d in ds], receipts=receipts(w), children=len(children(w)), terminals=len(terminals(w)),
     claim_in_ledger=db(w)["A1"]["claim"])
rc2, ds2 = call(m.cmd_consume)
show("a1_consume_after", rc=rc2, decisions=[d["decision"] for d in ds2], receipts=receipts(w), unknown_effect_reported="unknown-effect" in str(ds2))
# same, with an UNKNOWN effect left by the child that actually ran: effect BEGIN without END
w = world("a-partial-effect"); flag(w, "partial"); m = load_mod()
os.environ["RC"] = "0"
# make the fake coder write an effect BEGIN w/o END
open(w + "/bin/fake-coder", "w").write('#!/usr/bin/env bash\necho "$1 INV=$WR_INVOCATION" >> "$STUB/child.log"\necho "BEGIN deploy" > "$WR_EFFECT_FILE"\nprintf \'{"model":"m"}\\n\' > "$WR_PROVENANCE_FILE"\nexit 0\n')
rc, ds = call(m.start, db(w)["A1"]); rc2, ds2 = call(m.cmd_consume)
show("a2_partial_with_unknown_effect", start_rc=rc, receipts=receipts(w), consume_decisions=[d["decision"] for d in ds2], children=len(children(w)))
# late terminal: client nonzero, child runs afterwards
w = world("a-late"); flag(w, "late"); m = load_mod()
rc, ds = call(m.start, db(w)["A1"])
inv = [f[:-5] for f in os.listdir(w + "/state/launches")][0]
call(m.cmd_supervise, inv)         # the unit that the client reported as failed now runs and writes its terminal
rc2, ds2 = call(m.cmd_consume)
show("a3_late_terminal", start_rc=rc, receipts=receipts(w), terminals=terminals(w), consume_decisions=[d["decision"] for d in ds2], children=len(children(w)),
     note="terminal exists, receipt stays start-failed; late terminal never consumed")
# a4: relaunch after partial start against a store that allows re-claim (the AUTHOR fixture semantics) = second worker on the same ask while first ran
w = world("a-partial-relaunch-permissive"); flag(w, "partial"); m = load_mod()
call(m.start, db(w)["A1"])
open(w + "/bin/wm-asks", "w").write(FAKE_ASKS.replace('if r.get("claim"): sys.stderr', 'if r.get("claim") and not r["claim"].startswith("wr-"): sys.stderr')); bind(w)
unflag(w, "partial"); m = load_mod()
rc3, ds3 = call(m.start, db(w)["A1"])
show("a4_relaunch_after_partial_permissive_store", rc=rc3, decisions=[d["decision"] for d in ds3], children=len(children(w)), receipts=receipts(w))

# ---------- (b) canonical claim success, readback failure
w = world("b-readback"); flag(w, "readback-down-after"); m = load_mod()
rc, ds = call(m.start, db(w)["A1"])
inv = [f[:-5] for f in os.listdir(w + "/state/launches")][0]
rec = json.load(open(w + "/state/launches/" + inv + ".json"))
show("b1_claim_ok_readback_down", rc=rc, decisions=[d["decision"] for d in ds], rec_state=rec["state"], receipts=receipts(w), children=len(children(w)), ledger_claim=db(w)["A1"]["claim"])
unflag(w, "readback-down"); unflag(w, "readback-down-after")
rc2, ds2 = call(m.cmd_launch, "A1"); show("b1_relaunch_after_store_back", rc=rc2, decisions=[d["decision"] for d in ds2], children=len(children(w)))
rc3, ds3 = call(m.cmd_reconcile, inv, "present", "owner"); show("b1_reconcile_claim_unknown", rc=rc3, decisions=[d["decision"] for d in ds3])
rc3b, ds3b = call(m.cmd_resume, inv, "owner"); show("b1_resume_claim_unknown", rc=rc3b, decisions=[d["decision"] for d in ds3b], children=len(children(w)), claim_calls=open(w + "/stub/calls.log").read().count("asks claim"))
rc4, ds4 = call(m.cmd_consume); show("b1_consume", rc=rc4, receipts=receipts(w))
# claim committed then client exits nonzero (REAL: rc 75 committed-but-unpublished; or 1 uncaught), readback fine
for code in (75, 1):
    w = world("b-aftercommit-%d" % code); flag(w, "after-commit-rc", str(code)); m = load_mod()
    rc, ds = call(m.start, db(w)["A1"])
    show("b2_after_commit_rc%d_readback_ok" % code, rc=rc, decisions=[d["decision"] for d in ds], children=len(children(w)), receipts=receipts(w))
# claim committed, client exits nonzero, readback ALSO down
w = world("b-aftercommit-down"); flag(w, "after-commit-rc", "75"); flag(w, "readback-down"); m = load_mod()
rc, ds = call(m.start, db(w)["A1"])
show("b3_after_commit_rc75_readback_down", rc=rc, decisions=[d["decision"] for d in ds], receipts=receipts(w), ledger_claim=db(w)["A1"]["claim"])
# S3: claim client TimeoutExpired/OSError (sh -> 127) AFTER commit, readback down
w = world("b-timeout"); m = load_mod(); real_sh = m.sh
def sh_to(argv, timeout=120, env=None):
    if "claim" in argv:
        real_sh(argv, timeout, env)                      # the real fake claim COMMITS
        flag(w, "readback-down")                         # then the client hangs -> TimeoutExpired -> sh maps to 127; store unreadable
        return 127, "", "timed out"
    return real_sh(argv, timeout, env)
m.sh = sh_to
rc, ds = call(m.start, db(w)["A1"])
show("s3_timeout_after_commit_readback_down", rc=rc, decisions=[d["decision"] for d in ds], receipts=receipts(w), ledger_claim=db(w)["A1"]["claim"])
unflag(w, "readback-down"); m.sh = real_sh
rc2, ds2 = call(m.cmd_launch, "A1"); show("s3_relaunch_later", rc=rc2, decisions=[d["decision"] for d in ds2], children=len(children(w)))

# ---------- (c) unreachable host / unknown effect on the start client
w = world("c-unreachable"); flag(w, "probe-down"); m = load_mod(); real_sh = m.sh
def sh_oserr(argv, timeout=120, env=None):
    if argv and "fake-start" in argv[0]: return 127, "", "[Errno 2] No such file (client missing / bus unreachable)"
    return real_sh(argv, timeout, env)
m.sh = sh_oserr
rc, ds = call(m.start, db(w)["A1"])
show("c1_start_client_unreachable_127", rc=rc, decisions=[d["decision"] for d in ds], receipts=receipts(w), children=len(children(w)), ledger_claim=db(w)["A1"]["claim"])
m.sh = real_sh
rc2, ds2 = call(m.cmd_launch, "A1"); show("c1_relaunch", rc=rc2, decisions=[d["decision"] for d in ds2], receipts=receipts(w), children=len(children(w)))
inv_c = [f[:-5] for f in os.listdir(w + "/state/launches")][0]
rc2b, ds2b = call(m.cmd_resume, inv_c, "owner"); show("c1_resume_still_unreachable", rc=rc2b, decisions=[d["decision"] for d in ds2b], receipts=receipts(w))
unflag(w, "probe-down")
rc2c, ds2c = call(m.cmd_resume, inv_c, "owner"); show("c1_resume_proved_absent", rc=rc2c, decisions=[d["decision"] for d in ds2c], receipts=receipts(w))
# R3-5: the reconciliation is exercised STRUCTURALLY, not by grepping the source: the unit probe seam answers absent / present / unknown for the three stub modes
# and the route's own unit_probe() maps them (a source-text grep proves nothing about behaviour)
modes = []
for md in (None, "unit-present", "probe-down"):
    for x in ("unit-present", "probe-down"): unflag(w, x)
    if md: flag(w, md)
    modes.append(m.unit_probe("worker-route-wr-A1-4-deadbeef"))
for x in ("unit-present", "probe-down"): unflag(w, x)
show("c2_reconciliation_code_present", unit_probe_modes=modes)
src = open(SRC).read()

# ---------- (d) proved no-start then retry (positive)
w = world("d-nostart-real-api"); flag(w, "startfail"); m = load_mod()
rc, ds = call(m.start, db(w)["A1"])
show("d1_first_launch_startfail", rc=rc, receipts=receipts(w), children=len(children(w)), ledger_claim=db(w)["A1"]["claim"])
unflag(w, "startfail")
rc2, ds2 = call(m.cmd_launch, "A1")
show("d2_retry_against_REAL_claim_semantics", rc=rc2, decisions=[d["decision"] for d in ds2], children=len(children(w)), receipts=receipts(w))
rc3, ds3 = call(m.cmd_launch, "A1")
show("d3_retry_again_real", rc=rc3, decisions=[d["decision"] for d in ds3], children=len(children(w)))
w = world("d-nostart-permissive"); flag(w, "startfail"); m = load_mod()
call(m.start, db(w)["A1"]); unflag(w, "startfail")
open(w + "/bin/wm-asks", "w").write(FAKE_ASKS.replace('if r.get("claim"): sys.stderr', 'if r.get("claim") and not r["claim"].startswith("wr-"): sys.stderr')); bind(w)
m = load_mod(); rc2, ds2 = call(m.cmd_launch, "A1")
show("d4_retry_against_AUTHOR_fixture_semantics(permissive_reclaim)", rc=rc2, decisions=[d["decision"] for d in ds2], children=len(children(w)), receipts=receipts(w))

# ---------- binding: real entrypoint / canonical target
w = world("e-binding")
decoy = w + "/bin/wm-asks"        # any executable named by WM_ASKS_CMD is accepted
m = load_mod()
show("e1_asks_resolution", ASKS=m.ASKS_CMD, validated_target=any(k in src for k in ("realpath(ASKS", "sha256", "ledger_path", "WM_ASKS_DB", "canonical-target", "--version")), bound_ok=m.bound_ok())
os.environ["WM_ASKS_CMD"] = "/nonexistent/decoy"
m = load_mod(); rc, ds = call(m.cmd_launch, "A1"); show("e2_unbound_cmd_unreadable", rc=rc, decisions=[d["decision"] for d in ds])
w = world("e-binding-decoy"); open(w + "/bin/decoy", "w").write(FAKE_ASKS); os.chmod(w + "/bin/decoy", 0o755); os.environ["WM_ASKS_CMD"] = w + "/bin/decoy"
m = load_mod(); rc, ds = call(m.cmd_launch, "A1"); show("e3_decoy_executable_refused", rc=rc, decisions=[d["decision"] for d in ds], children=len(children(w)))
json.dump(res, open(os.path.join(BASE, "probe_addendum.json"), "w"), indent=1, sort_keys=True)
