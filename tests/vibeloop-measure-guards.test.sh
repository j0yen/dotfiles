#!/usr/bin/env bash
# tests/vibeloop-measure-guards.test.sh — PRD-mcphost-measure-guards Requirement 6/AC6:
# exercises the deploy->measure job's decision logic (proxy parse, the zero-bootstrap
# skip rule, cleanup accounting) against fixture JSON, with no network, no systemctl,
# and no live mcphost/synthorg. Plain bash (no bats dependency) — run with:
#   bash tests/vibeloop-measure-guards.test.sh
# from the repo root. Exits nonzero (and prints every failure) if any assertion fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
# The functions under test are function-only at source time (no top-level
# systemctl/curl/git calls) precisely so this can source them directly.
. "$here/../.local/lib/vibeloop-measure-guards.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=case description
  if [ "$1" = "$2" ]; then
    echo "ok - $3"
  else
    echo "NOT OK - $3: got '$1', want '$2'"
    fail=1
  fi
}

# -- proxy_parse + proxy_should_skip: zero / partial / full bootstrap -------

read -r k n <<< "$(proxy_parse "$fixtures/proxy-measure-zero.json")"
assert_eq "$k $n" "0 3" "proxy_parse: zero-bootstrap fixture reads 0/3"
if proxy_should_skip "$k"; then
  echo "ok - proxy_should_skip: zero bootstraps skips the truth tier"
else
  echo "NOT OK - proxy_should_skip: zero bootstraps should skip"; fail=1
fi

read -r k n <<< "$(proxy_parse "$fixtures/proxy-measure-partial.json")"
assert_eq "$k $n" "3 7" "proxy_parse: partial-bootstrap fixture reads 3/7"
if proxy_should_skip "$k"; then
  echo "NOT OK - proxy_should_skip: partial bootstraps (3/7) should NOT skip"; fail=1
else
  echo "ok - proxy_should_skip: partial bootstraps continues to the truth tier"
fi

read -r k n <<< "$(proxy_parse "$fixtures/proxy-measure-full.json")"
assert_eq "$k $n" "2 2" "proxy_parse: full-bootstrap fixture reads 2/2"
if proxy_should_skip "$k"; then
  echo "NOT OK - proxy_should_skip: full bootstraps (2/2) should NOT skip"; fail=1
else
  echo "ok - proxy_should_skip: full bootstraps continues to the truth tier"
fi

# A run that never wrote measure.json at all (proxy tier crashed/timed out)
# degrades to 0/0, which must still skip — not error, not "proceed".
read -r k n <<< "$(proxy_parse "$fixtures/does-not-exist.json")"
assert_eq "$k $n" "0 0" "proxy_parse: missing measure.json reads 0/0"
if proxy_should_skip "$k"; then
  echo "ok - proxy_should_skip: a missing measure.json (0/0) skips"
else
  echo "NOT OK - proxy_should_skip: a missing measure.json (0/0) should skip"; fail=1
fi

# -- cleanup accounting: zero / partial / full tenant_delete_by_prefix responses --

resp_zero=$(cat "$fixtures/tenant-delete-zero.json")
assert_eq "$(count_deleted "$resp_zero")" "0" "count_deleted: zero-deletion response counts 0"

resp_partial=$(cat "$fixtures/tenant-delete-partial.json")
assert_eq "$(count_deleted "$resp_partial")" "2" "count_deleted: partial-deletion response counts 2"

resp_full=$(cat "$fixtures/tenant-delete-full.json")
assert_eq "$(count_deleted "$resp_full")" "20" "count_deleted: full-deletion response counts 20"

# A malformed/empty response must count as 0, not crash the run.
assert_eq "$(count_deleted 'not json')" "0" "count_deleted: malformed JSON counts 0, does not error"

# Cleanup runs against two prefixes (panel_, probe-) per run; the accounted
# total is their sum, folded against fixture healthz before/after tenant counts.
removed=$(( $(count_deleted "$resp_partial") + $(count_deleted "$resp_full") ))
assert_eq "$removed" "22" "cleanup accounting: panel_ (2) + probe- (20) sums to 22"
after=$(python3 -c 'import json;print(json.load(open("'"$fixtures"'/healthz-after.json")).get("tenants_total"))')
assert_eq "$(cleanup_field_from_counts "$removed" "$after")" "cleanup=22 tenants_after=8" \
  "cleanup_field_from_counts: full run, fixture healthz-after"

before=$(python3 -c 'import json;print(json.load(open("'"$fixtures"'/healthz-before.json")).get("tenants_total"))')
zero_removed=$(count_deleted "$resp_zero")
assert_eq "$(cleanup_field_from_counts "$zero_removed" "$before")" "cleanup=0 tenants_after=28" \
  "cleanup_field_from_counts: nothing removed (e.g. no panel_/probe- tenants existed), tenants_after unchanged"

# Requirement 2/AC2: an unreadable tenants_after (empty string, as when
# /healthz was unreachable on the post-delete read) prints 'unknown', not a
# blank field a ledger-line parser would choke on.
assert_eq "$(cleanup_field_from_counts "3" "")" "cleanup=3 tenants_after=unknown" \
  "cleanup_field_from_counts: unreadable post-delete /healthz reads as 'unknown'"

if [ "$fail" -eq 0 ]; then
  echo "all vibeloop-measure-guards tests passed"
else
  echo "vibeloop-measure-guards tests FAILED"
fi
exit "$fail"
