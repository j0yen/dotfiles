#!/usr/bin/env python3
"""ask-row.py: the only appender of open-asks.tsv rows (A10).

  ask-row.py --owner O --due ISO --key K --done-check CMD --what TEXT [--asked ISO]

Row = 7 tab columns: id asked owner due key check what. The id is allocated under an flock on <tsv>.lock
(max Annn over the whole file, open and closed, plus 1), the row is inserted ABOVE the "# CLOSED" line,
the file always ends in a newline. A done-check whose first word is not a runnable command (prose) is
refused (exit 65); a field holding a tab or newline is refused (exit 64). Prints the new id.
OPEN_ASKS overrides the file (default ~/.cache/aide/open-asks.tsv).
"""
import argparse, fcntl, os, re, shutil, sys
from datetime import datetime

def runnable(check):
    first = check.split(None, 1)[0] if check.strip() else ""
    if not first:
        return False
    if first in ("test", "[", "[[", "!", "(", "{"):
        return True
    if "/" in first or first.startswith("~"):
        return os.access(os.path.expanduser(first), os.X_OK)
    return shutil.which(first) is not None

def main(argv=None):
    ap = argparse.ArgumentParser()
    for f in ("owner", "due", "key", "done_check", "what"):
        ap.add_argument("--" + f.replace("_", "-"), dest=f, required=True)
    ap.add_argument("--asked", default=datetime.now().strftime("%Y-%m-%dT%H:%M"))
    a = ap.parse_args(argv)
    path = os.environ.get("OPEN_ASKS") or os.path.expanduser("~/.cache/aide/open-asks.tsv")
    cols = [a.asked, a.owner, a.due, a.key, a.done_check, a.what]
    if any(("\t" in c or "\n" in c or not c.strip()) for c in cols):
        print("ask-row: every field must be non-empty with no tab or newline", file=sys.stderr); return 64
    try:
        datetime.fromisoformat(a.due)
    except ValueError:
        print("ask-row: --due must be ISO (2026-11-01T09:00)", file=sys.stderr); return 64
    if not runnable(a.done_check):
        print("ask-row: --done-check must start with a runnable command (prose refused): " + a.done_check[:60], file=sys.stderr); return 65
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        lines = open(path).read().split("\n") if os.path.exists(path) else []
        if lines and lines[-1] == "":
            lines.pop()
        ids = [int(m.group(1)) for l in lines for m in [re.match(r"A(\d+)\t", l)] if m]
        nid = "A%d" % (max(ids, default=0) + 1)
        row = "\t".join([nid] + cols)
        at = lines.index("# CLOSED") if "# CLOSED" in lines else len(lines)
        lines.insert(at, row)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    print(nid)
    return 0

if __name__ == "__main__":
    sys.exit(main())
