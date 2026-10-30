#!/usr/bin/env bash
# ctl 8898 (10-30): the stall note keys on the active step. Replays run 506 at 2:29 AM 10-30 (gate child live, coder jsonl 46 min,
# CPU moving) and expects NOT a stall; a gate with flat CPU+IO says NO PROGRESS, never "redrive from inner"; a coder step with a 46-min jsonl stays STALLED.
S=${1:-$HOME/.local/bin/r7-mon-journal.sh}
out=$(bash "$S" --stall-selftest 2>&1); rc=$?
echo "$out"
[ $rc = 0 ] && grep -q 'REPLAY-506 gate LIVE' <<<"$out" && echo "PASS r7-mon-journal-stall" || { echo "FAIL r7-mon-journal-stall rc=$rc"; exit 1; }
