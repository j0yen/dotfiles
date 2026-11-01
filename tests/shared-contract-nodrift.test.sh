#!/usr/bin/env bash
# shared-contract-nodrift.test.sh: the two json shapes dotfiles writes and fleet-dash reads are byte-identical in both repos (1071 M4/M6 brief, "Shared contract").
# Dotfiles is the one writer; fleet-dash copies. Changing a fixture here means changing these pins AND the fleet-dash copy in the same pair of PRs.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
pin() { # file md5
  local got; got=$(md5sum "$here/fixtures/shared/$1" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$2" ]; then echo "PASS: tests/fixtures/shared/$1 md5 $2"; else echo "FAIL: tests/fixtures/shared/$1 md5 $got, pinned $2"; fail=$((fail+1)); fi
}
pin hold-consumers.json 34118da1abbd50afb10b9b38b4177fbd
pin spec-age.json a9fe9c0ceb568aac6d5f6bf469b2dee8
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fail"; fi
exit "$fail"
