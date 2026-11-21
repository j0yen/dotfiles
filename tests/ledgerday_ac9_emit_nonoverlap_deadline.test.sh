#!/usr/bin/env bash
# tests/ledgerday_ac9_emit_nonoverlap_deadline.test.sh — A1733 (test_prefix:
# ledgerday): the remote --emit-local-records runs one at a time per host and
# never outlives the orchestrator's budget. Drives the real binary, directly
# and through fixtures/ledgerday/fake-ssh:
#   (1) an emit while another holds the emit lock exits 75 with one stderr line
#   (2) a slow emit (TOKEN_LEDGER_TEST_PER_FILE_SLEEP=infinity) given
#       TOKEN_LEDGER_EMIT_DEADLINE exits 76 by itself, no descendant survives
#   (2b) the same slow emit whose parent dies exits 74 at its next wake-up
#   (2c) an emit whose stdout has no reader exits 74 at its first write
#   (3) the orchestrator marks that slow host missing and still writes the
#       day row from the other hosts; the slow host's emit, detached the way a
#       real remote is (fake-ssh FAKE_SSH_DETACH_HOSTS: `timeout` kills only
#       the client), received the orchestrator's SSH_TIMEOUT as
#       TOKEN_LEDGER_EMIT_DEADLINE and ends by itself (exit 74 or 76), leaving
#       nothing behind
#   (4) output equivalence: the emit over fixtures/ledgerday/build-emit-tree.sh
#       equals, sorted and byte for byte, the pre-A1733 binary's output
#       (emit-tree.golden.ndjson)
# Each of (2)-(3) runs in its own session (setsid, no fork: a background job
# is no group leader, so the session id is the job's pid); a survivor is any
# process left in that session. No assertion is on elapsed time. Run with:
#   bash tests/ledgerday_ac9_emit_nonoverlap_deadline.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ledgerday_test_helpers.sh
. "$here/ledgerday_test_helpers.sh"

ledgerday_setup
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"
lock="$XDG_RUNTIME_DIR/token-ledger-emit.$EUID.lock"
cp "$FIXTURES/local-ac5.jsonl" "$jsonl/local.jsonl"

# survivors SID -> pids still in session SID
survivors() { pgrep -s "$1" | paste -sd' ' -; }

# --- (1) non-overlap: the lock is held (as a running emit holds it) -> exit 75, one stderr line, no records
exec {held}>>"$lock"
flock -n "$held"
out="$("$TL" --emit-local-records --since 2026-09-11T00:00:00Z 2>"$work/err1")"; rc=$?
assert_eq "$rc" "75" "(1) an emit while the emit lock is held exits 75"
assert_eq "$(wc -l <"$work/err1" | tr -d ' ')" "1" "(1) the refusal is one stderr line"
assert_contains "$(cat "$work/err1")" "another --emit-local-records holds $lock" "(1) the line names the lock"
assert_eq "$out" "" "(1) a refused emit prints no records"
exec {held}>&-
out="$("$TL" --emit-local-records --since 2026-09-11T00:00:00Z 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "(1) once the lock is free the emit runs (exit 0)"
assert_contains "$out" '"id":"msg_c1"' "(1) and prints its records"

# --- (2) deadline: a never-finishing file, TOKEN_LEDGER_EMIT_DEADLINE=1 -> exit 76, no survivor, scratch dir gone
setsid env TOKEN_LEDGER_EMIT_DEADLINE=1 TOKEN_LEDGER_TEST_PER_FILE_SLEEP=infinity \
  "$TL" --emit-local-records --since 2026-09-11T00:00:00Z >"$work/out2" 2>"$work/err2" &
sid=$!
wait "$sid"; rc=$?
assert_eq "$rc" "76" "(2) an emit past TOKEN_LEDGER_EMIT_DEADLINE exits 76 by itself"
assert_eq "$(wc -l <"$work/err2" | tr -d ' ')" "1" "(2) one stderr line"
assert_contains "$(cat "$work/err2")" "deadline 1s" "(2) the line names the deadline"
assert_eq "$(cat "$work/out2")" "" "(2) no partial records from the unfinished file"
assert_eq "$(survivors "$sid")" "" "(2) no descendant of the emit survives it"
assert_eq "$(ls -A "$TMPDIR")" "" "(2) the emit's scratch dir is removed"

# --- (2b) parent gone: the emit's parent is killed while the emit is in its file; the next wake-up exits 74
mkfifo "$work/out2b" "$work/pid2b"
cat "$work/out2b" >"$work/records2b" &   # reader first: EOF here = every holder of the emit's stdout has exited
reader=$!
setsid env TOKEN_LEDGER_TEST_PER_FILE_SLEEP=infinity bash -c \
  '"$1" --emit-local-records --since 2026-09-11T00:00:00Z >"$2" 2>"$3" & echo "$!" >"$4"; wait' \
  _ "$TL" "$work/out2b" "$work/err2b" "$work/pid2b" &
parent=$!   # the emit's parent, and the session id
read -r emit_pid <"$work/pid2b"
# the seam sleep exists only inside a worker, after the emit recorded its parent
until pgrep -s "$parent" -x sleep >/dev/null; do :; done
kill -KILL "$parent"; wait "$parent" 2>/dev/null
# wake the emit: end its worker's seam sleep, so the worker reads the file and exits
for w in $(pgrep -P "$emit_pid"); do pkill -TERM -x sleep -P "$w"; done
wait "$reader"
assert_contains "$(cat "$work/err2b")" "(exit 74)" "(2b) an emit whose parent is gone exits 74"
assert_contains "$(cat "$work/err2b")" "parent" "(2b) the line names the lost parent"
assert_eq "$(wc -l <"$work/err2b" | tr -d ' ')" "1" "(2b) one stderr line"
assert_eq "$(cat "$work/records2b")" "" "(2b) no records are written once the parent is gone"
assert_eq "$(survivors "$parent")" "" "(2b) no descendant of the orphaned emit survives it"

