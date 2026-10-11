#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC6: a Bash command mentioning parked/
# without git mv (ls parked/) -> exit 0 and no stdout.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

for c in "ls parked/" "cat parked/PRD-x.md" "git log -- parked/" "git mv build-queue/PRD-x.md build-queue/PRD-y.md"; do
  run_hook "$(bash_payload "$c")"
  assert_eq "$rc" "0" "'$c': exit 0"
  assert_eq "$out" "" "'$c': no stdout"
done
exit $fail
