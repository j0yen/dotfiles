#!/usr/bin/env bash
# tests/fleet_merge_hold_gate.test.sh -- fleet-merge.sh exits before any work while HOLD.json lacks `fleet-merge` in preserved (gate proof P2).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; fail=0
printf '#!/bin/sh\ntouch "%s/gh-called"\nexit 99\n' "$tmp" > "$tmp/gh"; chmod +x "$tmp/gh"
fleet_merge_hold_gate_blocks() {
  echo '{"reason":"t","preserved":["dashboard"]}' > "$tmp/hold.json"
  WM_HOLD_JSON="$tmp/hold.json" PATH="$tmp:$PATH" HOME="$tmp/h" bash "$here/.local/bin/fleet-merge.sh" >"$tmp/out" 2>&1; rc=$?
  [ $rc -eq 1 ] && grep -q 'hold-gate: HOLD blocks fleet-merge' "$tmp/out" && [ ! -e "$tmp/gh-called" ] && echo "ok - held: rc1, no gh" || { echo "NOT OK - held rc=$rc"; cat "$tmp/out"|head -3; fail=1; }
  echo '{"reason":"t","preserved":["fleet-merge"]}' > "$tmp/hold.json"; mkdir -p "$tmp/h"
  WM_HOLD_JSON="$tmp/hold.json" PATH="$tmp:$PATH" HOME="$tmp/h" timeout 20 bash "$here/.local/bin/fleet-merge.sh" >"$tmp/out2" 2>&1
  grep -q 'hold-gate: HOLD blocks' "$tmp/out2" && { echo "NOT OK - preserved still blocked"; fail=1; } || echo "ok - preserved passes the gate"
}
fleet_merge_hold_gate_blocks; [ $fail = 0 ] && echo ALL PASS; exit $fail
