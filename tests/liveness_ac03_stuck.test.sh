#!/usr/bin/env bash
# tests/liveness_ac03_stuck.test.sh — PRD-grand-loop-liveness-contract AC3:
# state.json with PREFLIGHT: running stamped 40 min ago makes bl_liveness
# print `stuck` and exit 2, using the default GRAND_LOOP_PHASE_MAX_WALL
# (30m) — regardless of whether a fresh last-success.json also exists,
# since a hung tick is its own failure mode.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.local/lib/grand-loop-lib.sh
. "$here/../.local/lib/grand-loop-lib.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

state="$work/state.json"
success="$work/last-success.json"

stamp_40m_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(minutes=40)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
python3 - "$state" "$stamp_40m_ago" <<'PY'
import json, sys
path, stamp = sys.argv[1], sys.argv[2]
json.dump({"phase": "PREFLIGHT", "phases": {"PREFLIGHT": {"stamp": stamp, "status": "running"}}}, open(path, "w"))
PY

# A fresh success row still on file — stuck must win over a fresh success.
stamp_1h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_1h_ago" > "$success"

unset GRAND_LOOP_PHASE_MAX_WALL  # exercise the 30m default
out="$(bl_liveness "$state" "$success")"
rc=$?
assert_eq "$out" "stuck" "bl_liveness prints stuck for a PREFLIGHT running 40 min (default 30m wall)"
assert_eq "$rc" "2" "bl_liveness exits 2 for stuck"

# A PREFLIGHT running well inside the wall is not stuck.
stamp_5m_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
python3 - "$state" "$stamp_5m_ago" <<'PY'
import json, sys
path, stamp = sys.argv[1], sys.argv[2]
json.dump({"phase": "PREFLIGHT", "phases": {"PREFLIGHT": {"stamp": stamp, "status": "running"}}}, open(path, "w"))
PY
out2="$(bl_liveness "$state" "$success")"
rc2=$?
assert_eq "$out2" "ok" "bl_liveness does not report stuck for a PREFLIGHT running only 5 min"
assert_eq "$rc2" "0" "bl_liveness exits 0 when not stuck and success is fresh"

exit $fail
