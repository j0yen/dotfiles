#!/usr/bin/env bash
# r7-run-coder.sh: reaper keeps busy/foreign dirs, the EXIT trap reaps on rc!=0 and on SIGTERM, commit-msg strips and pre-push refuses
# attribution trailers. Everything runs on mktemp roots via the script's own --selftest.  Run: bash tests/r7-run-coder.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$("$here/.local/bin/r7-run-coder.sh" --selftest 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -3
[ $rc = 0 ] && grep -q '^SELFTEST OK$' <<<"$out" && { echo "PASS r7-run-coder"; exit 0; }; echo "FAIL r7-run-coder"; exit 1
