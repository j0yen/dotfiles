#!/usr/bin/env python3
"""Compares the retained review-4 probe rows (p4.py, run through the test harness) with expected-p4.jsonl: rows p01-p13 are the reviewer's own recorded head output
(S/in/review4/probe-head.txt, invocation ids normalised), p14 (adoption readback flips to another holder: refused, no child) and p15 (the HARNESS, which has the seams on,
can be pointed at a decoy; the production entrypoint cannot: prod_entry.py S1-S7) are the same probes' output. One PASS/FAIL line per row."""
import json, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
norm = lambda s: re.sub(r"wr-[A-Za-z0-9]+-\d+-[0-9a-f]{8}", "INV", s)
exp = {}
for l in open(HERE + "/expected-p4.jsonl"):
    j = json.loads(l); exp[j["row"]] = j
p = subprocess.run([sys.executable, "-I", HERE + "/p4.py"], capture_output=True, text=True, env=dict(os.environ), timeout=600)
got = {}
for l in p.stdout.splitlines():
    if l.startswith("{"):
        j = json.loads(norm(l)); got[j["row"]] = j
fails = 0
for k in exp:
    if got.get(k) == exp[k]: print("PASS retained review-4 probe %s matches its expected row" % k)
    else: fails += 1; print("FAIL retained review-4 probe %s: got %s expected %s" % (k, json.dumps(got.get(k), sort_keys=True)[:300], json.dumps(exp[k], sort_keys=True)[:300]))
if set(got) - set(exp): fails += 1; print("FAIL unexpected probe rows: %s" % sorted(set(got) - set(exp)))
sys.exit(1 if fails else 0)
