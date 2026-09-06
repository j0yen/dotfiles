#!/usr/bin/env bash
# tests/buildpath_ac8_suite_offline.test.sh —
# PRD-build-path-unit-overlap-exit0 AC8: the buildpath test suite passes
# offline in under 10s. Runs every sibling buildpath_ac*.test.sh (explicit
# list, not this file itself) and times the total. Every fixture here is a
# fake systemctl/systemd-run plus a throwaway tmp dir — no real unit is
# touched and no network call is possible.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

siblings=(
  buildpath_ac1_tick_running.test.sh
  buildpath_ac2_freed.test.sh
  buildpath_ac3_pinned.test.sh
  buildpath_ac4_notfound.test.sh
  buildpath_ac5_systemdrun_fail.test.sh
)

fail=0
start=$(date +%s%N)
for t in "${siblings[@]}"; do
  if bash "$here/$t"; then
    echo "ok - $t"
  else
    echo "NOT OK - $t"
    fail=1
  fi
done
end=$(date +%s%N)
elapsed_s=$(( (end - start) / 1000000000 ))

if [ "$elapsed_s" -lt 10 ]; then
  echo "ok - suite ran in ${elapsed_s}s (< 10s)"
else
  echo "NOT OK - suite took ${elapsed_s}s (>= 10s)"
  fail=1
fi

exit $fail
