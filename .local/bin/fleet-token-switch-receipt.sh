#!/usr/bin/env bash
# fleet-token-switch-receipt.sh <account> <HH:MM> <rotate_rc> [--arm]   (A379, M3 of the 2026-11-01 jyen.pm drain five-whys)
# Receipt of a scheduled fleet account switch, composed from host truth AFTER the switch, never before it.
#   default (last step of the fleet-token-switch-at unit): <rotate_rc> is the exit code of fleet-token-rotate.sh.
#     rc != 0 -> FAILED rc=<n> (usage|place|verify): 64 = usage, 3 = place, 1/2 = verify, other = place
#     rc == 0 -> read token.json (.account == <account> and .placed_at within 180 s) and $FT_STATE/place.log (a line naming each of
#                redbaron ryzen7 orch with verify=OK); any miss -> FAILED rc=0 (verify)
#     all true -> `fleet account switch <HH:MM>: DONE <account> on 4 hosts`
#     Either line goes to the aide inbox (seat-event.sh aide) and ctl-events.log; a FAILED line also raises one ft_alarm (ALARM). Exit 0 DONE, 1 FAILED.
#   --arm: files the follow-up P row at arm time: seat-ask.sh rb --due <HH:MM+3> --done-check 'token.json .account == <account>'. Exit 0.
# Env (injectable): FLEET_DASH_DIR FLEET_TOKEN_STATE_DIR FLEET_TOKEN_SWITCH_NOW_EPOCH FLEET_TOKEN_SWITCH_HOSTS FLEET_TOKEN_BELL_CMD FLEET_TOKEN_ASK_CMD
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
ft_paths
usage() { echo 'usage: fleet-token-switch-receipt.sh <account> <HH:MM> <rotate_rc> [--arm]' >&2; exit 64; }
[ $# -ge 3 ] || usage
acct="$1" hhmm="$2" rc="$3" arm="${4:-}"
ft_valid_account "$acct" || usage
[[ "$hhmm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || usage
[[ "$rc" =~ ^[0-9]+$ ]] || usage
now="${FLEET_TOKEN_SWITCH_NOW_EPOCH:-$(date +%s)}"
if [ "$arm" = "--arm" ]; then
  due="$(date -d "@$(( $(date -d "$(date -d "@$now" +%Y-%m-%d) $hhmm:00" +%s) + 180 ))" +%H:%M)"
  ${FLEET_TOKEN_ASK_CMD:-seat-ask.sh} rb "fleet account switch $hhmm to $acct: read host truth" --due "$due" --done-check "token.json .account == $acct" >/dev/null
  exit 0
fi
[ -z "$arm" ] || usage
bell() { ${FLEET_TOKEN_BELL_CMD:-seat-event.sh} aide "$1" || true
         mkdir -p "$FT_DASH"; printf '%s | fleet-token | %s\n' "$(ft_iso)" "$1" >>"$FT_DASH/ctl-events.log"; }
failed() { bell "fleet account switch $hhmm: FAILED rc=$rc ($1)"; ft_alarm "scheduled switch to $acct at $hhmm FAILED rc=$rc ($1)"; exit 1; }
if [ "$rc" != 0 ]; then
  case "$rc" in 64) failed usage ;; 3) failed place ;; 1|2) failed verify ;; *) failed place ;; esac
fi
placed="$(jq -r '.placed_at // empty' "$FT_TOKJSON" 2>/dev/null || true)"
pe="$(date -d "$placed" +%s 2>/dev/null || true)"
[ "$(ft_current)" = "$acct" ] && [ -n "$pe" ] && [ $(( now - pe )) -ge 0 ] && [ $(( now - pe )) -le 180 ] || failed verify
pl="$FT_STATE/place.log"
for h in ${FLEET_TOKEN_SWITCH_HOSTS:-redbaron ryzen7 orch}; do
  grep -Eqi "(^|[^a-z0-9])$h([^a-z0-9]|$).*verify=ok" "$pl" 2>/dev/null || failed place
done
bell "fleet account switch $hhmm: DONE $acct on 4 hosts"
