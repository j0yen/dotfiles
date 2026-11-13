import json, os, sys, time, subprocess, threading, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from w4 import *
ROWS = {}
def row(f): ROWS[f.__name__] = f; return f
def newinv(w, exclude): return [i for i in w.invs() if i not in exclude]
@row
def p01_chain4():
    w = World("p01"); w.flag("startfail")
    w.run("launch", "A1"); w.run("launch", "A1"); w.run("launch", "A1"); w.unflag("startfail")
    rc, ds, _ = w.run("launch", "A1"); w.run("consume"); rc2, ds2, _ = w.run("launch", "A1")
    return dict(adopt_ok=(rc, len(w.invs())), after=(rc2, dec(ds2)), children=len(w.children()), claims=w.calls("asks claim"), rcpt=sorted(set(w.receipts().values())))
@row
def p02_after_consumed():
    w = World("p02"); w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail"); w.run("launch", "A1"); w.run("consume"); rc, ds, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), children=len(w.children()), claims=w.calls("asks claim"))
@row
def p03_after_failed():
    w = World("p03"); w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail"); w.env["RC"] = "1"; w.run("launch", "A1"); w.run("consume"); rc, ds, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), children=len(w.children()))
@row
def p04_late_terminal():
    w = World("p04"); w.flag("startfail"); w.run("launch", "A1"); w.run("launch", "A1")
    B = [i for i in w.invs() if w.rec("launches", i).get("adopts")][0]; r = w.rec("launches", B)
    json.dump({"invocation": B, "nonce": r["nonce"], "ask": "A1", "host": "h1", "rc": 0, "status": "ok", "effect": "x", "provenance": "unrecorded", "started": "s", "ended": "e"}, open(w.w + "/state/terminals/%s.json" % B, "w"))
    w.run("consume"); w.unflag("startfail"); rc, ds, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), children=len(w.children()), late=os.path.exists(w.w + "/state/consumed/%s.late-terminal.json" % B))
@row
def p05_unit_appears_before_adoption():
    w = World("p05"); w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail"); w.flag("unit-present"); rc, ds, _ = w.run("launch", "A1")
    w.unflag("unit-present"); w.flag("probe-down"); rc2, ds2, _ = w.run("launch", "A1"); w.unflag("probe-down"); rc3, ds3, _ = w.run("launch", "A1")
    return dict(present=(rc, dec(ds)), down=(rc2, dec(ds2)), clear=(rc3, dec(ds3)), children=len(w.children()), claims=w.calls("asks claim"))
@row
def p06_supervise_vs_finish_race():
    w = World("p06"); w.flag("slowfail"); w.flag("probe-slow")
    res = {}
    t = threading.Thread(target=lambda: res.update(l=w.run("launch", "A1"))); t.start()
    for _ in range(100):
        if os.path.exists(w.w + "/stub/probe-entered"): break
        time.sleep(0.05)
    inv = w.invs()[0]; t0 = time.time()
    sv = w.run("supervise", inv)         # blocks on the start lock until finish_start decides
    t.join()
    return dict(launch=(res["l"][0], dec(res["l"][1])), supervise=(sv[0], dec(sv[1]), round(time.time() - t0) >= 1), children=len(w.children()), started_marker=os.path.exists("%s/state/started/%s.json" % (w.w, inv)), rcpt=w.receipts())
@row
def p07_partial_start():
    w = World("p07"); w.flag("partial"); rc, ds, _ = w.run("launch", "A1"); rc2, ds2, _ = w.run("consume"); rc3, ds3, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), consume=dec(ds2), relaunch=(rc3, dec(ds3)), children=len(w.children()), rcpt=sorted(set(w.receipts().values())), claims=w.calls("asks claim"))
@row
def p07b_queued_unit():
    w = World("p07b"); w.flag("queued"); rc, ds, _ = w.run("launch", "A1"); rc2, ds2, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), relaunch=(rc2, dec(ds2)), children=len(w.children()), claims=w.calls("asks claim"))
@row
def p07c_start_unknown_blocks():
    w = World("p07c"); w.flag("startfail"); w.flag("probe-down"); rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    rc2, ds2, _ = w.run("resume", inv, "--by", "o"); rc3, ds3, _ = w.run("launch", "A1"); w.unflag("probe-down"); rc4, ds4, _ = w.run("resume", inv, "--by", "o"); rc5, ds5, _ = w.run("launch", "A1")
    return dict(first=(rc, dec(ds)), resume_down=(rc2, dec(ds2)), relaunch_blocked=(rc3, dec(ds3)), resume_up=(rc4, dec(ds4), w.receipts().get(inv)), retry=(rc5, dec(ds5)), children=len(w.children()))
