#!/usr/bin/env bash
# tests/token-ledger-build-share.test.sh — token-ledger's per-file `role`, the
# appended per_role column, build_share in today-summary.txt (+ the ALARM
# second line under 50 % when today's total is over 50M) and build-share.json.
# Hermetic: fixture transcripts under a temp TOKEN_LEDGER_JSONL_ROOT, a temp
# SEATS_TABLE, one in-tokens-only assistant record per file so weighted == in.
# Run with: bash tests/token-ledger-build-share.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup   # NOW=2026-09-12T10:15:00Z, single host carbon (today = 2026-09-12)
export SEATS_TABLE="$work/seats.tsv"
printf '# seat\trole\tsid\ttick_min\n\nother\tr\tsid-other\t5\nrb\tr\tsid-rb\t5\n' > "$SEATS_TABLE"

# mk FILE USER_LINE_JSON IN — one transcript: optional user line, one assistant record
asst() { # id in
  printf '{"type":"assistant","timestamp":"2026-09-12T09:00:00Z","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$1" "$2"
}
user_str() { printf '{"type":"user","uuid":"u-%s","timestamp":"2026-09-12T08:59:00Z","message":{"content":"%s"}}\n' "$RANDOM" "$1"; }
mk() { # file text in
  mkdir -p "$(dirname "$jsonl/$1")"
  { user_str "$2"; asst "m-$(echo "$1" | tr -c 'a-z0-9\n' '-')" "$3"; } > "$jsonl/$1"
}
# fixtures(scale-of-inner-in, divisor) builds the whole tree
fixtures() { # inner_in div
  rm -rf "$jsonl"; mkdir -p "$jsonl"
  local d="$2"
  mk "-home-jsy-wm-build-wt-foo/inner1.jsonl"          "hello"                                  "$1"
  mk "-home-jsy/sid-rb.jsonl"                          "implement the thing"                    "$((40000000/d))"
  mk "-home-jsy/sid-rb/subagents/agent-c.jsonl"        "Implement the binding spec"             "$((5000000/d))"
  mk "-home-jsy/sid-rb/subagents/agent-v.jsonl"        "VERIFY the build landed"                "$((3000000/d))"
  mk "-home-jsy/sid-rb/subagents/agent-s.jsonl"        "Find where foo is defined"              "$((2000000/d))"
  mk "-home-jsy/sid-rb/subagents/agent-r.jsonl"        "RUNNER: systemctl status x"             "$((1000000/d))"
  mk "-home-jsy/sid-rb/subagents/agent-g.jsonl"        "re-grade this DECISION"                 "$((1000000/d))"
  # headless coder: first line is a command echo, first text element a system-reminder
  mkdir -p "$jsonl/-home-jsy"
  {
    printf '{"type":"user","uuid":"hc0","timestamp":"2026-09-12T08:58:00Z","message":{"content":"<command-name>/x</command-name>"}}\n'
    printf '{"type":"user","uuid":"hc1","timestamp":"2026-09-12T08:59:00Z","message":{"content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"},{"type":"text","text":"Read your full spec at /x"}]}}\n'
    asst m-hc "$((4000000/d))"
  } > "$jsonl/-home-jsy/hc.jsonl"
  mk "-home-jsy/int.jsonl"                             "hello there"                            "$((1000000/d))"
}

PR_ALARM="coder=9000000;inner=10000000;interactive=1000000;review=1000000;runner=1000000;scout=2000000;seat:rb=40000000;verifier=3000000"

# --- 1. emit mode: per-file role on every record ---
fixtures 10000000 1
roles="$("$TL" --emit-local-records --since 2026-09-12T00:00:00Z | jq -r '[.role] | .[0]' | sort | uniq -c | awk '{print $2"="$1}' | paste -sd' ')"
assert_eq "$roles" "coder=2 inner=1 interactive=1 review=1 runner=1 scout=1 seat:rb=1 verifier=1" "emit-local-records tags each record with its file's role"

