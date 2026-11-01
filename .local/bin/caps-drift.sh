#!/usr/bin/env bash
# caps-drift.sh: host-side read of every enforced_at value in .config/fleet/caps.tsv (P28 mechanism 3).
# Stage 1 reports and alarms only; it never rewrites a host file. Logic: caps-drift.py (same directory).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
exec python3 -I "$here/caps-drift.py" "$@"
