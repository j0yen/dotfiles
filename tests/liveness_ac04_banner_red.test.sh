#!/usr/bin/env bash
# tests/liveness_ac04_banner_red.test.sh — PRD-grand-loop-liveness-contract
# AC4: given a stale state, grand-loop-banner.sh (the script wired into
# SessionStart via .claude/scripts/grand-loop-banner-start.sh, PRD
# Requirement 3, "the fleet's shared hooks path") prints one line starting
# `grand-loop:` that contains `RED` and the age.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANNER="$(cd "$here/.." && pwd)/.local/bin/grand-loop-banner.sh"

fail=0
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/prds"
loop_dir="$repo/grand-loop"
mkdir -p "$loop_dir/state"

stamp_31h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=31)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_31h_ago" > "$loop_dir/state/last-success.json"
printf '%s family=instrument reason="preflight: probe command failed" reached_measure=0\n' "$stamp_31h_ago" > "$loop_dir/ledger.md"

export GRAND_LOOP_PRD_DIR="$repo"
export GRAND_LOOP_ENV="$work/nonexistent-env"
export GRAND_LOOP_MAX_AGE=26h
export PATH="$work/bin:$PATH"
mkdir -p "$work/bin"  # no alert-deliver.sh on PATH: delivery is best-effort/silent

out="$(bash "$BANNER")"

line="$(printf '%s\n' "$out" | grep '^grand-loop:' || true)"
[ -n "$line" ]; assert_contains "${line:-<none>}" "grand-loop:" "banner output has a line starting with grand-loop:"
assert_contains "$line" "RED" "the grand-loop: line reports RED for a stale state"
assert_contains "$line" "31 h" "the grand-loop: line carries the age (31 h)"
assert_contains "$line" "family=instrument" "the grand-loop: line carries the last row's family"

exit $fail
