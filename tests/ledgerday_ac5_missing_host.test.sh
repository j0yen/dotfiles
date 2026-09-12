#!/usr/bin/env bash
# tests/ledgerday_ac5_missing_host.test.sh — PRD-token-ledger-day-buckets
# AC5 (P0, test_prefix: ledgerday): given a fake `ssh` that fails for
# ryzen7, when the run completes, then the rows for the window carry
# missing=ryzen7, the exit status is 0, and carbon's and redbaron's records
# are present. The fake ssh (fixtures/ledgerday/fake-ssh) re-invokes the
# real token-ledger binary in --emit-local-records mode against a per-host
# fixture root for redbaron, and fails outright for ryzen7 — no live
# network, no real ssh config needed. Run with:
#   bash tests/ledgerday_ac5_missing_host.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
cp "$FIXTURES/local-ac5.jsonl" "$jsonl/local.jsonl"

bin="$work/bin"
mkdir -p "$bin"
ln -s "$FIXTURES/fake-ssh" "$bin/ssh"
export PATH="$bin:$PATH"
export FAKE_SSH_HOSTS_DIR="$FIXTURES/hosts"
export FAKE_SSH_FAIL_HOSTS="ryzen7"
export TOKEN_LEDGER_BIN="$TL"
export TOKEN_LEDGER_HOSTS="carbon redbaron ryzen7"
export TOKEN_LEDGER_SSH_TIMEOUT=3

"$TL" --since 2026-09-11T00:00:00Z --until 2026-09-12T00:00:00Z
rc=$?
assert_eq "$rc" "0" "exit status is 0 even though ryzen7 is unreachable"

assert_eq "$(ledger_field 2026-09-11 6)" "carbon,redbaron" "row names both reachable hosts"
assert_eq "$(ledger_field 2026-09-11 7)" "ryzen7" "row carries missing=ryzen7, not silently omitted"

# msg_c1 (carbon, in=10 -> weighted 10) + msg_r1 (redbaron, in=20 -> weighted 20) = 30.
# If either host's records were dropped, this would be 10 or 20, not 30.
assert_eq "$(ledger_field 2026-09-11 3)" "30" "carbon's and redbaron's records are both present in the total"

exit "$fail"
