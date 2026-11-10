#!/usr/bin/env bash
# tests/director-event-consumer-tasksmax.test.sh — A1483: launch_argv() passes "-p", "TasksMax=infinity"
# to systemd-run (the worker unit otherwise inherits the user slice's TasksMax). Pure argv build, no unit started.
set -uo pipefail
C="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/director-event-consumer.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
DIRECTOR_STATE="$T/state" python3 -I - "$C" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("dec", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
argv = m.launch_argv("director-test-unit", "/nonexistent/query", tail=["/bin/true"], child_exec=False)
pairs = [(argv[i], argv[i + 1]) for i in range(len(argv) - 1)]
assert ("-p", "TasksMax=infinity") in pairs, argv
assert argv[0] == "systemd-run"
print("ok - launch_argv carries -p TasksMax=infinity")
PY
