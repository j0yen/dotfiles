#!/usr/bin/env bash
# five-whys G1 (11-06): the Stop hook lets a turn end only when ctl-event-bridge.service is ACTIVE and status.json ts is < 10 min old.
# RED shape = unit inactive + wake-armed lease in the future (the 8:26 PM incident); GREEN = unit active + fresh status.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
H="${AIDE_WAKE_STOP_HOOK:-$here/.claude/hooks/aide-wake-stop.sh}"; W="$here/.local/bin/aide-wake.sh"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/state" "$t/ev"
printf '#!/bin/sh\n[ "$1" = --user ] && [ "$2" = is-active ] && echo "$(cat %s/unit)"; exit 0\n' "$t" > "$t/systemctl"; chmod +x "$t/systemctl"
export AIDE_SYSTEMCTL_BIN="$t/systemctl" AIDE_BRIDGE_STATUS="$t/status.json" AIDE_WAKE_DIR="$t/state" EVENTS_DIR="$t/ev" AIDE_WAKE_BIN="$W" OWED_NOW_BIN="$t/none"
echo "line" > "$t/ev/aide-events.log"                       # pending work
echo $(( $(date +%s) + 1800 )) > "$t/state/wake-armed"      # lease in the future
run() { echo '{}' | env WM_SEAT=ctl "$@" "$H"; }
fresh() { printf '{"ts": "%s"}' "$(date -d "-$1 sec" -Iseconds)" > "$t/status.json"; }
echo inactive > "$t/unit"; fresh 5
out="$(run)"; jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && grep -q 'not active' <<<"$out" && ok "RED: unit inactive + future lease -> block" || bad "RED: unit inactive + future lease -> block"
out="$(run WM_DIRECTOR=hermes)"; grep -q 'report-not-block' <<<"$out" && ok "hermes director: report-not-block with reason" || bad "hermes director: report-not-block"
echo active > "$t/unit"; fresh 5
out="$(run)"; [ -z "$out" ] && ok "GREEN: unit active + fresh status -> allow" || bad "GREEN: unit active + fresh status -> allow"
fresh 900
out="$(run)"; jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && grep -q 'older than' <<<"$out" && ok "unit active + status 15 min old -> block" || bad "stale status -> block"
rm -f "$t/status.json"; out="$(run)"; jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1 && ok "missing status.json -> block" || bad "missing status -> block"
rm -f "$t/state/wake-armed"; echo active > "$t/unit"; fresh 5; out="$(run)"; [ -z "$out" ] && ok "no lease needed when unit active" || bad "no lease needed"
exit $fail
