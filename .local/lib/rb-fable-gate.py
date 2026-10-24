#!/usr/bin/env python3
"""rb-fable-gate.py - the Fable-verdict gate for rb-run-coder.sh (exit 78). Run as `python3 -I rb-fable-gate.py MODE ARG DB`.

  spec  SPEC DB   pass iff the NEWEST decisions row whose evidence holds `sha256:<hex of SPEC>` is kind=verdict, model contains `fable`,
                  final verdict in {AGREE, AGREE-WITH-EDITS, CONFIRM} (final = regrade JSON `verdict` when present, else the first word of `what`),
                  and the spec's stem (fvg.spec.md -> fvg) appears in that row's what/evidence. stdout `OK <id>` rc 0, else the reason rc 1.
  hatch PROMPT DB pass iff PROMPT carries `Hatch: d-<id>` naming a kind=decision row, `what` starting NO-SPEC-SPAWN, evidence holding
                  `sha256:<hex of PROMPT with the Hatch line(s) removed>`, id timestamp <= 24 h old. stdout the row id rc 0, else `hatch-<why>` rc 1.

The DB is opened read-only (`file:...?mode=ro`, never immutable=1); a locked DB retries 3x ~1 s apart then `db-locked`; a missing file or a schema
without the needed columns is `db-unreadable`. Reasons: sha-mismatch [<id>], no-fable-verdict-row <id>, verdict-<WORD> <id>, stem-mismatch <id>,
db-locked, db-unreadable. RB_FABLE_GATE_TIMEOUT (seconds, default 5) is the sqlite busy timeout; a shorter value only fails closed sooner.
"""
import hashlib, json, os, re, sqlite3, sys, time
from datetime import datetime

PASS_WORDS = {"AGREE", "AGREE-WITH-EDITS", "CONFIRM"}
COLS = {"id", "ts", "kind", "model", "what", "evidence", "regrade"}
ID_TS = re.compile(r"^d-(\d{8})-(\d{6})-")
HATCH = re.compile(rb"^Hatch: (d-\d{8}-\d{6}-[A-Za-z0-9-]+)[ \t\r]*$")


class Refuse(Exception):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def query(db_path, sql, args=()):
    """Read-only select with the lock retry; raises Refuse(db-locked|db-unreadable)."""
    timeout = float(os.environ.get("RB_FABLE_GATE_TIMEOUT", "5"))
    uri = "file:%s?mode=ro" % db_path.replace("%", "%25").replace("?", "%3f").replace("#", "%23")
    last = None
    for attempt in range(4):
        con = None
        try:
            con = sqlite3.connect(uri, uri=True, timeout=timeout)
            have = {r[1] for r in con.execute("PRAGMA table_info(decisions)")}
            if not COLS <= have:
                raise Refuse("db-unreadable")
            return con.execute(sql, args).fetchall()
        except sqlite3.OperationalError as e:
            if "locked" in str(e).lower():
                last = e
                if attempt < 3:
                    time.sleep(1)
                continue
            raise Refuse("db-unreadable")
        except sqlite3.DatabaseError:
            raise Refuse("db-unreadable")
        finally:
            if con is not None:
                con.close()
    raise Refuse("db-locked")


def id_key(row):
    m = ID_TS.match(row[0])
    return (m.group(1) + m.group(2) if m else "", row[1] or "", row[0])


def id_time(rid):
    m = ID_TS.match(rid)
    return time.mktime(datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").timetuple()) if m else None


def final_word(what, regrade):
    if regrade:
        try:
            rg = json.loads(regrade)
        except ValueError:
            return "REGRADE-UNREADABLE"
        if isinstance(rg, dict) and isinstance(rg.get("verdict"), str) and rg["verdict"].strip():
            return rg["verdict"].strip().upper()
    toks = (what or "").split(None, 1)
    return toks[0].strip("*_`:;,.()[]—–").upper() if toks else "NONE"


def gate_spec(spec, db):
    data = open(spec, "rb").read()
    hexd = sha(data)
    stem = os.path.basename(spec)
    stem = stem[: -len(".spec.md")] if stem.endswith(".spec.md") else stem
    cols = "id, ts, kind, model, what, evidence, regrade"
    rows = [r for r in query(db, "SELECT %s FROM decisions WHERE instr(evidence, ?) > 0" % cols, ("sha256:" + hexd,))]
    if not rows:
        word = re.compile(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(stem))
        named = sorted((r for r in query(db, "SELECT %s FROM decisions WHERE kind = 'verdict' AND instr(lower(model), 'fable') > 0 ORDER BY ts DESC LIMIT 300" % cols)
                        if word.search((r[4] or "") + " " + (r[5] or ""))), key=id_key)
        raise Refuse("sha-mismatch" + (" " + named[-1][0] if named else ""))
    gov = sorted(rows, key=id_key)[-1]
    rid, _ts, kind, model, what, evidence, regrade = gov
    if kind != "verdict" or "fable" not in (model or "").lower():
        raise Refuse("no-fable-verdict-row " + rid)
    word = final_word(what, regrade)
    if word not in PASS_WORDS:
        raise Refuse("verdict-%s %s" % (word, rid))
    if not re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(stem), (what or "") + " " + (evidence or "")):
        raise Refuse("stem-mismatch " + rid)
    return rid


def gate_hatch(prompt, db):
    lines = open(prompt, "rb").read().splitlines(keepends=True)
    ids = [m.group(1).decode() for m in (HATCH.match(l.rstrip(b"\n")) for l in lines) if m]
    if not ids:
        raise Refuse("")
    hexd = sha(b"".join(l for l in lines if not HATCH.match(l.rstrip(b"\n"))))
    rid = ids[-1]
    rows = query(db, "SELECT id, ts, kind, what, evidence FROM decisions WHERE id = ?", (rid,))
    if not rows:
        raise Refuse("hatch-no-row")
    _id, _ts, kind, what, evidence = rows[0]
    if kind != "decision" or not (what or "").startswith("NO-SPEC-SPAWN"):
        raise Refuse("hatch-not-no-spec-decision")
    if "sha256:" + hexd not in (evidence or ""):
        raise Refuse("hatch-prompt-sha-mismatch")
    t = id_time(rid)
    if t is None or time.time() - t > 24 * 3600:
        raise Refuse("hatch-expired")
    return rid


def main(argv):
    if len(argv) != 4 or argv[1] not in ("spec", "hatch"):
        print("usage: rb-fable-gate.py spec|hatch FILE DB", file=sys.stderr)
        return 64
    try:
        out = gate_hatch(argv[2], argv[3]) if argv[1] == "hatch" else "OK " + gate_spec(argv[2], argv[3])
        print(out)
        return 0
    except Refuse as e:
        print(str(e))
        return 1
    except OSError:
        print("db-unreadable" if argv[1] == "spec" else "")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