@row
def p08_after_commit_rc():
    out = {}
    w = World("p08a"); w.flag("after-commit-rc", "75"); rc, ds, _ = w.run("launch", "A1"); out["up"] = (rc, dec(ds), len(w.children()), w.calls("asks claim"))
    w = World("p08b"); w.flag("after-commit-rc", "75"); w.flag("readback-down-after"); rc, ds, _ = w.run("launch", "A1"); inv = w.invs()[0]
    rc2, ds2, _ = w.run("launch", "A1"); rc3, ds3, _ = w.run("resume", inv, "--by", "o"); w.unflag("readback-down"); rc4, ds4, _ = w.run("resume", inv, "--by", "o"); rc5, ds5, _ = w.run("launch", "A1")
    out["down"] = dict(first=(rc, dec(ds)), relaunch=(rc2, dec(ds2)), resume_down=(rc3, dec(ds3)), resume_up=(rc4, dec(ds4)), again=(rc5, dec(ds5)), children=len(w.children()), claims=w.calls("asks claim"))
    return out
@row
def p08c_claim_refused():
    w = World("p08c"); w.flag("refuse2"); rc, ds, _ = w.run("launch", "A1"); w.unflag("refuse2"); rc2, ds2, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), retry=(rc2, dec(ds2)), children=len(w.children()))
@row
def p09_positive_retry():
    w = World("p09"); w.flag("startfail"); rc, ds, _ = w.run("launch", "A1"); w.unflag("startfail"); rc2, ds2, _ = w.run("launch", "A1"); w.run("consume")
    return dict(first=(rc, dec(ds)), retry=(rc2, dec(ds2)), children=len(w.children()), claims=w.calls("asks claim"), rcpt=sorted(w.receipts().values()))
@row
def p10_missing_keys():
    w = World("p10a"); w.flag("nokey-claim"); rc, ds, _ = w.run("launch", "A1")
    out = dict(noclaim=(rc, dec(ds), w.calls("asks claim"), len(w.children())))
    w = World("p10b"); w.db["B1"] = {"ask_id": "B1", "rev": 1, "status": "open", "claim": None, "waits_on": ["A1"], "what": "x. worker-route: host=h1 launcher=fake-coder arg=b1"}; w.save()
    w.run("launch", "A1"); w.flag("nokey-waits"); rc, ds, _ = w.run("consume")
    out["nowaits"] = (rc, dec(ds), [c for c in w.children() if c.startswith("b1")])
    w.unflag("nokey-waits"); rc, ds, _ = w.run("consume"); out["waits_ok"] = (rc, dec(ds), [c.split()[0] for c in w.children()])
    return out
@row
def p11_chain_member_hosts_and_shape():
    out = {}
    for name, mut in (("other_host", lambda w, A, I: _setrec(w, A, host="h9")), ("planted_marker", lambda w, A, I: open(w.w + "/state/started/%s.json" % A, "w").write("{}")),
                      ("planted_prov", lambda w, A, I: open(w.w + "/state/prov/%s.json" % A, "w").write("{}")), ("planted_effect", lambda w, A, I: open(w.w + "/state/effects/%s.effect" % A, "w").write("BEGIN x\n")),
                      ("claimant_missing", lambda w, A, I: os.unlink(w.w + "/state/launches/%s.json" % A)),
                      ("open_adopter", None)):
        w = World("p11" + name); w.flag("startfail"); w.run("launch", "A1"); A = w.invs()[0]; w.unflag("startfail")
        if name == "open_adopter":
            w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail")
            B = [i for i in w.invs() if i != A][0]; os.unlink(w.w + "/state/consumed/%s.json" % B)
        else: mut(w, A, None)
        rc, ds, _ = w.run("launch", "A1"); out[name] = (rc, dec(ds), len(w.children()))
    return out
def _setrec(w, A, **kw):
    p = w.w + "/state/launches/%s.json" % A; r = json.load(open(p)); r.update(kw); json.dump(r, open(p, "w"))
@row
def p12_foreign_claim_and_resume_host():
    out = {}
    w = World("p12a"); w.db["A1"]["claim"] = "someone@t"; w.save(); rc, ds, _ = w.run("launch", "A1"); out["foreign"] = (rc, dec(ds), len(w.children()), w.calls("asks claim"))
    w = World("p12b"); w.flag("after-commit-rc", "75"); w.flag("readback-down-after"); w.run("launch", "A1"); inv = w.invs()[0]; w.unflag("readback-down"); _setrec(w, inv, host="h9")
    rc, ds, _ = w.run("resume", inv, "--by", "o"); out["resume_other_host"] = (rc, dec(ds), len(w.children()))
    return out
