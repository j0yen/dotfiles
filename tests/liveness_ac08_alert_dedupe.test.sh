#!/usr/bin/env bash
# tests/liveness_ac08_alert_dedupe.test.sh — PRD-grand-loop-liveness-contract
# AC8: a stale state read twice by grand-loop-banner.sh in one UTC day
# delivers exactly one alert (dedupe by date), through the build loop's
# alert-deliver.sh (Requirement 6).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
BANNER="$(cd "$here/.." && pwd)/.local/bin/grand-loop-banner.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/prds"
loop_dir="$repo/grand-loop"
mkdir -p "$loop_dir/state"

stamp_27h_ago="$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(hours=27)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts": "%s", "phase": "DIGEST", "version": "0.1.0"}\n' "$stamp_27h_ago" > "$loop_dir/state/last-success.json"

bin="$work/bin"
mkdir -p "$bin"
ln -s "$fixtures/fake-alert-deliver.sh" "$bin/alert-deliver.sh"
calls="$work/alert-deliver-calls"
: > "$calls"

export GRAND_LOOP_PRD_DIR="$repo"
export GRAND_LOOP_ENV="$work/nonexistent-env"
export GRAND_LOOP_MAX_AGE=26h
export FAKE_ALERT_DELIVER_CALLS="$calls"
export PATH="$bin:$PATH"

bash "$BANNER" >/dev/null
bash "$BANNER" >/dev/null

nlines="$(wc -l < "$calls" 2>/dev/null || echo 0)"
assert_eq "$nlines" "1" "two consecutive banner reads the same UTC day deliver exactly one alert"

marker="$loop_dir/state/last-alert-date.txt"
[ -f "$marker" ]; assert_eq "$?" "0" "the dedupe marker file was written"
assert_eq "$(cat "$marker")" "$(date -u +%F)" "the dedupe marker records today's UTC date"

exit $fail
