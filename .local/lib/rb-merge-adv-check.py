#!/usr/bin/env python3
"""rb-merge-adv-check.py DB V OWNER/NAME PR [WAIVER-ID] -- the ADV pre-check for rb-merge.sh (INTERIM: the real gate is a future G8 in wm_decide).
Reads the ledger FILE wm-decide writes (decisions.sqlite, mode=ro, no time window, no wm_decide import). Every pattern comes from the environment, set by
rb-merge.sh from .local/lib/adv-grammar.sh: this file holds no copy of the grammar. Prints ONE line and exits 0:
  NOTRIGGER            neither trigger holds; rb-merge.sh goes on to the merge gate
  OK <G> <A-id> <A-ts> <H>   the newest ADV row for (G, V's COMMIT) passes and its log is a non-empty regular file (H = the A row's COMMIT)
  WAIVED <d-id>        a valid controller waiver for this PR
  REFUSE <TOKEN> <G> [reason]   TOKEN in ADV-MISSING ADV-STALE ADV-NOT-PASS ADV-NOLOG ADV-UNCHECKED ADV-COMMIT-SHORT ADV-WAIVER-BAD (G = '-' when unknown; reason only on a waiver refusal)
The OK line's H is the ADV row's full 40-hex COMMIT; rb-merge.sh compares it with the PR's live headRefOid (ADV-STALE-HEAD) -- this helper never talks to GitHub.
Any exception is printed as REFUSE ADV-UNCHECKED (fail closed).
`--dump-re OWNER/NAME PR` prints the ADV row pattern this helper compiles (for the no-drift test: it must be byte-equal to adv_ere in adv-grammar.sh)."""
import datetime as dt
import json
import os
import re
import sqlite3
import sys
from urllib.parse import quote


BAD_TS = dt.datetime.min.replace(tzinfo=dt.timezone.utc)


class Refuse(Exception):
    def __init__(self, token, g="-", reason=""):
        super().__init__(token)
        self.token, self.g, self.reason = token, g, reason


def sub(fmt, repo, pr):
    """The same substitution as adv_ere in adv-grammar.sh (dots escaped, nothing else), so the two engines compile byte-equal text."""
    if not re.fullmatch(r"[0-9]+", pr):
        raise Refuse("ADV-UNCHECKED")
    return fmt.replace("@REPO@", repo.replace(".", "\\.")).replace("@PR@", pr)


def parse_ts(s):
    """Unparsable -> the minimum; ADV rows check ts is not BAD_TS and fail closed."""
    try:
        t = dt.datetime.fromisoformat(s)
    except (TypeError, ValueError):
        return BAD_TS
    return t if t.tzinfo else t.astimezone()


def epoch(s):
    """An ISO-8601 time as epoch seconds (naive = local), or None if unparsable: grade times are compared NUMERICALLY, never as text."""
    try:
        t = dt.datetime.fromisoformat(s)
    except (TypeError, ValueError):
        return None
    return (t if t.tzinfo else t.astimezone()).timestamp()


def get(db, rid):
    r = db.execute("SELECT * FROM decisions WHERE id = ?", (rid,)).fetchone()
    return dict(r) if r else None


def waiver_bad(reason):
    return Refuse("ADV-WAIVER-BAD", "-", reason)


def regrade_of(w):
    """The waiver row's own Fable grade: the `regrade` JSON column ({"by","verdict","ts",...}, one value per row, rewritten in place by swarm-decide-regrade; this helper keeps no
    cache between calls, so a rewrite is seen by the next merge). None if absent, malformed or not an object."""
    try:
        j = json.loads(w.get("regrade") or "null")
    except (TypeError, ValueError):
        return None
    return j if isinstance(j, dict) else None


