#!/usr/bin/env bash
# Every merge-gate rule id in mergegate.py must have a `# PRODUCER G<n>` line in fleet-merge.sh (a MISSING line counts as declared).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mg="${MERGEGATE_PY:-/mnt/data/jsy/tmp/a250/wm_decide/mergegate.py}"
[ -f "$mg" ] || { echo "FAIL gate-producer-contract: mergegate.py not found at $mg (set MERGEGATE_PY)" >&2; exit 1; }
gates="$(grep -oE 'fails\["G[0-9]+"\]' "$mg" | grep -oE 'G[0-9]+' | sort -u -V)"
[ -n "$gates" ] || { echo "FAIL gate-producer-contract: no gate ids found in $mg" >&2; exit 1; }
miss=0
for g in $gates; do
  if grep -qE "^# PRODUCER $g( |\$)" "$here/.local/bin/fleet-merge.sh"; then
    echo "PASS $g: $(grep -E "^# PRODUCER $g( |\$)" "$here/.local/bin/fleet-merge.sh" | cut -c1-90)"
  else
    echo "FAIL $g: no '# PRODUCER $g' line in fleet-merge.sh"; miss=1
  fi
done
[ "$miss" = 0 ] && echo "ALL PASS gate-producer-contract" || exit 1
