#!/usr/bin/env python3
"""rb-merge-adv-check.py DB V OWNER/NAME PR [WAIVER-ID] -- the ADV pre-check for rb-merge.sh (INTERIM: the real gate is a future G8 in wm_decide).
Reads the ledger FILE wm-decide writes (decisions.sqlite, mode=ro, no time window, no wm_decide import). Every pattern comes from the environment, set by
rb-merge.sh from .local/lib/adv-grammar.sh: this file holds no copy of the grammar. Prints ONE line and exits 0:
  NOTRIGGER            neither trigger holds; rb-merge.sh goes on to the merge gate
  OK <G>               the newest ADV row for (G, V's COMMIT) passes and its log is a non-empty regular file
  WAIVED <d-id>        a valid controller waiver for this PR
  REFUSE <TOKEN> <G>   TOKEN in ADV-MISSING ADV-STALE ADV-NOT-PASS ADV-NOLOG ADV-UNCHECKED ADV-WAIVER-BAD (G = '-' when unknown)
Any exception is printed as REFUSE ADV-UNCHECKED (fail closed)."""
import datetime as dt
import os
import re
import sqlite3
import sys
from urllib.parse import quote


class Refuse(Exception):
    def __init__(self, token, g="-"):
        super().__init__(token)
        self.token, self.g = token, g


def sub(fmt, repo, pr):
    return fmt.replace("@REPO@", re.escape(repo)).replace("@PR@", re.escape(pr))


def parse_ts(s):
    try:
        t = dt.datetime.fromisoformat(s)
    except (TypeError, ValueError):
        return dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    return t if t.tzinfo else t.astimezone()


def get(db, rid):
    r = db.execute("SELECT * FROM decisions WHERE id = ?", (rid,)).fetchone()
    return dict(r) if r else None


def check_waiver(db, wid, repo, pr, env):
    w = get(db, wid)
    if w is None or w["kind"] != env["ADV_WAIVE_KIND"] or w["agent"] != env["ADV_WAIVE_AGENT"]:
        raise Refuse("ADV-WAIVER-BAD")
    what = w["what"] or ""
    if not re.search(sub(env["ADV_WAIVE_RE_FMT"], repo, pr), what):
        raise Refuse("ADV-WAIVER-BAD")
    untils = [m.group(1) for m in re.finditer(env["ADV_UNTIL_RE"], what)]
    if not untils:
        raise Refuse("ADV-WAIVER-BAD")
    now = dt.datetime.now(dt.timezone.utc)
    for u in untils:
        try:
            t = dt.datetime.fromisoformat(u)
        except ValueError:
            raise Refuse("ADV-WAIVER-BAD")
        if (t if t.tzinfo else t.astimezone()) <= now:
            raise Refuse("ADV-WAIVER-BAD")
    return wid


def verdict_commit(v, g, env):
    ev = (v.get("evidence") or "").split("\nATTACH ")[0]   # attached log bodies are not claims
    found = {m.group(1).lower() for m in re.finditer(env["ADV_COMMIT_RE"], (v.get("what") or "") + "\n" + ev, re.I)}
    if not found:
        found = {m.group(1).lower() for m in re.finditer(env["ADV_COMMIT_RE"], g.get("what") or "", re.I)}
    longest = max(found, key=len) if found else None
    if longest is None or any(not longest.startswith(c) for c in found):
        raise Refuse("ADV-UNCHECKED", g["id"])   # no COMMIT, or conflicting COMMIT= values
    return longest


def run(db_path, vid, repo, pr, waive, env):
    db = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(db_path)), uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    if waive:
        return "WAIVED " + check_waiver(db, waive, repo, pr, env)
    v = get(db, vid)
    gid = ((v or {}).get("gates") or "").strip()
    g = get(db, gid) if gid else None
    if v is None or g is None:
        raise Refuse("ADV-UNCHECKED", gid or "-")
    trigger = repo in env["ADV_TRIGGER_REPOS"].split()
    if not trigger:
        brief = re.compile(env["ADV_BRIEF_RE"], re.I)
        trigger = any(brief.search(g.get(f) or "") for f in ("what", "why", "evidence"))
    if not trigger:
        return "NOTRIGGER"
    vc = verdict_commit(v, g, env)
    adv = re.compile(sub(env["ADV_RE_FMT"], repo, pr))
    rows = []
    for a in db.execute("SELECT * FROM decisions WHERE gates = ? AND kind = ?", (gid, env["ADV_ROW_KIND"])):
        a = dict(a)
        m = adv.match(a["what"] or "")
        if m:
            rows.append((parse_ts(a["ts"]), a["id"], m.group(1), re.search(env["ADV_COMMIT_RE"], a["what"], re.I).group(1).lower(), a["what"]))
    if not rows:
        raise Refuse("ADV-MISSING", gid)
    same = sorted(r for r in rows if r[3].startswith(vc))
    if not same:
        raise Refuse("ADV-STALE", gid)
    _ts, _id, word, _c, what = same[-1]   # the NEWEST row decides
    if word != env["ADV_PASS_WORD"]:
        raise Refuse("ADV-NOT-PASS", gid)
    log = re.search(env["ADV_LOG_RE"], what).group(1)
    if not (os.path.isfile(log) and os.path.getsize(log) > 0):
        raise Refuse("ADV-NOLOG", gid)
    return "OK " + gid


def main(argv):
    if len(argv) not in (5, 6):
        print("REFUSE ADV-UNCHECKED -")
        return 0
    try:
        out = run(argv[1], argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else "", os.environ)
    except Refuse as r:
        out = "REFUSE %s %s" % (r.token, r.g)
    except Exception:
        out = "REFUSE ADV-UNCHECKED -"
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
