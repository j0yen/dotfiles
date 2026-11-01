#!/usr/bin/env python3
"""caps-lint.py: the fleet caps registry check (P28 five-whys, A314).

Reads ~/dotfiles/.config/fleet/caps.tsv (or the path given). One row per cap.
Columns (header line starts with "# id"): id name value host enforced_at class
source verdict owner note, plus the optional v2 columns premise expires applied_by.

VIOLATION (exit 1):
  - a live row (verdict KEEP, CHECK or CHANGE) of a voided class (rationing,
    leased-box) whose value is not a no-cap sentinel; Joe 11-01 1:5x AM #195
    "stop using rationing limits", "no budget limit"; R013 permanent boxes only
  - a live row whose `expires` is in the past
  - an unknown class or verdict, or a live row with owner "-"
GAP (printed; exit 1 only with --strict):
  - a live row whose source is none / none found / - / empty
  - a live row of a premise class (rationing, leased-box, money, expiry, cadence)
    with neither premise nor expires, when the v2 columns exist

Usage: caps-lint.py [caps.tsv] [--strict] [--json]
"""
import json, re, sys, datetime

CLASSES = {"memory", "disk", "hang-guard", "cadence", "safety", "alarm", "display",
           "expiry", "compaction", "routing", "leased-box", "rationing", "money", "target"}
VERDICTS = {"KEEP", "DROP", "DEAD", "VOID", "CHECK", "CHANGE"}
LIVE = {"KEEP", "CHECK", "CHANGE"}
VOIDED_CLASSES = {"rationing", "leased-box"}
PREMISE_CLASSES = {"rationing", "leased-box", "money", "expiry", "cadence"}
NO_CAP = re.compile(r"^\s*(0\s*\(none\)|none\b|unlimited\b|void\b|lifted\b|-\s*$)", re.I)
NO_SOURCE = re.compile(r"^\s*(none( found)?|-)?\s*$", re.I)


def parse(path):
    cols, rows = None, []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            if line.startswith("# id\t"):
                cols = line[2:].split("\t")
                continue
            if line.startswith("#"):
                continue
            if cols is None:
                raise SystemExit(f"caps-lint: no '# id' header before data at line {n}")
            f_ = line.split("\t")
            if len(f_) < len(cols):
                f_ += [""] * (len(cols) - len(f_))
            row = dict(zip(cols, f_))
            row["_line"] = n
            rows.append(row)
    if cols is None:
        raise SystemExit("caps-lint: header line '# id\\t...' missing")
    return cols, rows


def lint(cols, rows, today=None):
    today = today or datetime.date.today()
    v2 = "premise" in cols and "expires" in cols
    viol, gaps = [], []
    for r in rows:
        rid, cls, vd = r.get("id", "?"), r.get("class", ""), r.get("verdict", "")
        where = f"{rid} line {r['_line']}"
        if cls not in CLASSES:
            viol.append(f"{where}: unknown class '{cls}'")
        if vd not in VERDICTS:
            viol.append(f"{where}: unknown verdict '{vd}'")
            continue
        if vd not in LIVE:
            continue
        if cls in VOIDED_CLASSES and not NO_CAP.match(r.get("value", "")):
            viol.append(f"{where}: live cap of voided class {cls} (value '{r.get('value','')[:40]}'; #195 / R013)")
        if r.get("owner", "").strip() in ("", "-"):
            viol.append(f"{where}: live row with no owner")
        if v2 and r.get("expires", "").strip() not in ("", "-"):
            try:
                exp = datetime.date.fromisoformat(r["expires"].strip()[:10])
                if exp < today:
                    viol.append(f"{where}: expired {r['expires'].strip()} and still live")
            except ValueError:
                viol.append(f"{where}: expires '{r['expires']}' is not ISO")
        if NO_SOURCE.match(r.get("source", "")):
            gaps.append(f"{where}: live row with no source (reason)")
        if v2 and cls in PREMISE_CLASSES and not (r.get("premise", "").strip() or r.get("expires", "").strip()):
            gaps.append(f"{where}: {cls} row with neither premise nor expires")
    return viol, gaps, v2


def main(argv):
    strict = "--strict" in argv
    as_json = "--json" in argv
    args = [a for a in argv if not a.startswith("--")]
    path = args[0] if args else "/home/jsy/dotfiles/.config/fleet/caps.tsv"
    cols, rows = parse(path)
    viol, gaps, v2 = lint(cols, rows)
    live = sum(1 for r in rows if r.get("verdict") in LIVE)
    out = {"rows": len(rows), "live": live, "v2_columns": v2,
           "violations": viol, "gaps": gaps}
    if as_json:
        print(json.dumps(out, indent=1))
    else:
        print(f"caps-lint: {len(rows)} rows, {live} live, v2 columns={'yes' if v2 else 'no'}, "
              f"{len(viol)} violation(s), {len(gaps)} gap(s)")
        for v in viol:
            print(f"VIOLATION {v}")
        for g in gaps:
            print(f"GAP {g}")
    return 1 if viol or (strict and gaps) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
