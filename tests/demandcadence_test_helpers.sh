#!/usr/bin/env bash
# tests/demandcadence_test_helpers.sh — shared setup for
# tests/demandcadence_ac*.test.sh (PRD-grand-loop-demand-cadence). Not
# itself a test file. Builds a throwaway bare git repo as the "dedicated
# clone"'s origin (so fetch/push/reset semantics are real, no network), and
# a fake `mcphost-deploy` + `agorabus` on PATH — mirrors the
# loop_test_helpers.sh / buildpath_test_helpers.sh convention.
set -uo pipefail

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/grand-loop-demand.sh"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "NOT OK - $3: '$1' unexpectedly contains '$2'"; fail=1 ;; *) echo "ok - $3" ;; esac
}

# demandcadence_setup — creates $work (cleaned up on EXIT), a bare git repo
# at $origin_bare seeded with one commit on main, a fake bin dir on PATH
# ahead of the real mcphost-deploy/agorabus, and exports every
# GRAND_LOOP_DEMAND_* hook the runner reads so it never touches the real
# filesystem or network. Sets $clone as a convenience for tests to inspect
# the clone the runner creates.
demandcadence_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  origin_bare="$work/origin.git"
  git init -q --bare -b main "$origin_bare"

  seed="$work/seed"
  git init -q -b main "$seed"
  git -C "$seed" config user.email test@test.com
  git -C "$seed" config user.name test
  printf '# seed\n' > "$seed/README.md"
  git -C "$seed" add -A && git -C "$seed" commit -q -m seed
  git -C "$seed" remote add origin "$origin_bare"
  git -C "$seed" push -q origin main

  bin="$work/bin"
  mkdir -p "$bin"
  ln -s "$FIXTURES/fake-mcphost-deploy" "$bin/mcphost-deploy"
  ln -s "$FIXTURES/fake-agorabus" "$bin/agorabus"

  agorabus_calls="$work/agorabus-calls"
  : > "$agorabus_calls"
  export FAKE_AGORABUS_CALLS="$agorabus_calls"

  clone="$work/clone"
  ledger="$clone/grand-loop/demand/ledger.jsonl"

  export GRAND_LOOP_DEMAND_CLONE_DIR="$clone"
  export GRAND_LOOP_DEMAND_ORIGIN="$origin_bare"
  export GRAND_LOOP_DEMAND_BRANCH="main"
  # Under their own subdirs (not directly in $work) so a test exercising
  # "the install-created directories are missing" (AC7) can rm -rf just
  # these parents without also destroying $origin_bare/$bin/$work itself.
  export GRAND_LOOP_DEMAND_LOG="$work/logs/demand.log"
  export GRAND_LOOP_DEMAND_MD_CACHE="$work/config/md-cache"
  export GRAND_LOOP_DEMAND_MD_REPO="$work/no-such-repo"
  unset GRAND_LOOP_DEMAND_MD_BIN GRAND_LOOP_DEMAND_TODAY FAKE_MEASURE_MODE FAKE_MEASURE_JSON
  export PATH="$bin:$PATH"
}

run_demand() { bash "$RUNNER" "$@"; }
