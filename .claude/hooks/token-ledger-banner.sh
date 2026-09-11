#!/usr/bin/env bash
# token-ledger-banner.sh — SessionStart hook: surface yesterday's weighted
# token usage (from the nightly token-ledger timer) as a one-line banner.
# Silent if the summary doesn't exist yet (e.g. before the first nightly run).

set -uo pipefail

SUMMARY="${HOME}/.cache/token-ledger/today-summary.txt"
[ -r "$SUMMARY" ] || exit 0

cat "$SUMMARY"
