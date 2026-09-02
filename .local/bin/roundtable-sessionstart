#!/usr/bin/env bash
# roundtable-sessionstart.sh — SessionStart hook: show yesterday's crowned bon mot.
#
# Reads only local state files (vicious-circle ledger + conning-tower columns).
# Makes no network or API calls. Safe to run offline.
#
# Outputs exactly one line:
#   - "roundtable · <date> bon mot: \"<line>\" — <author>; column: <headline>"
#   - "roundtable · no session run for <date> — run: roundtable session"

set -euo pipefail

# Determine the roundtable binary — prefer the installed one, fall back to
# the cargo-built dev binary if running from the repo.
if command -v roundtable >/dev/null 2>&1; then
    RT_BIN="roundtable"
elif [ -f "${HOME}/.cargo/bin/roundtable" ]; then
    RT_BIN="${HOME}/.cargo/bin/roundtable"
else
    # No binary found — emit fallback and exit cleanly
    echo "roundtable · not installed — run: cargo install --path ~/wintermute/roundtable"
    exit 0
fi

# Run `roundtable digest` (defaults to yesterday, text format).
# Never let this error propagate — hook must always exit 0.
output="$("${RT_BIN}" digest 2>/dev/null)" || output=""

if [ -z "${output}" ]; then
    yesterday="$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "yesterday")"
    echo "roundtable · no session run for ${yesterday} — run: roundtable session"
else
    echo "${output}"
fi

exit 0
