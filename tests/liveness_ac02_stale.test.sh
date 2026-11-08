#!/usr/bin/env bash
# tests/liveness_ac02_stale.test.sh — PRD-grand-loop-liveness-contract AC2:
# a last-success.json stamped 27h ago with GRAND_LOOP_MAX_AGE=26h makes
# bl_liveness print `stale` and exit 2.
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

stamp_27h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=27)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_27h_ago" > "$success"
# No state.json at all: bl_liveness must not require one to report staleness.

export GRAND_LOOP_MAX_AGE=26h
out="$(bl_liveness "$state" "$success")"
rc=$?
assert_eq "$out" "stale" "bl_liveness prints stale for a 27h-old success row against a 26h max age"
assert_eq "$rc" "2" "bl_liveness exits 2 for stale"

# A success row inside the window is ok, not stale.
stamp_1h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_1h_ago" > "$success"
out2="$(bl_liveness "$state" "$success")"
rc2=$?
assert_eq "$out2" "ok" "bl_liveness prints ok for a 1h-old success row against a 26h max age"
assert_eq "$rc2" "0" "bl_liveness exits 0 for ok"

exit $fail
