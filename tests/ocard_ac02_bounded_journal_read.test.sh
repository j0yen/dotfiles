#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC2: with a 300 MB journal whose tick row
# sits in the last 1 MB, the generator finishes in < 2 s and reads < 3 MB
# (sum of read-family syscall returns under strace -f).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
ocard_setup
assert_eq "$(stat -c %s "$work/state/journal.jsonl" | awk '{print ($1>300000000)?"big":"small"}')" "big" "journal fixture is >= 300 MB"
t="$work/t.json"
s=$(date +%s.%N); "$GEN" --out "$t"; e=$(date +%s.%N)
assert_eq "$(awk -v s="$s" -v e="$e" 'BEGIN{print (e-s<2)?"fast":"slow"}')" "fast" "generator wall < 2 s"
assert_eq "$(jq -r '.config.tick_loaded_at|type' "$t")" "string" "tick row found at the end of the journal (config.tick_loaded_at)"
if ! command -v strace >/dev/null || ! strace -o /dev/null -e trace=read true 2>/dev/null; then
  echo "NOT OK - strace unavailable, cannot count bytes read"; exit 1
fi
tr="$work/strace.out"
strace -f -o "$tr" -e trace=read,pread64,readv "$GEN" --out "$t"
bytes=$(awk '/ (read|pread64|readv)\(/ && $NF ~ /^[0-9]+$/ {s+=$NF; next} / = [0-9]+$/ {s+=$NF} END{print s+0}' "$tr")
echo "# bytes read: $bytes"
assert_eq "$(awk -v b="$bytes" 'BEGIN{print (b<3000000)?"under":"over"}')" "under" "reads < 3 MB"
assert_eq "$(awk -v b="$bytes" 'BEGIN{print (b>500000)?"real":"suspicious"}')" "real" "the tail was really read (sanity floor)"
exit $fail
