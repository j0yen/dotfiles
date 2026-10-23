#!/usr/bin/env python3
# rb 10-22 12:4x PM (jsy-29 ask 2, after gate cap 13 / max_runs 2): minutes each run's GATE-class cargo units wait on the
# MemGate. Source = journal op cargo-admission (class gate): a wait episode runs from its first decision=wait row to the next
# grant/timeout for the same (run_id, producer), or to now if still open. Prints one row per run (total minutes, episodes, open).
# Runs > LIMIT (30) minutes print an RB-BELL GATE-WAIT line -> the seat takes a DECISION to CTRL (candidate: price gate on anon 7.1 G).
# Usage: gate-wait-minutes.py [--since ISO] [--journal PATH] [--limit 30] | --selftest
import sys, json, datetime as dt, os, tempfile
def parse(ts):
    return dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
def compute(lines, since, now):
    open_, tot, eps = {}, {}, {}
    for l in lines:
        if '"cargo-admission"' not in l or '"gate"' not in l: continue
        try: d = json.loads(l); r = d["row"]; t = parse(d["ts"])
        except Exception: continue
        if d.get("op") != "cargo-admission" or r.get("class") != "gate" or t < since: continue
        k = (str(r.get("run_id")), str(r.get("producer"))); dec = r.get("decision")
        if dec == "wait":
            open_.setdefault(k, t)
        elif dec in ("grant", "timeout") and k in open_:
            s = open_.pop(k); run = k[0]
            tot[run] = tot.get(run, 0.0) + (t - s).total_seconds() / 60; eps[run] = eps.get(run, 0) + 1
    still = {}
    for (run, _), s in open_.items():
        tot[run] = tot.get(run, 0.0) + (now - s).total_seconds() / 60; eps[run] = eps.get(run, 0) + 1; still[run] = 1
    return tot, eps, still
def main(a):
    if a[:1] == ["--selftest"]:
        z = dt.datetime(2026, 10, 22, 19, 0, tzinfo=dt.timezone.utc)
        row = lambda m, run, dec, cls="gate", p="py": json.dumps({"op": "cargo-admission", "ts": (z + dt.timedelta(minutes=m)).isoformat(), "row": {"class": cls, "decision": dec, "run_id": run, "producer": p}})
        L = [row(0, "1", "wait"), row(5, "1", "wait"), row(12, "1", "grant"), row(0, "2", "wait", cls="inner"), row(1, "2", "grant", cls="inner"),
             row(20, "3", "wait"), row(30, "1", "wait", p="q"), row(31, "1", "grant", p="q"), "garbage", row(-90, "4", "wait")]
        tot, eps, still = compute(L, z, z + dt.timedelta(minutes=50))
        ok = round(tot.get("1", 0)) == 13 and eps.get("1") == 2 and "2" not in tot and round(tot.get("3", 0)) == 30 and still == {"3": 1} and "4" not in tot
        print("SELFTEST PASS" if ok else f"SELFTEST FAIL {tot} {eps} {still}"); return 0 if ok else 1
    j = os.path.expanduser("~/.local/state/wm-build/journal.jsonl"); since = "2026-10-22T19:29:00+00:00"; lim = 30.0
    i = 0
    while i < len(a):
        if a[i] == "--journal": j = a[i + 1]; i += 2
        elif a[i] == "--since": since = a[i + 1]; i += 2
        elif a[i] == "--limit": lim = float(a[i + 1]); i += 2
        else: print(f"unknown arg {a[i]}", file=sys.stderr); return 2
    sn = parse(since); now = dt.datetime.now(dt.timezone.utc)
    with open(j, errors="replace") as f: tot, eps, still = compute(f, sn, now)
    print(f"gate-wait since {since}: runs={len(tot)} total_min={sum(tot.values()):.1f}")
    for run in sorted(tot, key=lambda r: -tot[r]):
        print(f"{'RB-BELL GATE-WAIT>' + str(int(lim)) + ' ' if tot[run] > lim else ''}run={run} wait_min={tot[run]:.1f} episodes={eps[run]}{' OPEN' if run in still else ''}")
    return 0
sys.exit(main(sys.argv[1:]))
