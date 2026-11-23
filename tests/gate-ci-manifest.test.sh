#!/usr/bin/env bash
# wm-build parses wm-build-ci.toml leniently: a check whose name is not ^[a-z0-9-]+$ or that has no cmd is DROPPED without a message, and a
# manifest with no surviving check falls back to `skipped no-repo-ci` (the gate then runs nothing of ours). This pins the shape so a typo
# cannot silently remove a check: every [[check]] is valid by wm-build's own rules, the required names are present, and every test a check
# names exists as tests/<name>.test.sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$HERE" <<'PY'
import re, sys, tomllib, pathlib
root = pathlib.Path(sys.argv[1]); fails = []
m = tomllib.loads((root / "wm-build-ci.toml").read_text())
checks = m.get("check", [])
names = [c.get("name") for c in checks]
for c in checks:
    n = c.get("name")
    if not isinstance(n, str) or not re.fullmatch(r"[a-z0-9-]+", n): fails.append(f"check name {n!r} would be dropped by wm-build")
    if not isinstance(c.get("cmd"), str) or not c["cmd"].strip(): fails.append(f"check {n!r} has no cmd (dropped by wm-build)")
    if c.get("where", "box") not in ("box", "host"): fails.append(f"check {n!r} where={c.get('where')!r}")
    if not isinstance(c.get("wall_minutes", 20), (int, float)): fails.append(f"check {n!r} wall_minutes not a number")
    for w in c["cmd"].split():
        if w.startswith("tests/gate/"): 
            if not (root / w).is_file(): fails.append(f"check {n!r} runs missing {w}")
    if "run-relevant.sh" in c["cmd"]:
        for t in c["cmd"].split("run-relevant.sh", 1)[1].split():
            name = t.split(":")[0]
            if not (root / "tests" / f"{name}.test.sh").is_file(): fails.append(f"check {n!r} names missing tests/{name}.test.sh")
if len(names) != len(set(names)): fails.append("duplicate check names")
for need in ("typed-review-consumer", "legacy-director-consumer"):
    if need not in names: fails.append(f"required check {need} absent")
if len(checks) > 16: fails.append("more than 16 checks (wm-build keeps the first 16)")
for f in fails: print("FAIL", f)
print(f"COUNTS: checks={len(checks)} fail={len(fails)}")
sys.exit(1 if fails else 0)
PY
