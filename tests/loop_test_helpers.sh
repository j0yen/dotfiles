#!/usr/bin/env bash
# tests/loop_test_helpers.sh — shared setup for tests/loop_ac*.test.sh
# (PRD-grand-loop-scaffold). Not itself a test file (no ac<N> in the name),
# sourced by every loop_ac*.test.sh. Builds an isolated, throwaway git repo
# as PRD_DIR and a fake `mcphost-deploy` on PATH so tests never touch the
# real ~/Documents/PRDs, run no network call, and run offline in well under
# the suite's 20s budget (AC11).
set -uo pipefail

TICK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/grand-loop-tick.sh"
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

# loop_setup — creates $work (cleaned up on EXIT), $repo (a fresh git repo
# with build-queue/, projects/, and the grand-loop scaffold's directories),
# $bin (a tmp dir on PATH holding mcphost-deploy -> fixtures/fake-mcphost-deploy),
# and exports GRAND_LOOP_PRD_DIR + GRAND_LOOP_LOG so the tick script under
# test never touches the real filesystem.
loop_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  repo="$work/prds"
  git init -q "$repo"
  git -C "$repo" config user.email test@test.com
  git -C "$repo" config user.name test
  mkdir -p "$repo/projects" "$repo/build-queue"
  printf '# Project profile: grand-loop\n' > "$repo/projects/grand-loop.md"
  git -C "$repo" add -A && git -C "$repo" commit -q -m init

  bin="$work/bin"
  mkdir -p "$bin"
  ln -s "$FIXTURES/fake-mcphost-deploy" "$bin/mcphost-deploy"

  export GRAND_LOOP_PRD_DIR="$repo"
  export GRAND_LOOP_LOG="$work/grand-loop.log"
  export GRAND_LOOP_ENV="$work/nonexistent-env"  # no env file: exercise defaults
  export PATH="$bin:$PATH"

  loop_dir="$repo/grand-loop"
  ledger="$loop_dir/ledger.md"
  state="$loop_dir/state.json"
  profile="$repo/projects/grand-loop.md"
}

run_tick() { bash "$TICK" "$@"; }
