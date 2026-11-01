#!/usr/bin/env bash
# token-ledger-banner.sh — SessionStart hook: surface yesterday's weighted
# token usage (from the nightly token-ledger timer) as a banner. The summary
# file is one line, or two when the build_share ALARM line is present; cat
# prints it whole.
# Silent if the summary doesn't exist yet (e.g. before the first nightly run).

set -uo pipefail

SUMMARY="${HOME}/.cache/token-ledger/today-summary.txt"
[ -r "$SUMMARY" ] || exit 0

cat "$SUMMARY"
