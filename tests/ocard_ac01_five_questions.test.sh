#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC1: with all five sources present the
# generator's status.json answers runs, fleet queue counts, chain, siblings and
# daemon-vs-binary with no null field and every source ok.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
t="$work/t.json"
"$GEN" --out "$t"; assert_eq "$?" "0" "generator exits 0"
jq -e . "$t" >/dev/null || { echo "NOT OK - t.json parses"; exit 1; }
assert_eq "$(jq -r '[.runs[].id]|sort|join(",")' "$t")" "488,518,519" "runs: the 3 open rows"
assert_eq "$(jq -r '.runs[0]|[.slug,.stage,(.age_min|type),.created_by,.mode]|join(",")' "$t")" "alpha,land,number,tick,daemon" "run row fields"
assert_eq "$(jq -c '.queue' "$t")" '{"queue_total":12,"queue_ready":5,"building":2,"blocked":3,"parked":2}' "queue: fleet-dash counts"
assert_eq "$(jq -r '.chain|[.chain_run_id,.link,.status,.ts]|join(",")' "$t")" "c2,digest,running,2026-10-11T07:00:00Z" "chain: newest ledger row"
assert_eq "$(jq -r '[.siblings[].session_id]|join(",")' "$t")" "claude-2576670,claude-9" "siblings: intents minus self"
assert_eq "$(jq -r '.siblings[0]|[.skill,.prd,.since]|join(",")' "$t")" "dream,T9,2026-10-11T06:58:00Z" "sibling fields"
assert_eq "$(jq -r '.decisions_open[0]|[.id,.slug,.cause]|join(",")' "$t")" "7,alpha,cordon" "decisions_open"
assert_eq "$(jq -r '.daemon|[.running_version,.binary.version]|join(",")' "$t")" "0.1.0,0.2.0" "daemon vs binary versions"
assert_eq "$(jq '[.. | scalars | select(. == null)] | length' "$t")" "0" "no null field anywhere"
assert_eq "$(jq -r '.sources|to_entries|map(select(.value!="ok"))|length' "$t")" "0" "sources all ok"
assert_eq "$(jq -r '.sources|keys|join(",")' "$t")" "chain,config,daemon,decisions,queue,runs,siblings" "sources cover every section"
exit $fail
