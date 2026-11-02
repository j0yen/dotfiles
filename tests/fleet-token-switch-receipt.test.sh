#!/usr/bin/env bash
# tests/fleet-token-switch-receipt.test.sh -- fleet-token-switch-receipt.sh with stub bell/ask and a fake token.json + place.log; no host is touched.
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
h="$root/.local/bin/fleet-token-switch-receipt.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
export FLEET_DASH_DIR="$t/dash" FLEET_TOKEN_STATE_DIR="$t/state" FLEET_TOKEN_BELL_CMD="$t/bell" FLEET_TOKEN_ASK_CMD="$t/ask"
mkdir -p "$FLEET_DASH_DIR" "$FLEET_TOKEN_STATE_DIR"
printf '#!/bin/sh\necho "$2" >> "%s/inbox"\n' "$t" >"$t/bell"
printf '#!/bin/sh\necho "$@" >> "%s/ask.rec"\n' "$t" >"$t/ask"
chmod +x "$t/bell" "$t/ask"
NOW=1793532000
export FLEET_TOKEN_SWITCH_NOW_EPOCH=$NOW
tok() { printf '{"account":"%s","placed_at":"%s"}\n' "$1" "$(date -d "@$2" -Iseconds)" >"$FLEET_DASH_DIR/token.json"; }
placelog() { printf 'redbaron placed verify=OK\nryzen7 placed verify=OK\norch placed verify=OK\ncarbon placed verify=OK\n' >"$FLEET_TOKEN_STATE_DIR/place.log"; }
reset() { rm -f "$t/inbox" "$FLEET_DASH_DIR/ctl-events.log"; }
nalarm() { grep -c 'ALARM fleet-token' "$FLEET_DASH_DIR/ctl-events.log" 2>/dev/null || true; }
# 1 stub exit 64 -> FAILED rc=64, no DONE, one ALARM
reset; tok acctA $((NOW-10)); placelog
bash "$h" acctB 03:20 64 >/dev/null 2>&1 && rc=0 || rc=$?
grep -q 'fleet account switch 03:20: FAILED rc=64 (usage)' "$t/inbox" && ! grep -q DONE "$t/inbox" && [ "$(nalarm)" = 1 ] && [ "$rc" = 1 ] && grep -q 'FAILED rc=64' "$FLEET_DASH_DIR/ctl-events.log" && ok "rc 64: FAILED rc=64 (usage), no DONE, one ALARM, also in ctl-events" || bad "rc 64"
# 2 rc 0 but token.json unchanged -> FAILED (verify)
reset; tok acctA $((NOW-10)); placelog
bash "$h" acctB 03:20 0 >/dev/null 2>&1 && rc=0 || rc=$?
grep -q 'FAILED rc=0 (verify)' "$t/inbox" && ! grep -q DONE "$t/inbox" && [ "$(nalarm)" = 1 ] && ok "rc 0, token.json unchanged: FAILED (verify)" || bad "unchanged"
# 3 rc 0, account right but placed_at stale -> FAILED (verify)
reset; tok acctB $((NOW-600)); placelog
bash "$h" acctB 03:20 0 >/dev/null 2>&1 || true
grep -q 'FAILED rc=0 (verify)' "$t/inbox" && ok "stale placed_at: FAILED (verify)" || bad "stale"
# 4 rc 0, host missing from place log -> FAILED (place)
reset; tok acctB $((NOW-10)); printf 'redbaron verify=OK\nryzen7 verify=OK\n' >"$FLEET_TOKEN_STATE_DIR/place.log"
bash "$h" acctB 03:20 0 >/dev/null 2>&1 || true
grep -q 'FAILED rc=0 (place)' "$t/inbox" && ok "orch absent from place log: FAILED (place)" || bad "place log"
# 5 all true -> DONE, no ALARM
reset; tok acctB $((NOW-10)); placelog
bash "$h" acctB 03:20 0 >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && grep -q 'fleet account switch 03:20: DONE acctB on 4 hosts' "$t/inbox" && ! grep -q FAILED "$t/inbox" && [ "$(nalarm)" = 0 ] && grep -q DONE "$FLEET_DASH_DIR/ctl-events.log" && ok "all true: DONE line to inbox + ctl-events, no ALARM" || bad "done"
# 6 --arm files the P row with due +3 min and the done-check
NOW=$(date -d "2026-11-01 03:20:00" +%s); export FLEET_TOKEN_SWITCH_NOW_EPOCH=$NOW
bash "$h" acctB 03:20 0 --arm >/dev/null 2>&1
grep -q -- "--due 03:23 --done-check token.json .account == acctB" "$t/ask.rec" && ok "--arm: seat-ask --due 03:23 --done-check 'token.json .account == acctB'" || bad "arm ($(cat "$t/ask.rec" 2>/dev/null))"
bash "$h" acctB 3:20 0 >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 64 ] && ok "bad time: exit 64" || bad "bad time rc=$rc"
[ "$fail" = 0 ] && echo "OK fleet-token-switch-receipt" || echo "NOT OK fleet-token-switch-receipt"
exit "$fail"
