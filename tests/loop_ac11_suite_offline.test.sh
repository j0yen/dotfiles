#!/usr/bin/env bash
# tests/loop_ac11_suite_offline.test.sh — PRD-grand-loop-scaffold AC11: the
# loop test suite passes offline in under 20s and attempts no network call.
# Runs every sibling loop_ac*.test.sh (explicit list, not this file itself)
# and times the total. Every fixture in this suite is the local
# fake-mcphost-deploy plus a throwaway git repo with no remote — a stray
# network attempt would only ever come from a bug, not from the fixtures.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

siblings=(
  loop_ac1_basic_tick.test.sh
  loop_ac2_flock.test.sh
  loop_ac3_stop.test.sh
  loop_ac4_unvalidated.test.sh
  loop_ac5_distribution.test.sh
  loop_ac6_families.test.sh
  loop_ac7_growing.test.sh
  loop_ac8_budget_cap.test.sh
  loop_ac9_tenant_mismatch.test.sh
  loop_ac10_loop_notes.test.sh
  loop_ac12_status.test.sh
)

fail=0
start=$(date +%s%N)
for t in "${siblings[@]}"; do
  # Unset any per-test env leaking from a prior iteration's `export` (each
  # sibling calls loop_setup, which overrides PATH/GRAND_LOOP_* anyway).
  if bash "$here/$t"; then
    echo "ok - $t"
  else
    echo "NOT OK - $t"
    fail=1
  fi
done
end=$(date +%s%N)
elapsed_s=$(( (end - start) / 1000000000 ))

if [ "$elapsed_s" -lt 20 ]; then
  echo "ok - suite ran in ${elapsed_s}s (< 20s)"
else
  echo "NOT OK - suite took ${elapsed_s}s (>= 20s)"
  fail=1
fi

exit $fail
