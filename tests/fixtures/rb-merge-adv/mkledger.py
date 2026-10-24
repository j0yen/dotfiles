"""mkledger.py STATE_DIR SPEC_JSON -- build <STATE_DIR>/decisions.sqlite for tests/rb-merge-adv.test.sh and print "<G id> <V id>".
Every row is a COPY of a captured real ledger row (real-rows.json: d-20261024-101751-r7-d001 = the gated row G, d-20261024-101957-r7-2b5b = the verdict row V,
both from the live ledger 10-24); only id, COMMIT, the repo#pr tokens and the target fields are edited. ADV and waiver rows copy the V (kind verdict) and G
(kind other) column shapes; only their what/kind/agent/gates/ts differ. The DDL is the live table's (decisions.ddl.sql)."""
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
state, spec = sys.argv[1], json.loads(sys.argv[2])
rows = {r["id"]: r for r in json.load(open(os.path.join(HERE, "real-rows.json")))}
REAL_G, REAL_V = rows["d-20261024-101751-r7-d001"], rows["d-20261024-101957-r7-2b5b"]
REAL_REPO, REAL_PR, REAL_COMMIT = "j0yen/synthorg", "434", "d3fd3c990a8fc73234bd81ed9b2578797f4e158c"
repo, pr, commit = spec["repo"], str(spec["pr"]), spec.get("commit", "a" * 40)
SUF = spec.get("suffix", "1")


def retarget(text):
    return (text or "").replace(REAL_REPO + "#" + REAL_PR, repo + "#" + pr).replace(REAL_COMMIT, commit)


def copy(real, rid, **over):
    r = dict(real)
    for k in ("what", "why", "evidence"):
        r[k] = retarget(r[k])
    t = json.loads(r["target"])
    if "run" in t:
        t.update(host=repo.split("/")[1], run=int(pr))
    r["target"] = json.dumps(t)
    r["id"] = rid
    r.update(over)
    return r


def rid(tag):
    return "d-20261024-1100%s-r7-%s%s" % (SUF.zfill(2)[:2], tag, SUF)


g_over = {}
for fld in spec.get("brief_in", []):   # where the brief token goes in G: what | why | evidence
    g_over[fld] = retarget(REAL_G[fld]) + " " + spec["brief_tok"]
G = copy(REAL_G, rid("dd"), **g_over)
V = copy(REAL_V, rid("bb"), gates=G["id"])
out = [G, V]
n = 0
for a in spec.get("rows", []):
    n += 1
    ts = "2026-10-24T11:%02d:00-07:00" % a.get("min", n)
    if a["role"] == "adv":
        what = a["what"].format(repo=repo, pr=pr, commit=a.get("commit", commit))
        gates = G["id"] if a.get("gates", "G") == "G" else "d-20261024-100000-r7-0000"
        out.append(copy(REAL_V, rid("a%d" % n), what=what, ts=ts, gates=gates, kind=a.get("kind", "verdict")))
    else:   # waiver: a copy of the real kind=other row G, kind / agent / what are the knobs
        what = a["what"].format(repo=repo, pr=pr)
        out.append(copy(REAL_G, rid("w%d" % n), what=what, ts=ts, kind=a.get("kind", "other"), agent=a.get("agent", "controller")))
os.makedirs(state, exist_ok=True)
db = sqlite3.connect(os.path.join(state, "decisions.sqlite"))
db.executescript(open(os.path.join(HERE, "decisions.ddl.sql")).read())
cols = [c[1] for c in db.execute("PRAGMA table_info(decisions)")]
for r in out:
    db.execute("INSERT INTO decisions (%s) VALUES (%s)" % (",".join(cols), ",".join("?" * len(cols))), [r.get(c) for c in cols])
db.commit()
print(G["id"], V["id"], *[r["id"] for r in out[2:]])
