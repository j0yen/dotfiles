#!/usr/bin/env bash
# wm-build parses wm-build-ci.toml leniently: a check whose name is not ^[a-z0-9-]+$ or that has no cmd is DROPPED without a message, and a
# manifest with no surviving check falls back to `skipped no-repo-ci`. This pins the EXACT rows (name, cmd, where, minimum counts) so a typo,
# a dropped test name, a lowered `:120` minimum or a merged row (review 74270b28 F1/F5) fails here, and every test a row names must exist.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$HERE" <<'PY'
import re, sys, tomllib, pathlib
root = pathlib.Path(sys.argv[1]); fails = []
checks = tomllib.loads((root / "wm-build-ci.toml").read_text()).get("check", [])
R = "bash tests/gate/run-relevant.sh "
LEGACY = ["director-event-consumer", "director-event-consumer-own-claim-rerun", "director-consumer-child-env",
          "director-event-consumer-tasksmax", "ctl-intake-consumer", "director-hermes-stop-gates"]
EXPECT = {"typed-review-consumer": R + "director-event-consumer-typed-review:120"}
EXPECT.update({"legacy-" + t: R + t for t in LEGACY})
EXPECT["gate-selftest"] = "bash tests/gate-run-relevant.test.sh && bash tests/gate-ci-manifest.test.sh"
got = {}
for c in checks:
    n = c.get("name")
    if not isinstance(n, str) or not re.fullmatch(r"[a-z0-9-]+", n): fails.append(f"check name {n!r} would be dropped by wm-build")
    if not isinstance(c.get("cmd"), str) or not c["cmd"].strip(): fails.append(f"check {n!r} has no cmd (dropped by wm-build)"); continue
    if c.get("where", "box") != "host": fails.append(f"check {n!r} where={c.get('where')!r} (must be host)")
    if not isinstance(c.get("wall_minutes", 20), (int, float)): fails.append(f"check {n!r} wall_minutes not a number")
    if n in got: fails.append(f"duplicate check {n}")
    got[n] = c["cmd"]
    if "run-relevant.sh" in c["cmd"]:
        if c.get("fail_marker") != "GATE-RELEVANT-PROBLEM:": fails.append(f"check {n!r} lacks the fail_marker")
        names = c["cmd"].split("run-relevant.sh", 1)[1].split()
        if len(names) != 1: fails.append(f"check {n!r} names {len(names)} tests (one row per test)")
        for t in names:
            if not (root / "tests" / f"{t.split(':')[0]}.test.sh").is_file(): fails.append(f"check {n!r} names missing tests/{t.split(':')[0]}.test.sh")
for n, cmd in EXPECT.items():
    if n not in got: fails.append(f"required row {n} absent")
    elif got[n] != cmd: fails.append(f"row {n} cmd is {got[n]!r}, pinned {cmd!r}")
for n in got:
    if n not in EXPECT: fails.append(f"unpinned extra row {n} (adding a row is a reviewed change: update this pin)")
if len(checks) > 16: fails.append("more than 16 checks (wm-build keeps the first 16)")
for t in ("tests/gate/run-relevant.sh", "tests/gate-run-relevant.test.sh"):
    if not (root / t).is_file(): fails.append(f"missing {t}")
for f in fails: print("FAIL", f)
print(f"COUNTS: checks={len(checks)} fail={len(fails)}")
sys.exit(1 if fails else 0)
PY
