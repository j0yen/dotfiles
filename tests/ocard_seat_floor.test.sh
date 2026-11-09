#!/usr/bin/env bash
# tests/ocard_seat_floor.test.sh -- M9 mechanism 6: the operator card prints a `floor (p50 last 5)` line from seat-floor.json (OPERATOR_SEAT_FLOOR), with hook-cancel counts and the stage;
# silent when the file is absent. Fixture status.json via OPERATOR_CACHE_DIR with a fresh mtime and a no-op generator; no network.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; CARD="$root/.claude/scripts/operator-status-card.sh"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ocf.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/cache"; echo '{"host":"carbon","sources":{},"runs":[],"config":{}}' >"$T/cache/status.json"; printf '#!/bin/sh\nexit 0\n' >"$T/gen"; chmod +x "$T/gen"
echo '{"stage":0,"seats":{"ctl":{"floor_p50":62428,"compact_hook_cancelled_24h":3},"rb":{"floor_p50":49730,"compact_hook_cancelled_24h":0},"r7":{"floor_p50":null}}}' >"$T/sf.json"
card() { env -i PATH="$PATH" HOME="$T" OPERATOR_CACHE_DIR="$T/cache" OPERATOR_GEN="$T/gen" OPERATOR_FLEET_STATUS="$T/none" OPERATOR_SEAT_FLOOR="$T/sf.json" bash "$CARD" "$@"; }
out="$(card)"; printf '%s\n' "$out" | grep -q '^floor (p50 last 5): ctl 62.4K (3 hook cancels 24h) · rb 49.7K · r7 ? · stage 0$'; chk "full card prints the floor line" $?
out="$(card --section floor)"; [ "$out" = "floor (p50 last 5): ctl 62.4K (3 hook cancels 24h) · rb 49.7K · r7 ? · stage 0" ]; chk "--section floor prints just the line" $?
out="$(env -i PATH="$PATH" HOME="$T" OPERATOR_CACHE_DIR="$T/cache" OPERATOR_GEN="$T/gen" OPERATOR_FLEET_STATUS="$T/none" OPERATOR_SEAT_FLOOR="$T/absent.json" bash "$CARD")"; ! printf '%s\n' "$out" | grep -q '^floor'; chk "no seat-floor.json: no floor line" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
