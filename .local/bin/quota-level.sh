#!/usr/bin/env bash
# quota-level.sh -- read-only quota governor: computes quota.level L0..L3 and writes it for the fleet-dash collector (status.json quota.level) + one alarm per change.
# It never throttles, never sets a cap, never touches max_runs or open runs (caps R002: the governor may alarm, it does not limit).
# Inputs: READINGS tsv (epoch<TAB>account<TAB>used_pct<TAB>resets_epoch; last line wins, Joe's readings anchor) and the seat tick files *-tick.json (quota_wait_until).
#   pace = used_pct / elapsed_pct of the 7-day window ending at resets_epoch.
#   L3 = a seat is parked in a quota wait, or pace >= 1.5 or used >= 95; L2 = pace >= 1.25; L1 = pace >= 1.0; else L0. No reading and no wait = L0.
# Output: $QL_OUT (quota-level.json {level, pace, used_pct, account, resets_epoch, waiting_seats, since}) rewritten ONLY when the level changes;
#   a change appends `ALARM quota.level Lx` via QL_ALARM_CMD (default: seat-event.sh ctl).
# Env: FLEET_DASH_DIR QL_READINGS QL_OUT QL_ALARM_CMD QL_NOW (fake clock). Usage: quota-level.sh [--selftest]
set -euo pipefail
set +x

compute() {
  local D="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}" READINGS="${QL_READINGS:-$HOME/.config/fleet-token/readings.tsv}"
  local now r_ep acct used resets el pace waiting level f w seats=""
  now="${QL_NOW:-$(date +%s)}"
  acct=""; used=""; resets=""; pace=""
  if [ -r "$READINGS" ]; then
    IFS=$'\t' read -r r_ep acct used resets < <(grep -v '^#' "$READINGS" | awk 'NF>=4' | tail -n1) || true
  fi
  if [[ "${used:-}" =~ ^[0-9]+(\.[0-9]+)?$ && "${resets:-}" =~ ^[0-9]+$ ]] && [ "$resets" -gt "$now" ]; then
    pace="$(awk -v u="$used" -v r="$resets" -v n="$now" 'BEGIN{e=1-(r-n)/604800; if(e<0.05)e=0.05; if(e>1)e=1; printf "%.2f", u/(e*100)}')"
  else
    used=""; pace=""
  fi
  for f in "$D"/*-tick.json; do
    [ -f "$f" ] || continue
    w="$(jq -r '.quota_wait_until // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$w" =~ ^[0-9]+$ ]] || w=0
    if [ "$w" -gt "$now" ]; then seats="$seats$(basename "$f" -tick.json) "; fi
  done
  seats="${seats% }"
  level=0
  if [ -n "$pace" ]; then
    awk -v p="$pace" 'BEGIN{exit !(p>=1.0)}' && level=1
    awk -v p="$pace" 'BEGIN{exit !(p>=1.25)}' && level=2
    awk -v p="$pace" -v u="$used" 'BEGIN{exit !(p>=1.5||u>=95)}' && level=3
  fi
  [ -z "$seats" ] || level=3
  jq -cn --argjson l "$level" --arg p "${pace:-}" --arg u "${used:-}" --arg a "${acct:-}" --arg r "${resets:-}" --arg s "$seats" --argjson now "$now" \
    '{level:$l, pace:($p|if .=="" then null else tonumber end), used_pct:($u|if .=="" then null else tonumber end), account:($a|if .=="" then null else . end),
      resets_epoch:($r|if .=="" then null else tonumber end), waiting_seats:($s|split(" ")|map(select(length>0))), since:$now}'
}

run() {
  local OUT="${QL_OUT:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}/quota-level.json}"
  local new old_level new_level tmp ALARM="${QL_ALARM_CMD:-$HOME/.local/bin/seat-event.sh ctl}"
  new="$(compute)"
  new_level="$(jq -r .level <<<"$new")"
  old_level="$(jq -r '.level // empty' "$OUT" 2>/dev/null || true)"
  [ "$old_level" != "$new_level" ] || return 0
  mkdir -p "$(dirname "$OUT")"; tmp="$OUT.tmp.$$"
  printf '%s\n' "$new" >"$tmp" && mv "$tmp" "$OUT"
  # shellcheck disable=SC2086
  $ALARM "ALARM quota.level L${new_level} (was ${old_level:-none}): $(jq -c '{pace,used_pct,waiting_seats}' <<<"$new")" || true
}

selftest() {
  local t fails=0; t="$(mktemp -d)"
  export FLEET_DASH_DIR="$t" QL_READINGS="$t/readings.tsv" QL_OUT="$t/quota-level.json" QL_NOW=1000000
  export QL_ALARM_CMD="$t/alarm.sh"; printf '#!/bin/sh\necho "$*" >>%s/alarms\n' "$t" >"$t/alarm.sh"; chmod +x "$t/alarm.sh"
  want() { local got; got="$(jq -r .level "$QL_OUT")"; if [ "$got" = "$1" ]; then echo "PASS $2"; else echo "FAIL $2 (got $got want $1)"; fails=1; fi; }
  run; want 0 "no reading, no wait -> L0"
  # half the window elapsed: resets = now + 302400
  printf 'x\tacct\t40\t%s\n' $((QL_NOW+302400)) >"$QL_READINGS"; run; want 0 "40 % used at 50 % elapsed -> L0 (pace 0.8)"
  printf 'x\tacct\t55\t%s\n' $((QL_NOW+302400)) >"$QL_READINGS"; run; want 1 "55 % at 50 % -> L1"
  printf 'x\tacct\t65\t%s\n' $((QL_NOW+302400)) >"$QL_READINGS"; run; want 2 "65 % at 50 % -> L2"
  printf 'x\tacct\t80\t%s\n' $((QL_NOW+302400)) >"$QL_READINGS"; run; want 3 "80 % at 50 % -> L3"
  local n; n="$(wc -l <"$t/alarms")"
  run; [ "$(wc -l <"$t/alarms")" = "$n" ] && echo "PASS unchanged level: no new alarm" || { echo "FAIL repeat alarm"; fails=1; }
  local m; m="$(stat -c %Y "$QL_OUT")"; sleep 1; run; [ "$(stat -c %Y "$QL_OUT")" = "$m" ] && echo "PASS file written only on change" || { echo "FAIL rewrite"; fails=1; }
  printf 'x\tacct\t10\t%s\n' $((QL_NOW+302400)) >"$QL_READINGS"; run; want 0 "back to L0"
  echo '{"quota_wait_until":'$((QL_NOW+600))'}' >"$t/rb-tick.json"; run; want 3 "a seat in quota wait -> L3"
  [ "$(jq -r '.waiting_seats[0]' "$QL_OUT")" = rb ] && echo "PASS waiting seat named" || { echo "FAIL seat name"; fails=1; }
  grep -q 'ALARM quota.level L3' "$t/alarms" && echo "PASS alarm text" || { echo "FAIL alarm text"; fails=1; }
  rm -rf "$t"
  [ "$fails" = 0 ] && echo "SELFTEST PASS" || { echo "SELFTEST FAIL"; return 1; }
}

case "${1:-}" in
  --selftest) selftest ;;
  "") run ;;
  *) echo "usage: quota-level.sh [--selftest]" >&2; exit 64 ;;
esac
