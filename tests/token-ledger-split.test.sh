#!/usr/bin/env bash
# tests/token-ledger-split.test.sh — token-ledger's appended columns
# (split, per_host, compactions) and the extended today-summary suffix.
# Hermetic: fixture JSONL generated here with known usage numbers, one
# compaction marker via isCompactSummary, one via the content prefix alone,
# a duplicate of the first (resumed-session copy, must dedup on uuid), and a
# tool_result that merely quotes the phrase (must NOT count). Host split
# uses the ledgerday fake-ssh (re-invokes the real binary, no network).
# Run with: bash tests/token-ledger-split.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup   # NOW=2026-09-12T10:15:00Z, single host carbon
P='This session is being continued from a previous conversation that ran out of context.'
asst() { # id ts in cw cr out
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' "$2" "$1" "$3" "$4" "$5" "$6"
}
{
  asst m1 2026-09-11T01:00:00Z 1 1 1 1          # superseded partial line
  asst m1 2026-09-11T01:00:05Z 10 100 1000 5    # final usage for m1
  asst m2 2026-09-11T02:00:00Z 1 2 3 4
  printf '{"type":"user","uuid":"u1","timestamp":"2026-09-11T03:00:00Z","isCompactSummary":true,"message":{"content":"%s"}}\n' "$P"
  printf '{"type":"user","uuid":"u2","timestamp":"2026-09-11T04:00:00Z","message":{"content":"%s"}}\n' "$P"
  printf '{"type":"user","uuid":"u3","timestamp":"2026-09-11T05:00:00Z","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' "$P"
  printf '{"type":"user","uuid":"u4","timestamp":"2026-09-11T06:00:00Z","message":{"content":"hello"}}\n'
  asst m3 2026-09-12T09:00:00Z 7 0 0 0
} > "$jsonl/a.jsonl"
# resumed-session copy of the u1 compaction in a second transcript
printf '{"type":"user","uuid":"u1","timestamp":"2026-09-11T03:00:00Z","isCompactSummary":true,"message":{"content":"%s"}}\n' "$P" > "$jsonl/b.jsonl"

"$TL"; rc=$?
assert_eq "$rc" "0" "run exits 0"
assert_eq "$(head -n1 "$state/ledger.tsv" | cut -f9-11)" $'split\tper_host\tcompactions' "header appends split, per_host, compactions"
# raw sums: m1 (10,100,1000,5) + m2 (1,2,3,4) -> in=11 cw=102 cr=1003 out=9
assert_eq "$(ledger_field 2026-09-11 9)" "in=11 cw=102 cr=1003 out=9" "split = raw sums, dedup keeps m1's final line"
# weighted = 11 + 1.25*102 + 0.1*1003 + 5*9 = 283.8 -> per-host rounds to 284
assert_eq "$(ledger_field 2026-09-11 10)" "carbon=284" "per_host single host"
assert_eq "$(ledger_field 2026-09-11 11)" "2" "compactions = flag + prefix markers, uuid-deduped, tool_result quote ignored"
assert_eq "$(ledger_field 2026-09-12 11)" "0" "day with no markers has compactions 0"
assert_eq "$(ledger_field 2026-09-11 3)" "284" "existing weighted column unchanged"
assert_eq "$(cat "$state/today-summary.txt")" \
  "TOKENS yesterday 2026-09-11: 284 budget off · today so far 7 (10:15Z) · forecast 16 · hosts carbon missing  · split in/cw/cr/out 7/0/0/0 · compactions 0 · build_share 0% (coder+inner 0M of 0M)" \
  "summary keeps the old text and appends split + compactions (today)"

# --- old 8-column ledger is upgraded in place, not moved aside ---
rm -f "$state"/*
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n2026-09-01\tm=5\t5\tbudget off\tyes\tcarbon\t\t2026-09-02T00:00:00Z\n' > "$state/ledger.tsv"
"$TL" --day 2026-09-11 2>"$work/err"
assert_not_contains "$(cat "$work/err")" "migrated legacy" "v1 header is not treated as legacy"
assert_eq "$(ledger_field 2026-09-01 3)" "5" "old row preserved"
assert_eq "$(awk -F'\t' '$1=="2026-09-01"{print NF}' "$state/ledger.tsv")" "12" "old row padded to 12 columns"
assert_eq "$(ledger_field 2026-09-11 11)" "2" "--day recomputes one day with new columns"

# --- two hosts via fake ssh: per_host splits by origin ---
rm -f "$state"/*
mkdir -p "$work/hosts/redbaron" "$work/bin"
asst r1 2026-09-11T08:00:00Z 20 0 0 0 > "$work/hosts/redbaron/r.jsonl"
printf '{"type":"user","uuid":"ur","timestamp":"2026-09-11T08:30:00Z","isCompactSummary":true,"message":{"content":"%s"}}\n' "$P" >> "$work/hosts/redbaron/r.jsonl"
ln -s "$here/fixtures/ledgerday/fake-ssh" "$work/bin/ssh"
PATH="$work/bin:$PATH" FAKE_SSH_HOSTS_DIR="$work/hosts" TOKEN_LEDGER_BIN="$TL" \
  TOKEN_LEDGER_HOSTS="carbon redbaron" "$TL" --day 2026-09-11
assert_eq "$(ledger_field 2026-09-11 10)" "carbon=284 redbaron=20" "per_host lists each origin host"
assert_eq "$(ledger_field 2026-09-11 9)" "in=31 cw=102 cr=1003 out=9" "split sums across hosts"
assert_eq "$(ledger_field 2026-09-11 11)" "3" "compactions counted across hosts"

exit "$fail"
