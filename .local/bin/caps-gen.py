#!/usr/bin/env python3
"""caps-gen.py: write the enforced files from the caps registry (P28 architecture stage 2, A323).

The manifest .config/fleet/caps-gen.tsv maps a registry cap to one generated spot:
  cap_id  host  kind  target  section  key  fmt  pick
  host    machine name the row applies to, empty = every host
  kind    dropin  : whole file generated (header + [section] + key=fmt lines; rows with one target are one file, in order)
          tomlkey : replace the `key = fmt` line inside [section] ('' = top level) of an existing file
          tsvcell : in a tab file, set column `key` (named by its '# ...' header line) of the row whose first cell is `section`
  target  path under the home directory (no leading ~/)
  fmt     right-hand side; {n} = the value picked from the registry `value` column
  pick    regex, group 1 = n (empty = first number in the value)
Only rows whose registry verdict is KEEP/CHECK/CHANGE are generated. A missing registry row, an unmatched pick,
or a missing key/section/row in an existing file is an ERROR, never a silent skip.

Usage: caps-gen.py (--check | --write) [--registry caps.tsv] [--manifest caps-gen.tsv] [--home DIR] [--host NAME]
--check  prints DRIFT lines for files that differ from the generated text, then `caps.gen drift=<n> errors=<m>`; exit 1 if any.
--write  rewrites those files (tmp + rename), prints WROTE lines, same summary; exit 1 only on errors.
"""
import importlib.util, os, re, socket, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("caps_lint", os.path.join(HERE, "caps-lint.py"))
caps_lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(caps_lint)
ALIAS = {"rb": "redbaron", "r7": "ryzen7"}
COLS = ["cap_id", "host", "kind", "target", "section", "key", "fmt", "pick"]
HEADER = "# GENERATED from .config/fleet/caps.tsv by caps-gen.py (cap {ids}); edit the registry, not this file."


def load_manifest(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            c = line.split("\t")
            c += [""] * (len(COLS) - len(c))
            row = dict(zip(COLS, c))
            row["_line"] = n
            out.append(row)
    return out


def pick_value(reg, m):
    val = reg.get("value", "")
    rx = m["pick"] or r"(\d+(?:\.\d+)?)"
    g = re.search(rx, val)
    if not g or not g.groups():
        raise ValueError(f"{m['cap_id']}: pick /{rx}/ finds no value in '{val}'")
    return g.group(1)


def render_dropin(rows):
    ids = ",".join(dict.fromkeys(m["cap_id"] for m, _ in rows))
    lines, sec = [HEADER.format(ids=ids)], None
    for m, n in rows:
        if m["section"] != sec:
            sec = m["section"]
            lines.append(f"[{sec}]")
        lines.append(f"{m['key']}={m['fmt'].replace('{n}', n)}")
    return "\n".join(lines) + "\n"


def edit_tomlkey(text, m, n):
    lines, sec, hit = text.split("\n"), "", None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("[") and s.endswith("]"):
            sec = s.strip("[]").strip()
        elif sec == m["section"] and re.match(r"^" + re.escape(m["key"]) + r"\s*=", s):
            hit = i
            break
    if hit is None:
        raise ValueError(f"{m['cap_id']}: key '{m['key']}' not found in [{m['section']}] of {m['target']}")
    tail = re.search(r"\s+#.*$", lines[hit])  # keep a trailing comment
    lines[hit] = f"{m['key']} = {m['fmt'].replace('{n}', n)}" + (tail.group(0) if tail else "")
    return "\n".join(lines)


def edit_tsvcell(text, m, n):
    lines, cols, hit = text.split("\n"), None, None
    for i, ln in enumerate(lines):
        if cols is None and ln.startswith("# ") and m["key"] in ln[2:].split("\t"):
            cols = ln[2:].split("\t")
        elif cols is not None and ln and not ln.startswith("#") and ln.split("\t")[0] == m["section"]:
            hit = i
            break
    if cols is None or hit is None:
        raise ValueError(f"{m['cap_id']}: column '{m['key']}' or row '{m['section']}' not found in {m['target']}")
    cells = lines[hit].split("\t")
    j = cols.index(m["key"])
    cells += ["-"] * (j + 1 - len(cells))
    cells[j] = m["fmt"].replace("{n}", n)
    lines[hit] = "\t".join(cells)
    return "\n".join(lines)


def plan(rows, manifest, host, home):
    """-> ([(path, new_text, old_text_or_None)], [error])"""
    byid = {r["id"]: r for r in rows}
    errs, dropins, edits = [], {}, {}
    for m in manifest:
        if m["host"] and ALIAS.get(m["host"], m["host"]) != host:
            continue
        reg = byid.get(m["cap_id"])
        if reg is None:
            errs.append(f"ERROR {m['cap_id']} not in the registry (manifest line {m['_line']})")
            continue
        if reg.get("verdict") not in caps_lint.LIVE:
            continue
        try:
            n = pick_value(reg, m)
        except ValueError as e:
            errs.append(f"ERROR {e}")
            continue
        if m["kind"] == "dropin":
            dropins.setdefault(m["target"], []).append((m, n))
        elif m["kind"] in ("tomlkey", "tsvcell"):
            edits.setdefault(m["target"], []).append((m, n))
        else:
            errs.append(f"ERROR {m['cap_id']} unknown kind '{m['kind']}'")
    out = []
    for target, rs in dropins.items():
        p = os.path.join(home, target)
        old = open(p, encoding="utf-8").read() if os.path.exists(p) else None
        out.append((p, render_dropin(rs), old))
    for target, rs in edits.items():
        p = os.path.join(home, target)
        if not os.path.exists(p):
            errs.append(f"ERROR {rs[0][0]['cap_id']} {target} does not exist on this host")
            continue
        old = text = open(p, encoding="utf-8").read()
        try:
            for m, n in rs:
                text = (edit_tomlkey if m["kind"] == "tomlkey" else edit_tsvcell)(text, m, n)
        except ValueError as e:
            errs.append(f"ERROR {e}")
            continue
        out.append((p, text, old))
    return out, errs


def write_atomic(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = f"{p}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, p)


def main(argv):
    opt = {"--registry": None, "--manifest": None, "--home": None, "--host": None}
    mode, i = None, 0
    while i < len(argv):
        if argv[i] in ("--check", "--write"):
            mode, i = argv[i], i + 1
        elif argv[i] in opt and i + 1 < len(argv):
            opt[argv[i]], i = argv[i + 1], i + 2
        else:
            mode = None
            break
    if mode is None:
        print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
        return 64
    base = os.path.dirname(os.path.dirname(HERE))
    reg = opt["--registry"] or os.path.join(base, ".config/fleet/caps.tsv")
    man = opt["--manifest"] or os.path.join(base, ".config/fleet/caps-gen.tsv")
    home = opt["--home"] or os.path.expanduser("~")
    host = ALIAS.get((opt["--host"] or socket.gethostname().split(".")[0]).lower(), (opt["--host"] or socket.gethostname().split(".")[0]).lower())
    _, rows = caps_lint.parse(reg)
    changes, errs = plan(rows, load_manifest(man), host, home)
    drift = 0
    for p, new, old in changes:
        if new == old:
            continue
        drift += 1
        if mode == "--write":
            write_atomic(p, new)
            print(f"WROTE {p}")
        else:
            print(f"DRIFT {p} differs from the registry-generated text" + ("" if old is not None else " (file absent)"))
    for e in errs:
        print(e)
    print(f"caps.gen drift={drift} errors={len(errs)}")
    return 1 if errs or (mode == "--check" and drift) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
