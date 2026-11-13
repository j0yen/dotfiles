#!/usr/bin/env bash
# rb-hand-unit-gate.sh - PreToolUse hook (Bash): the rb seat starts its suite/verifier/ad hoc units through rb-suite-unit.sh (A1304).
# 11-12: rb's hand `systemd-run --user --unit rb-sd-a1573-suite …` inherited the user slice's TasksMax 33183 (ctl lifted it runtime-only,
# d-20261112-083731-ctl-b3c0); rb-gate398*, rb-sd-a1303*, rb-sd-a1608 and rb-disk-survey* were started the same way. rb-suite-unit.sh
# carries TasksMax/MemoryMax=infinity + IOWeight=50 and an exclusive OUTFILE; this hook makes it the only path (Hermes 8:50 AM: an unused
# helper is not prevention).
# Rule: under WM_SEAT=rb, deny when the command text, or an rb-seat script it runs (~/.cache/rb-seat/*.sh, the seat's r-script
# pattern), has an uncommented line with `systemd-run` and `--unit rb-<name>` (or --unit=rb-…), unless that line also names
# rb-suite-unit.sh. rb-coder-* units are exempt: coders launch through rb-run-coder.sh / rb-coder-launch.sh with their own argv.
# Other seats and plain sessions exit 0 at once. Fails OPEN on bad JSON, a missing python3 or any exception.
# --selftest runs the cases below.
set -uo pipefail

read -r -d '' PY <<'PYEOF' || true
import json, os, re, sys
DENY = ("rb-hand-unit-gate: start rb units with rb-suite-unit.sh (TasksMax/MemoryMax=infinity, IOWeight=50, exclusive OUTFILE):\n"
        "  ssh redbaron 'rb-suite-unit.sh [--setenv K=V]... rb-<name> <workdir> <outfile> -- <cmd> [args]'\n"
        "a hand `systemd-run --unit rb-*` is refused (A1304); rb-coder-* units go through rb-run-coder.sh")
HIT = re.compile(r"""\bsystemd-run\b.*--unit(?:\s+|=)['"]?rb-(?!coder-)[a-z0-9]""")
SCRIPT = re.compile(r"""(?:/home/jsy|~|\$HOME)/\.cache/rb-seat/[A-Za-z0-9._/-]+\.sh""")
def bad(text):
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if HIT.search(s) and "rb-suite-unit.sh" not in s:
            return True
    return False
try:
    d = json.load(sys.stdin)
    if d.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (d.get("tool_input") or {}).get("command") or ""
    texts = [cmd]
    home = os.environ.get("HOME", "/home/jsy")
    for m in SCRIPT.findall(cmd):
        p = m.replace("$HOME", home, 1) if m.startswith("$HOME") else os.path.expanduser(m)
        try:
            with open(p, errors="replace") as f:
                texts.append(f.read(262144))
        except OSError:
            pass
    if any(bad(t) for t in texts):
        print(DENY, file=sys.stderr)
        sys.exit(2)
except SystemExit:
    raise
except Exception:
    sys.exit(0)
PYEOF

selftest() {
  local fail=0 T rc
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
  run() { jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | WM_SEAT=$1 HOME=$T "$0" 2>/dev/null; }
  run rb "ssh -n redbaron 'systemd-run --user --unit rb-sd-x -p IOWeight=50 --collect bash /tmp/x.sh'"; [ $? = 2 ]; chk "rb: hand systemd-run --unit rb-sd-x denied" $?
  run rb "ssh redbaron systemd-run --user --unit=rb-gate1 bash g.sh"; [ $? = 2 ]; chk "rb: --unit=rb-… denied" $?
  run rb "ssh redbaron 'rb-suite-unit.sh rb-sd-x /wd /o.txt -- python3 -m unittest'"; [ $? = 0 ]; chk "rb: rb-suite-unit.sh allowed" $?
  run rb "ssh redbaron 'systemd-run --user --unit rb-coder-a1 --collect -p IOWeight=50 ~/.local/bin/rb-run-coder.sh a1 p'"; [ $? = 0 ]; chk "rb: rb-coder-* exempt" $?
  run r7 "ssh redbaron 'systemd-run --user --unit rb-sd-x bash x.sh'"; [ $? = 0 ]; chk "r7 seat: not gated" $?
  run "" "systemd-run --user --unit rb-sd-x bash x.sh"; [ $? = 0 ]; chk "no seat: not gated" $?
  mkdir -p "$T/.cache/rb-seat"
  printf 'exec > /x 2>&1\nssh -n redbaron "systemd-run --user --unit rb-sd-y --collect bash y.sh"\n' > "$T/.cache/rb-seat/r1.sh"
  run rb "timeout 60 bash ~/.cache/rb-seat/r1.sh; echo rc=\$?"; [ $? = 2 ]; chk "rb: r-script with a hand rb unit denied" $?
  printf '# systemd-run --user --unit rb-sd-z was the old way\nssh redbaron "rb-suite-unit.sh rb-sd-z /wd /o -- true"\n' > "$T/.cache/rb-seat/r2.sh"
  run rb "timeout 60 bash ~/.cache/rb-seat/r2.sh"; [ $? = 0 ]; chk "rb: r-script via rb-suite-unit.sh (comment mentions systemd-run) allowed" $?
  run rb "wm-decide record --what 'a hand systemd-run of rb-sd-a1573-suite inherited TasksMax'"; [ $? = 0 ]; chk "rb: prose naming systemd-run without --unit allowed" $?
  printf 'not json' | WM_SEAT=rb "$0" 2>/dev/null; [ $? = 0 ]; chk "bad JSON fails open" $?
  jq -nc '{tool_name:"Edit",tool_input:{file_path:"x"}}' | WM_SEAT=rb "$0" 2>/dev/null; [ $? = 0 ]; chk "non-Bash tool ignored" $?
  return $fail
}

[ "${1:-}" = --selftest ] && { selftest; exit $?; }
[ "${WM_SEAT:-}" = rb ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
python3 -c "$PY"
