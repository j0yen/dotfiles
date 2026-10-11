#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC4: with mcphost.dev unreachable
# (HANDOFF_MCPHOST_URL=http://127.0.0.1:9) the Versions section prints
# `mcphost prod: unreachable` and the run completes within 3 s.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
hgen_setup
export HANDOFF_MCPHOST_URL="http://127.0.0.1:9"
t0=$(date +%s%N)
"$HGEN" --out "$work/t.md"; assert_eq "$?" "0" "generator exits 0"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
assert_eq "$([ "$ms" -lt 3000 ] && echo yes)" "yes" "completes within 3 s (${ms} ms)"
v="$(awk '/^## Versions /{f=1;next} /^## /{f=0} f' "$work/t.md")"
assert_contains "$v" "mcphost prod: unreachable" "Versions prints mcphost prod: unreachable"
# a black-holed address (connect hangs) must still be cut at the 2 s curl timeout
export HANDOFF_MCPHOST_URL="http://10.255.255.1/status.json"
t0=$(date +%s%N); "$HGEN" --out "$work/h.md"; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
assert_eq "$([ "$ms" -lt 3000 ] && echo yes)" "yes" "hanging connect still < 3 s (${ms} ms)"
assert_contains "$(cat "$work/h.md")" "mcphost prod: unreachable" "hanging host reads unreachable"
exit $fail
