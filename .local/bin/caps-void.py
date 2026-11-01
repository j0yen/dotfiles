#!/usr/bin/env python3
"""caps-void.py: void every live row of one class in the caps registry (P28 mechanism 4).

Usage: caps-void.sh --class <class> [--approvals N] [--dry-run] [--registry caps.tsv]

Lists every live row (KEEP/CHECK/CHANGE) of the class. Without --dry-run (requires --approvals N)
it sets the verdict to VOID and appends "VOID #N" to the note, in the given registry file only
(atomic tmp + rename; every other line is kept byte for byte). It then prints, per host, the
enforced_at entries a host operator must neutralise. Stage 1: it never edits a host file;
caps-drift.sh reports any entry still present. Regenerate caps-digest.md after a rewrite.
"""
import importlib.util, os, sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("caps_drift", os.path.join(HERE, "caps-drift.py"))
caps_drift = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(caps_drift)
caps_lint = caps_drift.caps_lint


def main(argv):
    cls = approvals = reg = None
    dry = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            dry = True
        elif a in ("--class", "--approvals", "--registry") and i + 1 < len(argv):
            i += 1
            if a == "--class": cls = argv[i]
            elif a == "--approvals": approvals = argv[i].lstrip("#")
            else: reg = argv[i]
        else:
            print(__doc__.split("Usage:")[1].split("Lists")[0].strip(), file=sys.stderr)
            return 64
        i += 1
    if cls not in caps_lint.CLASSES:
        print(f"caps-void: --class must be one of {sorted(caps_lint.CLASSES)}", file=sys.stderr)
        return 64
    if not dry and not (approvals and approvals.isdigit()):
        print("caps-void: a real run needs --approvals <number>", file=sys.stderr)
        return 64
    reg = reg or os.path.join(os.path.dirname(os.path.dirname(HERE)), ".config/fleet/caps.tsv")
    cols, rows = caps_lint.parse(reg)
    live = [r for r in rows if r.get("class") == cls and r.get("verdict") in caps_lint.LIVE]
    print(f"caps-void: class {cls}: {len(live)} live row(s){' (dry run, nothing written)' if dry else ''}")
    for r in live:
        print(f"ROW {r['id']} {r['name']} value='{r['value']}' verdict={r['verdict']} hosts={r['host']}")
    ids = {r["id"] for r in live}
    print("NEUTRALISE (host operator; stage 1 edits no host file):")
    for r in live:
        hosts = caps_drift.row_hosts(r["host"])
        ents = caps_drift.parse_entries(r, hosts)
        if not ents:
            print(f"  {r['id']}: enforced_at '{r['enforced_at']}' is not a host file; retire it where it is stated")
        for h in (hosts or ["-"]):
            for path, hostlines, tag, _ in ents:
                if tag and tag != h:
                    continue
                lines = (hostlines or {}).get(h, (hostlines or {}).get("*"))
                print(f"  {r['id']} {h} {path}{':' + ','.join(map(str, lines)) if lines else ''}")
    if dry or not live:
        return 0
    out = []
    with open(reg, encoding="utf-8") as f:
        text = f.read()
    ci = {c: n for n, c in enumerate(cols)}
    for line in text.split("\n"):
        f_ = line.split("\t")
        if not line.startswith("#") and f_[0] in ids and len(f_) > ci["verdict"]:
            f_ += [""] * (len(cols) - len(f_))
            f_[ci["verdict"]] = "VOID"
            note = f_[ci["note"]].strip()
            f_[ci["note"]] = (note + " · " if note else "") + f"VOID #{approvals}"
            line = "\t".join(f_)
        out.append(line)
    tmp = f"{reg}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    os.replace(tmp, reg)
    print(f"caps-void: {len(live)} row(s) set to VOID #{approvals} in {reg}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
