#!/usr/bin/env bash
# A1235 / foundation 5796: keep wm-decide asks equal to open-asks.tsv (ctl is the sole writer). Idempotent import, then an id-set check; nonzero exit = drift.
set -u; L="${LEDGER:-$HOME/.cache/aide/open-asks.tsv}"
exec 9>"$L.lock"; flock -w 30 9 || exit 75
wm-decide asks import "$L" >/dev/null 2>&1 || { echo "ctl-asks-sync: import failed" >&2; exit 1; }
w="$(grep -v '^#' "$L" | cut -f1 | grep . | sort)"; h="$(wm-decide asks --tsv | grep -v '^#' | cut -f1 | grep . | sort)"
[ "$w" = "$h" ] || { echo "ctl-asks-sync: id sets differ after import" >&2; exit 1; }
echo "ctl-asks-sync: $(printf '%s\n' "$w" | wc -l) ids canonical"