def check_waiver(db, wid, repo, pr, env):
    cols = {c[1] for c in db.execute("PRAGMA table_info(decisions)")}
    if not {"regrade", "graded_at"} <= cols:
        raise waiver_bad("old-schema")   # graded_at is only this column probe now: the grade time is the regrade JSON's own ts
    w = get(db, wid)
    if w is None:
        raise waiver_bad("not-found")
    if w["kind"] != env["ADV_WAIVE_KIND"]:
        raise waiver_bad("kind")
    if w["agent"] != env["ADV_WAIVE_AGENT"]:
        raise waiver_bad("agent")
    if w["via"] != env["ADV_WAIVE_VIA"]:
        raise waiver_bad("via")
    what = w["what"] or ""
    if not re.search(sub(env["ADV_WAIVE_RE_FMT"], repo, pr), what):
        raise waiver_bad("pr-text")
    untils = [m.group(1) for m in re.finditer(env["ADV_UNTIL_RE"], what)]
    if not untils:
        raise waiver_bad("no-until")
    now = dt.datetime.now(dt.timezone.utc)
    for u in untils:
        try:
            t = dt.datetime.fromisoformat(u)
        except ValueError:
            raise waiver_bad("until-unparsable")
        if (t if t.tzinfo else t.astimezone()) <= now:
            raise waiver_bad("until-past")
    rg = regrade_of(w)
    if rg is None:
        raise waiver_bad("no-regrade")
    if rg.get("by") != env["ADV_REGRADER_AGENT"]:
        raise waiver_bad("regrade-agent")
    if rg.get("verdict") != env["ADV_REGRADE_OK"]:
        raise waiver_bad("regrade-not-confirm")
    wts, rts = epoch(w["ts"]), epoch(rg.get("ts"))   # graded_at is the outcome-pass time (later than ts on every regraded row): the grade time is regrade.ts
    if wts is None or rts is None or not rts > wts:   # missing or unparsable regrade.ts, or not STRICTLY later than the waiver row's ts
        raise waiver_bad("regrade-ts")
    return wid


def verdict_commit(v, g, env):
    ev = (v.get("evidence") or "").split("\nATTACH ")[0]   # attached log bodies are not claims
    found = {m.group(1).lower() for m in re.finditer(env["ADV_COMMIT_RE"], (v.get("what") or "") + "\n" + ev, re.I)}
    if not found:
        found = {m.group(1).lower() for m in re.finditer(env["ADV_COMMIT_RE"], g.get("what") or "", re.I)}
    longest = max(found, key=len) if found else None
    if longest is None or any(not longest.startswith(c) for c in found):
        raise Refuse("ADV-UNCHECKED", g["id"])   # no COMMIT, or conflicting COMMIT= values
    if len(longest) != 40:
        raise Refuse("ADV-COMMIT-SHORT", g["id"])   # a prefix could match an ADV row at another tip that shares it: only a full 40-hex binds
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
    # every filter BEFORE the newest pick: kind, gates G, via, the grammar (the agent and scope tokens, this owner/name#pr), then the COMMIT
    rows = []
    for a in db.execute("SELECT * FROM decisions WHERE gates = ? AND kind = ? AND via = ?", (gid, env["ADV_ROW_KIND"], env["ADV_ROW_VIA"])):
        a = dict(a)
        m = adv.match(a["what"] or "")
        if m:
            ts = parse_ts(a["ts"])
            if ts == BAD_TS:
                raise Refuse("ADV-UNCHECKED", gid)   # a candidate row whose ts cannot be ordered could hide a newer FAIL
            rows.append((ts, a["id"], m.group(1), re.search(env["ADV_COMMIT_RE"], a["what"], re.I).group(1).lower(), a["what"], a["ts"]))
    if not rows:
        raise Refuse("ADV-MISSING", gid)
    same = [r for r in rows if r[3].startswith(vc)]
    if not same:
        raise Refuse("ADV-STALE", gid)
    top = max(r[0] for r in same)
    newest = sorted(r for r in same if r[0] == top)   # order by ts only: the id never breaks a tie
    if any(r[2] != env["ADV_PASS_WORD"] for r in newest):
        raise Refuse("ADV-NOT-PASS", gid)   # a same-instant PASS + FAIL fails closed
    _ts, aid, _word, acommit, what, ats = newest[0]
    log = re.search(env["ADV_LOG_RE"], what).group(1)
    if not (os.path.isfile(log) and os.path.getsize(log) > 0):
        raise Refuse("ADV-NOLOG", gid)
    return "OK %s %s %s %s" % (gid, aid, ats, acommit)


def main(argv):
    if len(argv) == 4 and argv[1] == "--dump-re":
        try:
            print(sub(os.environ["ADV_RE_FMT"], argv[2], argv[3]))
        except Exception:
            return 1
        return 0
    if len(argv) not in (5, 6):
        print("REFUSE ADV-UNCHECKED -")
        return 0
    try:
        out = run(argv[1], argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else "", os.environ)
    except Refuse as r:
        out = "REFUSE %s %s%s" % (r.token, r.g, " " + r.reason if r.reason else "")
    except Exception:
        out = "REFUSE ADV-UNCHECKED -"
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
