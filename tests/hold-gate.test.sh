#!/usr/bin/env bash
# tests/hold-gate.test.sh -- hold-gate.sh (hermes-handover 2.4): one shared HOLD.json read in every spawner.
# Isolation: HOME is a mktemp dir holding a symlink to the repo's hold-gate.sh; WM_HOLD_JSON points at a fixture, never the real HOLD.json.
# Run: bash tests/hold-gate.test.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; bin="$root/.local/bin"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.local/bin" "$HOME/.claude/state" "$HOME/.cache" "$HOME/.local/state" "$HOME/.config"
ln -s "$bin/hold-gate.sh" "$HOME/.local/bin/hold-gate.sh"
unset WM_SEAT WM_AIDE_LANE
printf 'ctl\tticker\tsid-x\t20\t600\t-\t1\t-\n' >"$HOME/.claude/state/seats.tsv"
export SEATS_TABLE="$HOME/.claude/state/seats.tsv"
F="$T/HOLD.json"; export WM_HOLD_JSON="$F"
cat >"$F" <<'JSON'
{"reason": "fixture hold: stop most activities and preserve reserve", "preserved": ["dashboard", "Caller:Seat-Tick:x ", "backups"]}
JSON
G="$bin/hold-gate.sh"; ST="$bin/seat-tick.sh"

# (a) HOLD present: seat-tick exits 1 with the gate line, before any seat work
err="$(bash "$ST" fakeseat 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && [[ "$err" == *"hold-gate: HOLD blocks seat-tick:fakeseat (fixture hold: stop most"* ]] && [[ "$err" == *"file=$F"* ]]; chk "a: seat-tick.sh exits 1 under HOLD.json with the hold-gate: HOLD line" $?
# the gate applies to --ask and --event too, not to read-only --status
bash "$ST" fakeseat --event >/dev/null 2>&1; [ $? = 1 ]; chk "a2: seat-tick.sh --event exits 1 under HOLD" $?
err="$(bash "$ST" fakeseat --status 2>&1)"; [[ "$err" != *"hold-gate"* ]]; chk "a3: seat-tick.sh --status is not gated" $?
# other gated callers refuse before doing anything
bash "$bin/ctl-relaunch.sh" nosuchacct >/dev/null 2>"$T/e"; [ $? = 1 ] && grep -q 'hold-gate: HOLD blocks ctl-relaunch' "$T/e"; chk "a4: ctl-relaunch.sh exits 1 under HOLD" $?

# (b) no HOLD file: the gate is silent exit 0 and seat-tick runs past it (stops at the unknown-seat check, exit 64)
mv "$F" "$F.off"
out="$(bash "$G" seat-tick:fakeseat 2>&1)"; rc=$?; [ "$rc" = 0 ] && [ -z "$out" ]; chk "b: hold-gate.sh exits 0, silent, without the HOLD file" $?
err="$(bash "$ST" fakeseat 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 64 ] && [[ "$err" == *"unknown seat 'fakeseat'"* ]] && [[ "$err" != *"hold-gate"* ]]; chk "b2: seat-tick.sh proceeds past the gate without HOLD (reaches the seat lookup, exit 64)" $?
mv "$F.off" "$F"

# (c) preserved match
bash "$G" seat-tick:x >/dev/null 2>&1; chk "c: preserved entry 'caller:seat-tick:x' (case/space-insensitive) exits 0" $?
bash "$G" DASHBOARD >/dev/null 2>&1; chk "c2: bare preserved entry matches case-insensitively" $?
bash "$G" seat-tick:y >/dev/null 2>&1; [ $? = 1 ]; chk "c3: a non-preserved caller exits 1" $?

# (d) unparseable file is a HOLD
echo '{ not json' >"$F"
err="$(bash "$G" seat-tick:x 2>&1 >/dev/null)"; rc=$?; [ "$rc" = 1 ] && [[ "$err" == *"(unparseable)"* ]]; chk "d: unparseable HOLD.json exits 1 (never fails open)" $?
echo '{"reason":"r"}' >"$F"
bash "$G" seat-tick:x >/dev/null 2>&1; [ $? = 1 ]; chk "d2: HOLD.json without a preserved list exits 1" $?

# explain is read-only
echo '{"reason":"r","preserved":["a"]}' >"$F"
out="$(bash "$G" --explain)"; rc=$?; [ "$rc" = 0 ] && [[ "$out" == *"$F"* ]] && [[ "$out" == *'["a"]'* ]]; chk "e: --explain prints the path and preserved list, exit 0" $?

# seat-event: log append survives the hold; wake is skipped
E="$T/ev"; mkdir -p "$E"
out="$(EVENTS_DIR="$E" SEAT_EVENT_DRY=1 bash "$bin/seat-event.sh" ctl "hold probe line" 2>"$T/e2")"; rc=$?
[ "$rc" = 0 ] && grep -q 'hold probe line' "$E/ctl-events.log" 2>/dev/null && ! grep -q systemd-run <<<"$out"; chk "f: seat-event.sh appends the receipt line and skips the wake under HOLD" $?

[ "$fail" = 0 ] && echo "ALL PASS hold-gate.test.sh" || echo "SOME FAIL hold-gate.test.sh"
exit "$fail"
