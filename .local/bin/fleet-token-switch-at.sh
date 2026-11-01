#!/usr/bin/env bash
# fleet-token-switch-at.sh <account> <HH:MM> [--by joe-<date>] [--dry-run]
# Arms ONE transient user timer unit (fleet-token-switch-at-<HHMM>) that runs, in order, at the next HH:MM (today, else tomorrow):
#   1. fleet account switch: fleet-token-rotate.sh <account> --by <by> --trigger joe-<HHMM>
#   2. aide account switch:  aide-relaunch.sh <account> joe-switch-at-<HHMM> (account = required first argument, same account as step 1; the rest is the free-text reason)
# Runs `fleet-token-rotate.sh --check <argv>` first and refuses to arm (exit = its rc, nothing armed) when it is non-zero.
# Refuses with exit 2, arming nothing, when fleet-token-rotate.sh or aide-relaunch.sh cannot be found. --dry-run prints the systemd-run command only.
# Exit: 0 armed / dry-run printed, 2 a step's script is absent, 64 usage.
set -euo pipefail
set +x
usage() { echo 'usage: fleet-token-switch-at.sh <account> <HH:MM> [--by joe-<date>] [--dry-run]' >&2; exit 64; }
acct="" hhmm="" by="" dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --by) by="${2:-}"; [ $# -ge 2 ] || usage; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) usage ;;
    *) if [ -z "$acct" ]; then acct="$1"; elif [ -z "$hhmm" ]; then hhmm="$1"; else usage; fi; shift ;;
  esac
done
[[ "$acct" =~ ^[A-Za-z0-9._@-]+$ ]] || usage
[[ "$hhmm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || usage
[ -n "$by" ] || by="joe-$(date +%Y%m%d)"
[[ "$by" =~ ^joe-[0-9A-Za-z:._-]+$ ]] || usage
tag="${hhmm/:/}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rotate="$here/fleet-token-rotate.sh"
if [ ! -x "$rotate" ]; then rotate="$(command -v fleet-token-rotate.sh || true)"; fi
relaunch="$(command -v aide-relaunch.sh || true)"
if [ -z "$relaunch" ] && [ -x "$here/aide-relaunch.sh" ]; then relaunch="$here/aide-relaunch.sh"; fi
[ -n "$rotate" ] || { echo "fleet-token-switch-at: fleet account switch script fleet-token-rotate.sh not found; nothing armed" >&2; exit 2; }
[ -n "$relaunch" ] || { echo "fleet-token-switch-at: aide account switch script aide-relaunch.sh not found; nothing armed" >&2; exit 2; }
# arm-time execution of the exact fleet step argv: parse + store check, no placement; refuse to arm on rc != 0
if "${FLEET_TOKEN_ROTATE_CHECK_BIN:-$rotate}" --check "$acct" --by "$by" --trigger "joe-$tag" --armed-by fleet-token-switch-at; then :; else
  rc=$?; echo "fleet-token-switch-at: fleet account switch argv refused by 'fleet-token-rotate.sh --check' (rc=$rc); nothing armed" >&2; exit "$rc"
fi
day="$(date +%Y-%m-%d)"
if [ "$(date +%s)" -ge "$(date -d "$day $hhmm:00" +%s)" ]; then day="$(date -d 'tomorrow' +%Y-%m-%d)"; fi
cal="$day $hhmm:00"
unit="fleet-token-switch-at-$tag"
cmd=(systemd-run --user --on-calendar="$cal" --unit="$unit" --collect
     /usr/bin/env bash -c 'set -e; "$1" "$2" --by "$3" --trigger "$4" --armed-by fleet-token-switch-at && echo "fleet account switch done"; "$5" "$2" "$6" && echo "aide account switch done"' fleet-token-switch-at
     "$rotate" "$acct" "$by" "joe-$tag" "$relaunch" "joe-switch-at-$tag")
if [ "$dry" = 1 ]; then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
"${cmd[@]}"
echo "armed $unit for $cal: fleet account switch to $acct (by $by), then aide account switch"
