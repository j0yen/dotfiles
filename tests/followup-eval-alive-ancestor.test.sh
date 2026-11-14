#!/usr/bin/env bash
# followup-eval _alive(): a pgrep match on the evaluator's own ancestors is dropped only for shells and wrappers; an ancestor whose comm is
# claude or tmux IS the live worker (A1307 rev 13: inside the ctl session the canonical handle ctl:<sid> read dead because the session's claude
# and tmux pids were the evaluator's ancestors, while the same handle read live from any other session). The real tmux/pgrep path runs here:
# no FOLLOWUP_WORKER_ALIVE_CMD. A script's comm is its filename, so a wrapper named `claude` stands in for a session process whose argv names
# the token (--resume <sid>), and one named `hookshell` for a hook shell whose command line names it.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-eval-alive.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"
unset FOLLOWUP_WORKER_ALIVE_CMD
command -v pgrep >/dev/null; chk "0: pgrep present" $?
tok="tokalive$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"   # names no tmux session and no process but this test's chain
cat >"$base/probe.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fe", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("live" if m._alive(sys.argv[2]) else "dead")
PY
for name in claude hookshell; do printf '#!/bin/bash\npython3 -I "$1" "$2" "$3"\n' >"$base/$name"; chmod +x "$base/$name"; done   # no exec: the wrapper stays the parent
out="$("$base/claude" "$base/probe.py" "$EV" "$tok" 2>&1)"
[ "$out" = live ]; chk "1: a claude ancestor whose argv names the token reads LIVE (in-session probe; got: $out)" $?
out="$("$base/hookshell" "$base/probe.py" "$EV" "$tok" 2>&1)"
[ "$out" = dead ]; chk "2: a wrapper ancestor (comm hookshell) naming the token is dropped: reads DEAD (got: $out)" $?
out="$(bash -c "python3 -I '$base/probe.py' '$EV' '$tok'" 2>&1)"
[ "$out" = dead ]; chk "3: a bash -c ancestor naming the token is dropped: reads DEAD (the 5f0bd35 self-match fix holds; got: $out)" $?
out="$(python3 -I "$base/probe.py" "$EV" "" 2>&1)"
[ "$out" = dead ]; chk "4: an empty handle reads DEAD (got: $out)" $?
echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