# --- (2c) stdout closed: a pipe whose only reader is gone before the emit starts -> the first write fails -> exit 74
mkfifo "$work/out2c"
exec {r2c}<>"$work/out2c"   # read-write open: does not block, and lets the write-only open below succeed
exec {w2c}>"$work/out2c"
exec {r2c}<&-               # the only reader closes: the emit's stdout now has none
"$TL" --emit-local-records --since 2026-09-11T00:00:00Z 1>&"$w2c" 2>"$work/err2c"; rc=$?
exec {w2c}>&-
assert_eq "$rc" "74" "(2c) an emit whose stdout has no reader exits 74"
assert_contains "$(cat "$work/err2c")" "stdout closed" "(2c) the line names the closed stdout"
assert_eq "$(wc -l <"$work/err2c" | tr -d ' ')" "1" "(2c) one stderr line"

# --- (3) orchestrator: redbaron's emit never finishes inside SSH_TIMEOUT -> missing=redbaron; carbon + ryzen7 counted
mkdir -p "$work/hosts/redbaron" "$work/hosts/ryzen7" "$work/bin"
cp "$FIXTURES/hosts/redbaron/remote.jsonl" "$work/hosts/redbaron/remote.jsonl"
sed 's/msg_r1/msg_y1/; s/"input_tokens":20/"input_tokens":40/' "$FIXTURES/hosts/redbaron/remote.jsonl" >"$work/hosts/ryzen7/remote.jsonl"
ln -s "$FIXTURES/fake-ssh" "$work/bin/ssh"
mkfifo "$work/remote-err"
cat "$work/remote-err" >"$work/remote-err.txt" &   # EOF here = the detached remote emit has exited
rreader=$!
PATH="$work/bin:$PATH" setsid env FAKE_SSH_HOSTS_DIR="$work/hosts" FAKE_SSH_SLOW_HOSTS=redbaron \
  FAKE_SSH_DETACH_HOSTS=redbaron FAKE_SSH_REMOTE_STDERR="$work/remote-err" FAKE_SSH_LOG="$work/ssh.log" TOKEN_LEDGER_BIN="$TL" \
  TOKEN_LEDGER_HOSTS="carbon redbaron ryzen7" TOKEN_LEDGER_SSH_TIMEOUT=3 \
  "$TL" --since 2026-09-11T00:00:00Z --until 2026-09-12T00:00:00Z &
sid=$!
wait "$sid"; rc=$?
assert_eq "$rc" "0" "(3) the orchestrator exits 0 with one host over budget"
assert_eq "$(ledger_field 2026-09-11 7)" "redbaron" "(3) the slow host is marked missing"
assert_eq "$(ledger_field 2026-09-11 6)" "carbon,ryzen7" "(3) the day row names the hosts that answered"
# msg_c1 (carbon, weighted 10) + msg_y1 (ryzen7, weighted 40) = 50
assert_eq "$(ledger_field 2026-09-11 3)" "50" "(3) the day row carries carbon's and ryzen7's records"
assert_eq "$(survivors "$sid")" "" "(3) nothing of the orchestrator's own tree survives"
rsid="$(awk -F'\t' '$1=="redbaron"{print $2}' "$work/ssh.log")"
assert_eq "$(awk -F'\t' '$1=="redbaron"{print $3}' "$work/ssh.log")" "TOKEN_LEDGER_EMIT_DEADLINE=3" \
  "(3) the remote got the orchestrator's SSH_TIMEOUT as TOKEN_LEDGER_EMIT_DEADLINE"
assert_eq "$(awk -F'\t' '$1=="ryzen7"{print $3}' "$work/ssh.log")" "TOKEN_LEDGER_EMIT_DEADLINE=3" "(3) every remote gets the same deadline"
grep -q 'TOKEN_LEDGER_EMIT_DEADLINE=3' "$work/ssh.log" || pkill -KILL -s "$rsid"   # no deadline: end it here rather than hang
wait "$rreader"
assert "grep -qE '\(exit 7[46]\)\$' '$work/remote-err.txt'" "(3) the detached remote emit ended by itself (parent gone or deadline): $(cat "$work/remote-err.txt")"
assert_eq "$(survivors "$rsid")" "" "(3) nothing of the detached remote emit survives"

# --- (4) output equivalence with the pre-A1733 extraction
"$FIXTURES/build-emit-tree.sh" "$work/tree"
TOKEN_LEDGER_JSONL_ROOT="$work/tree/jsonl" SEATS_TABLE="$work/tree/seats.tsv" TOKEN_LEDGER_AIDE_SIDS="$work/tree/aide-sids" \
  "$TL" --emit-local-records --since 2026-09-11T00:00:00Z | LC_ALL=C sort >"$work/tree.ndjson"
rc=${PIPESTATUS[0]}
assert_eq "$rc" "0" "(4) the emit over the equivalence tree exits 0"
LC_ALL=C sort "$FIXTURES/emit-tree.golden.ndjson" >"$work/golden.ndjson"
cmp -s "$work/golden.ndjson" "$work/tree.ndjson"
assert_eq "$?" "0" "(4) sorted records are byte-identical to the pre-A1733 binary's ($(wc -l <"$work/golden.ndjson" | tr -d ' ') records)"

exit "$fail"
