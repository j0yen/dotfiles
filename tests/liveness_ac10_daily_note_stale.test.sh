#!/usr/bin/env bash
# tests/liveness_ac10_daily_note_stale.test.sh — PRD-grand-loop-liveness-contract
# AC10: given a RED state, the daily note's Open needs lists the stale
# instrument with its timestamp.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../.local/lib/grand-loop-lib.sh
. "$here/../.local/lib/grand-loop-lib.sh"

fail=0
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "NOT OK - $3: '$1' unexpectedly contains '$2'"; fail=1 ;; *) echo "ok - $3" ;; esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
loop_dir="$work/grand-loop"
mkdir -p "$loop_dir/state"
ledger="$loop_dir/ledger.md"
: > "$ledger"
today="$(date -u +%F)"

# --- scenario A: RED (stale) -> the daily note names it, with a timestamp ---
stamp_27h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=27)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_27h_ago" > "$loop_dir/state/last-success.json"
touch "$loop_dir/PUBLISH-OK"

target="$(update_daily_section "$work" "$loop_dir" "$ledger" "$today")"
body="$(cat "$target")"
assert_contains "$body" "instrument stale since $stamp_27h_ago" "RED (stale): Open needs names the stale instrument with its timestamp"

# --- scenario B: OK (fresh success) -> no such need ---
stamp_1h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_1h_ago" > "$loop_dir/state/last-success.json"

target2="$(update_daily_section "$work" "$loop_dir" "$ledger" "$today")"
body2="$(cat "$target2")"
assert_not_contains "$body2" "instrument stale since" "OK (fresh success): Open needs carries no stale-instrument line"

exit $fail