# --- 2. total 67M, build 19M = 28 % -> per_role column, banner, ALARM, json ---
"$TL"; rc=$?
assert_eq "$rc" "0" "run exits 0"
assert_eq "$(head -n1 "$state/ledger.tsv" | cut -f12)" "per_role" "header appends per_role"
assert_eq "$(awk -F'\t' '$1=="2026-09-12"{print NF}' "$state/ledger.tsv")" "12" "row has 12 columns"
assert_eq "$(ledger_field 2026-09-12 12)" "$PR_ALARM" "per_role = weighted per role, sorted"
assert_eq "$(ledger_field 2026-09-12 3)" "67000000" "weighted total = 67M"
sum=$(ledger_field 2026-09-12 12 | tr ';' '\n' | awk -F= '{s+=$2} END{print s}')
assert_eq "$sum" "67000000" "per_role sums to the weighted total"
summary="$(cat "$state/today-summary.txt")"
assert_contains "$(head -n1 "$state/today-summary.txt")" " · build_share 28% (coder+inner 19M of 67M)" "line 1 carries build_share"
assert_contains "$summary" "ALARM build_share 28% < 50% — building is coder+inner; the rest is management" "ALARM line under 50 % and > 50M"
assert_eq "$(wc -l < "$state/today-summary.txt")" "2" "summary file is two lines under alarm"
bs="$state/build-share.json"
assert_eq "$(jq -r '.date' "$bs")" "2026-09-12" "build-share.json date"
assert_eq "$(jq -r '.build_share' "$bs")" "28.4" "build-share.json build_share percent"
assert_eq "$(jq -r '.build_weighted' "$bs")" "19000000" "build-share.json build_weighted = coder+inner"
assert_eq "$(jq -r '.total_weighted' "$bs")" "67000000" "build-share.json total_weighted"
assert_eq "$(jq -c '.per_role' "$bs")" '{"coder":9000000,"inner":10000000,"interactive":1000000,"review":1000000,"runner":1000000,"scout":2000000,"seat:rb":40000000,"verifier":3000000}' "build-share.json per_role"
"$TL" --check; assert_eq "$?" "0" "--check passes on the new 12-column file"

# --- 3. build-heavy day: 60M inner -> 69M of 117M = 58 %, no ALARM ---
rm -f "$state"/*
fixtures 60000000 1
"$TL"
assert_contains "$(head -n1 "$state/today-summary.txt")" " · build_share 58% (coder+inner 69M of 117M)" "build-heavy day banner"
assert_not_contains "$(cat "$state/today-summary.txt")" "ALARM" "no ALARM at or above 50 %"
assert_eq "$(wc -l < "$state/today-summary.txt")" "1" "summary file stays one line without alarm"

# --- 4. small day (28 % but total 67K < 50M): no ALARM, json still written ---
rm -f "$state"/*
fixtures 10000 1000
"$TL"
assert_contains "$(head -n1 "$state/today-summary.txt")" "build_share 28% (coder+inner 0M of 0M)" "small day still reports build_share"
assert_not_contains "$(cat "$state/today-summary.txt")" "ALARM" "no ALARM when total <= 50M"
assert_eq "$(jq -r '.total_weighted' "$state/build-share.json")" "67000" "small day json written"

# --- 5. existing 11-column ledger (v2 header): not moved aside, --check ok, padded to 12 ---
rm -f "$state"/*
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\tsplit\tper_host\tcompactions\n2026-09-01\tm=5\t5\tbudget off\tyes\tcarbon\t\t2026-09-02T00:00:00Z\tin=5 cw=0 cr=0 out=0\tcarbon=5\t0\n' > "$state/ledger.tsv"
"$TL" --check 2>"$work/err"; assert_eq "$?" "0" "--check passes on an existing 11-column file"
fixtures 10000000 1
"$TL" 2>"$work/err"
assert_not_contains "$(cat "$work/err")" "migrated legacy" "11-column header is not treated as legacy"
assert_eq "$(awk -F'\t' '$1=="2026-09-01"{print NF}' "$state/ledger.tsv")" "12" "old 11-column row padded to 12"
assert_eq "$(ledger_field 2026-09-01 3)" "5" "old row preserved"
"$TL" --check; assert_eq "$?" "0" "--check passes after the upgrade"

# --- 6. old row without per_role for today: build_share n/a, never alarms ---
rm -f "$state"/*; rm -rf "$jsonl"; mkdir -p "$jsonl"
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\tsplit\tper_host\tcompactions\n2026-09-12\tm=90000000\t90000000\tbudget off\tno\tcarbon\t\t2026-09-12T01:00:00Z\tin=1 cw=0 cr=0 out=0\tcarbon=1\t0\n' > "$state/ledger.tsv"
"$TL" --day 2026-09-11
assert_contains "$(cat "$state/today-summary.txt")" "build_share n/a" "unknown per_role reads n/a"
assert_not_contains "$(cat "$state/today-summary.txt")" "ALARM" "unknown per_role never alarms"
assert_eq "$(jq -r '.build_share' "$state/build-share.json")" "null" "unknown per_role json build_share is null"

exit "$fail"