@row
def p13_binding():
    out = {}
    w = World("p13a"); os.unlink(w.w + "/state/asks-binding.json"); rc, ds, _ = w.run("launch", "A1"); out["missing"] = (rc, dec(ds), w.calls("asks"))
    w = World("p13b"); open(w.w + "/bin/wm-asks", "a").write("\n# changed\n"); rc, ds, _ = w.run("launch", "A1"); out["hash"] = (rc, w.calls("asks"))
    w = World("p13c"); os.makedirs(w.w + "/decoy"); open(w.w + "/decoy/wm-asks", "w").write("#!/bin/sh\necho x>>%s/decoy.log\nexit 0\n" % w.w); os.chmod(w.w + "/decoy/wm-asks", 0o755)
    e = dict(w.env); del e["WM_ASKS_CMD"]; e["PATH"] = w.w + "/decoy:" + e["PATH"]; rc, ds, _ = w.run("launch", "A1", env=e); out["decoy_path"] = (rc, os.path.exists(w.w + "/decoy.log"), w.calls("asks"))
    w = World("p13d"); e = dict(w.env); e["WM_ASKS_CMD"] = w.w + "/bin/other"; shutil.copy(w.w + "/bin/wm-asks", w.w + "/bin/other"); rc, ds, _ = w.run("launch", "A1", env=e); out["other_exe_same_content"] = (rc, w.calls("asks"))
    w = World("p13e"); st = json.load(open(w.w + "/state/asks-binding.json")); shutil.move(w.w + "/stub/db.json", w.w + "/stub/db2.json"); shutil.copy(w.w + "/stub/db2.json", w.w + "/stub/db.json"); rc, ds, _ = w.run("launch", "A1"); out["store_replaced"] = (rc, w.calls("asks"))
    w = World("p13f"); os.chmod(w.w + "/bin/wm-asks", 0o777); rc, ds, _ = w.run("launch", "A1"); out["worldwritable_exe"] = (rc, w.calls("asks"))
    w = World("p13g"); e = dict(w.env); e["WR_HOST"] = "h2"; rc, ds, _ = w.run("launch", "A1", env=e); out["other_host"] = (rc, w.calls("asks"))
    w = World("p13h"); os.symlink(w.w + "/bin/wm-asks", w.w + "/bin/link"); os.unlink(w.w + "/state/asks-binding.json")
    r = w.run("bind", "--executable", w.w + "/bin/link", "--store", w.w + "/stub/db.json", "--by", "o"); b = json.load(open(w.w + "/state/asks-binding.json")); out["bind_symlink_resolves"] = (r[0], b["executable"] == os.path.realpath(w.w + "/bin/wm-asks"))
    w = World("p13i"); os.unlink(w.w + "/state/asks-binding.json"); r = w.run("bind", "--executable", "wm-asks", "--store", w.w + "/stub/db.json", "--by", "o"); out["bind_name_not_path"] = r[0]
    w = World("p13j"); os.chmod(w.w + "/stub/db.json", 0o666); rc, ds, _ = w.run("launch", "A1"); out["worldwritable_store"] = (rc, w.calls("asks"))
    w = World("p13k"); e = dict(w.env); e["WR_ASKS_BINDING"] = w.w + "/forged.json"; shutil.copy(w.w + "/state/asks-binding.json", w.w + "/forged.json"); os.unlink(w.w + "/state/asks-binding.json"); rc, ds, _ = w.run("launch", "A1", env=e); out["env_binding_override_ignored"] = (rc, w.calls("asks"))
    return out
@row
def p14_adopt_readback_flip():
    w = World("p14"); w.flag("startfail"); w.run("launch", "A1"); w.unflag("startfail"); w.flag("flip"); open(w.w + "/stub/qn", "w").write("0")
    rc, ds, _ = w.run("launch", "A1")
    return dict(rc=rc, d=dec(ds), children=len(w.children()))
@row
def p15_switch_settable_by_caller():
    w = World("p15"); dec_exe = w.w + "/decoy-asks"; shutil.copy(w.w + "/bin/wm-asks", dec_exe); open(dec_exe, "a").write("\nopen(S + '/decoy.ran', 'w').close()\n")
    st2 = w.w + "/state2"; os.makedirs(st2)
    e = dict(w.env, WR_STATE=st2, WM_ASKS_CMD=dec_exe)
    r1 = w.run("bind", "--executable", dec_exe, "--store", w.w + "/stub/db.json", "--by", "anyone", env=e)
    r2 = w.run("launch", "A1", env=e)
    e2 = {k: v for k, v in e.items() if k != "WR_TEST_SEAMS"}
    r3 = w.run("launch", "A1", env=e2) if False else None   # not run: without the switch STATE would be the REAL passwd home
    return dict(bind_decoy=r1[0], launch=(r2[0], dec(r2[1])), decoy_ran=os.path.exists(w.w + "/stub/decoy.ran"))
if __name__ == "__main__":
    only = sys.argv[1:]
    for k, f in ROWS.items():
        if only and not any(k.startswith(o) for o in only): continue
        try: print(json.dumps({"row": k, "r": f()}, sort_keys=True, default=str))
        except Exception as e: print(json.dumps({"row": k, "error": repr(e)}))
