#!/usr/bin/env bash
# tests/seat-floor-probe.test.sh -- M9 mechanism 6 probe: one row per compact_boundary with the floor and per-source bytes, byte-offset cursor (second run reads nothing new,
# an appended boundary adds one row, a boundary still waiting for its first assistant call stays behind the cursor), seat-floor.json fields, alarms, timer has OnBootSec AND OnUnitActiveSec.
# Fixture: tests/fixtures/seat-floor/rb-3boundary.jsonl (synthetic); no network, no ssh, no live JSONL.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; P="$root/.local/bin/seat-floor-probe.sh"; FX="$root/tests/fixtures/seat-floor"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/sfp.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/jd"; cp "$FX/rb-3boundary.jsonl" "$T/jd/sid-rb.jsonl"
cat >"$T/stage.json" <<'J'
{"stage":0,"expected_p50":{"rb":40000}}
J
run() { SEATS_TSV="$FX/seats.tsv" JSONL_DIR="$T/jd" SEAT_FLOOR_DIR="$T/out" SEAT_FLOOR_STAGE_FILE="$T/stage.json" SEAT_FLOOR_NOW=$(date -u -d 2026-10-26T20:00:00Z +%s) bash "$P" 2>&1; }
out="$(run)"; rc=$?
[ "$rc" = 0 ]; chk "first run exits 0 ($out)" $?
rows=$(($(wc -l <"$T/out/seat-floor.tsv") - 1)); [ "$rows" = 3 ]; chk "3 boundaries -> 3 rows (got $rows)" $?
col() { awk -F'\t' -v n="$2" -v c="$1" 'NR>1 && NR==n+1{print $c}' "$T/out/seat-floor.tsv"; }
# columns: 1 ts 2 seat 3 trigger 4 pre 5 floor 6 cache_read 7 summary 8 hook 9 files 10 files_n 11 max_path 12 instr 13 skill 14 cancelled
[ "$(col 5 1)" = 40002 ] && [ "$(col 5 2)" = 41002 ] && [ "$(col 5 3)" = 45002 ]; chk "floor = input + cache_read + cache_creation" $?
[ "$(col 7 1)" = 2000 ] && [ "$(col 8 1)" = 400 ] && [ "$(col 9 1)" = 1200 ] && [ "$(col 10 1)" = 2 ] && [ "$(col 11 1)" = /x/big.md ] && [ "$(col 12 1)" = 1000 ] && [ "$(col 13 1)" = 500 ] && [ "$(col 14 1)" = 1 ]; chk "row 1 per-source bytes, largest re-attached path, hook_cancelled" $?
[ "$(col 4 1)" = 150000 ] && [ "$(col 2 1)" = rb ]; chk "preTokens + seat recorded" $?
[ "$(cat "$T/out/rb.cursor")" = "$(stat -c %s "$T/jd/sid-rb.jsonl")" ]; chk "cursor = end of file after a complete scan" $?
run >/dev/null; [ "$(($(wc -l <"$T/out/seat-floor.tsv") - 1))" = 3 ]; chk "second run adds no rows (cursor)" $?
# a boundary with no assistant call yet stays behind the cursor, then completes
size0=$(stat -c %s "$T/jd/sid-rb.jsonl")
printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-27T05:00:00.000Z","compactMetadata":{"trigger":"auto","preTokens":112000}}' >>"$T/jd/sid-rb.jsonl"
run >/dev/null; [ "$(($(wc -l <"$T/out/seat-floor.tsv") - 1))" = 3 ] && [ "$(cat "$T/out/rb.cursor")" = "$size0" ]; chk "pending boundary: no row yet, cursor held at its start" $?
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-27T05:00:05.000Z","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3}}}' >>"$T/jd/sid-rb.jsonl"
run >/dev/null; [ "$(($(wc -l <"$T/out/seat-floor.tsv") - 1))" = 4 ] && [ "$(col 5 4)" = 6 ]; chk "boundary completes on its first assistant call -> row 4" $?
# json summary + alarms: last 5 p50 over 4 rows = sorted[2] ; expected 40000 + 5000 = 45000
j="$T/out/seat-floor.json"
[ "$(jq -r '.seats.rb.floor_last' "$j")" = 6 ] && [ "$(jq -r '.seats.rb.n' "$j")" = 4 ] && [ "$(jq -r '.seats.rb.floor_p50' "$j")" = 41002 ]; chk "seat-floor.json: floor_last, n, floor_p50 of the last 5" $?
[ "$(jq -r '.seats.rb.compact_hook_cancelled_24h' "$j")" = 1 ]; chk "compact_hook_cancelled_24h counts the 10-26 01:00Z cancellation (now = 10-26 20:00Z)" $?
jq -e '.seats | has("aide") | not' "$j" >/dev/null; chk "aide (sid -) is not probed" $?
# seat-floor-high needs 3 floors above expected+5000
cat >"$T/stage.json" <<'J'
{"stage":0,"expected_p50":{"rb":10000}}
J
run >/dev/null; jq -e '.alarms | map(.alarm) | index("seat-floor-high") != null' "$j" >/dev/null; chk "seat-floor-high fires when floor_p50 > expected_p50 + 5000" $?
jq -e '.alarms | map(.alarm) | index("seat-compact-hook-cancelled") != null' "$j" >/dev/null; chk "seat-compact-hook-cancelled fires on a cancellation in 24 h" $?
# a first run on a big tail never reads the whole file: backfill window
rm -rf "$T/out2"; SEATS_TSV="$FX/seats.tsv" JSONL_DIR="$T/jd" SEAT_FLOOR_DIR="$T/out2" SEAT_FLOOR_STAGE_FILE="$T/stage.json" SEAT_FLOOR_BACKFILL_BYTES=600 bash "$P" >/dev/null 2>&1
r2=$(($(wc -l <"$T/out2/seat-floor.tsv") - 1)); [ "$r2" -lt 4 ] && [ "$r2" -ge 1 ]; chk "backfill window bounds the first read ($r2 of 4 rows)" $?
# timer: both start triggers
tm="$root/.config/systemd/user/seat-floor-probe.timer"
grep -q '^OnBootSec=' "$tm" && grep -q '^OnUnitActiveSec=10min' "$tm" && [ -f "$root/.config/systemd/user/seat-floor-probe.service" ]; chk "timer has OnBootSec and OnUnitActiveSec=10min; service present" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
