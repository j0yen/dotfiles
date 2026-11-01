#!/usr/bin/env bash
# fleet-token-schedule.sh -- the weekly rotation (fleet-token-schedule.timer, Fri 14:05 America/Los_Angeles, Persistent=true, carbon only).
# Rotates to the ONE account named in ${XDG_CONFIG_HOME:-~/.config}/fleet-token/schedule (first non-comment line) with `--trigger schedule`.
#   already current (token.json names it)  -> `no-op: <account> already current`, exit 0
#   schedule file missing/empty, or the store lacks the account -> ALARM (ctl-events.log), exit 1
#   the account is BLOCKED (blocked-until-<account> in the future, see fleet-token-lib.sh ft_block) -> ALARM `... skipped: blocked until <iso>`, nothing rotated, exit 1
#   otherwise -> exec fleet-token-rotate.sh <account> --by fleet-token-schedule --trigger schedule (its exit code is ours)
# Env: FLEET_TOKEN_ROTATE_CMD (default the sibling fleet-token-rotate.sh) and everything fleet-token-rotate.sh reads.
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

schedule() {
  local acct="" line cur blocked
  if [ -r "$FT_CFG/schedule" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      acct="$(printf '%s' "${line%%#*}" | tr -d '[:space:]')"
      [ -z "$acct" ] || break
    done <"$FT_CFG/schedule"
  fi
  if [ -z "$acct" ] || ! ft_valid_account "$acct"; then
    ft_alarm "weekly rotation: $FT_CFG/schedule is missing, empty or names an invalid account; nothing rotated"; return 1
  fi
  cur="$(ft_current)"
  if [ -n "$cur" ] && [ "$cur" = "$acct" ]; then echo "no-op: $acct already current"; return 0; fi
  if [ ! -f "$FT_STORE/$acct" ]; then
    ft_alarm "weekly rotation to '$acct' NOT done: no store entry (fleet-token-store.sh add $acct); current stays '${cur:-unknown}'"; return 1
  fi
  blocked="$(ft_block_reason "$acct" "$(ft_now)")"
  if [ -n "$blocked" ]; then
    ft_alarm "weekly rotation to '$acct' skipped: $blocked; current stays '${cur:-unknown}'"; return 1
  fi
  exec ${FLEET_TOKEN_ROTATE_CMD:-"$(dirname "$SELF")/fleet-token-rotate.sh"} "$acct" --by fleet-token-schedule --trigger schedule
}

selftest() {
  local T c=canary-tok-7f3e9a; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  ( set +e; ft_st_env "$T"; FT_ST_T="$T"
    local o="$T/out" e="$T/err" rc NOW=1790000000
    export FLEET_TOKEN_NOW_EPOCH=$NOW
    fl() { cat "$FAKE_LOG_DIR/$1.log" 2>/dev/null; }
    tokj() { jq -r "$1" "$FT_TOKJSON"; }
    runs() { "$SELF" >"$o" 2>"$e"; }
    ft_st_store acctA "$c"; ft_st_store acctB "$c-2"
    # 1. no schedule file
    runs; rc=$?
    [ "$rc" = 1 ] && grep -q 'ALARM fleet-token: weekly rotation: .*schedule is missing' "$FT_DASH/ctl-events.log" && [ -z "$(fl place)" ]; ft_st_chk "no schedule file: ALARM, exit 1, nothing placed" $?
    # 2. already current
    printf '# the Friday account\nacctA  # comment\n' >"$FT_CFG/schedule"
    "$(dirname "$SELF")/fleet-token-store.sh" current acctA >/dev/null
    : >"$FT_DASH/ctl-events.log"
    runs; rc=$?
    [ "$rc" = 0 ] && grep -qx 'no-op: acctA already current' "$o" && [ -z "$(fl place)" ] && [ -z "$(fl verify)" ] && [ -z "$(fl bell)" ] && [ ! -s "$FT_DASH/ctl-events.log" ]; ft_st_chk "already current: 'no-op: acctA already current', exit 0, no verify/place/bell/ALARM" $?
    # 3. missing store entry
    printf 'acctGone\n' >"$FT_CFG/schedule"
    runs; rc=$?
    [ "$rc" = 1 ] && grep -q "weekly rotation to 'acctGone' NOT done: no store entry" "$FT_DASH/ctl-events.log" && [ -z "$(fl place)" ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "missing store entry: ALARM, exit 1, nothing placed, token.json unchanged" $?
    # 4. rotates with --trigger schedule
    printf 'acctB\n' >"$FT_CFG/schedule"
    runs; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctB ] && [ "$(tokj .trigger)" = schedule ] && [ "$(tokj .by)" = fleet-token-schedule ] && [ "$(tokj .previous)" = acctA ] \
      && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 1 ] && [ "$(wc -l <"$FAKE_LOG_DIR/bell.log")" = 3 ] && [ "$(wc -l <"$FAKE_LOG_DIR/record.log")" = 1 ]; ft_st_chk "rotates: token.json acctB trigger=schedule by=fleet-token-schedule previous=acctA, 1 place, 3 bells, 1 row" $?
    # 5. a second (Persistent catch-up) run the same week is a no-op
    : >"$FAKE_LOG_DIR/place.log"
    runs; rc=$?
    [ "$rc" = 0 ] && grep -qx 'no-op: acctB already current' "$o" && [ ! -s "$FAKE_LOG_DIR/place.log" ]; ft_st_chk "run again (timer catch-up): no-op, nothing placed" $?
    # 6. the scheduled account fails its pre-verify: rotate's exit code surfaces
    ft_st_store acctBad "$c-bad"; printf 'acctBad\n' >"$FT_CFG/schedule"
    runs; rc=$?
    [ "$rc" = 2 ] && [ "$(tokj .account)" = acctB ]; ft_st_chk "pre-verify failure: exit 2 passed through, token.json unchanged" $?
    # 7. blocked-until: a scheduled account inside its block is skipped (ALARM, exit 1, nothing placed); an expired or garbled block is ignored
    printf 'acctA\n' >"$FT_CFG/schedule"; : >"$FT_DASH/ctl-events.log"; : >"$FAKE_LOG_DIR/place.log"
    ft_block acctA "$((NOW + 3600))" "weekly limit resets $(ft_la_iso "$((NOW + 3600))")"
    runs; rc=$?
    [ "$rc" = 1 ] && [ ! -s "$FAKE_LOG_DIR/place.log" ] && [ "$(tokj .account)" = acctB ] && grep -q "weekly rotation to 'acctA' skipped: blocked until $(ft_la_iso "$((NOW + 3600))")" "$FT_DASH/ctl-events.log"; ft_st_chk "schedule-blocked: scheduled account blocked -> ALARM 'skipped: blocked until <iso>', exit 1, nothing placed, token.json unchanged" $?
    export FLEET_TOKEN_NOW_EPOCH=$((NOW + 7200))
    runs; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctA ] && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 1 ]; ft_st_chk "schedule-expired: the block is in the past -> rotates to acctA" $?
    export FLEET_TOKEN_NOW_EPOCH=$NOW
    printf 'acctB\n' >"$FT_CFG/schedule"; printf 'garbage\n' >"$FT_STATE/blocked-until-acctB"; : >"$FAKE_LOG_DIR/place.log"
    runs; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctB ]; ft_st_chk "schedule-garbled: an unparseable blocked-until file is ignored (old behaviour) -> rotates" $?
    ft_unblock acctA; ft_block acctB "$((NOW + 3600))" "x"; printf 'acctA\n' >"$FT_CFG/schedule"; : >"$FT_DASH/ctl-events.log"
    runs; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "schedule-other: a block on a DIFFERENT account does not stop the scheduled rotation" $?
    printf 'acctB\n' >"$FT_CFG/schedule"; runs; rc=$?
    [ "$rc" = 1 ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "schedule-blocked again: rotating onto the blocked acctB is refused" $?
    ! grep -rqF "$c" "$o" "$e"; ft_st_chk "stdout/stderr carry no token" $?
    ft_st_done fleet-token-schedule
  ); return $?
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -eq 0 ] || { echo 'usage: fleet-token-schedule.sh  |  --selftest' >&2; exit 64; }
ft_paths
schedule
