#!/usr/bin/env bash
# caps-void.sh --class <class> [--approvals N] [--dry-run]: void every live row of a class in the caps registry (P28 mechanism 4).
# Stage 1: rewrites the registry file only; host files are listed for the host operator, never edited. Logic: caps-void.py.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
exec python3 -I "$here/caps-void.py" "$@"
