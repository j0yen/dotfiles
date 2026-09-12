#!/usr/bin/env bash
# tests/ledgerday_test_helpers.sh — shared setup for tests/ledgerday_ac*.test.sh
# (PRD-token-ledger-day-buckets, test_prefix: ledgerday). Not itself a test
# file (no ac<N> in the name), sourced by every ledgerday_ac*.test.sh. Points
# the real .local/bin/token-ledger at an isolated $work dir via its env-var
# testability knobs, so tests never touch the real ~/.cache/token-ledger or
# ~/.claude/projects, run no live ssh, and stay hermetic/reproducible.
set -uo pipefail

TL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.local/bin/token-ledger"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/ledgerday"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - ledgerday: $3"
  else echo "NOT OK - ledgerday: $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - ledgerday: $3" ;; *) echo "NOT OK - ledgerday: $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "NOT OK - ledgerday: $3: '$1' unexpectedly contains '$2'"; fail=1 ;; *) echo "ok - ledgerday: $3" ;; esac
}
assert() { # $1=cond $2=description
  if eval "$1"; then echo "ok - ledgerday: $2"; else echo "NOT OK - ledgerday: $2"; fail=1; fi
}

# ledgerday_setup — creates $work (removed on EXIT), $state (empty
# TOKEN_LEDGER_STATE_DIR), $jsonl (empty TOKEN_LEDGER_JSONL_ROOT), and
# exports the single-host defaults every AC that doesn't care about the
# fleet/ssh path can just run against.
ledgerday_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  state="$work/state"
  jsonl="$work/jsonl"
  mkdir -p "$state" "$jsonl"
  export TOKEN_LEDGER_STATE_DIR="$state"
  export TOKEN_LEDGER_JSONL_ROOT="$jsonl"
  export TOKEN_LEDGER_HOSTS="carbon"
  export TOKEN_LEDGER_LOCAL_HOST="carbon"
  export TOKEN_LEDGER_NOW="2026-09-12T10:15:00Z"
  unset TOKEN_BUDGET_WEIGHTED
}

# ledger_field DATE COLUMN — read one column (1-based) from $state/ledger.tsv
# for the row matching DATE. Empty string if the row doesn't exist.
ledger_field() {
  awk -F'\t' -v d="$1" -v c="$2" '$1==d{print $c}' "$state/ledger.tsv" 2>/dev/null
}
