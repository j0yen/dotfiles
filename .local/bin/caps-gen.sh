#!/usr/bin/env bash
# caps-gen.sh: write the enforced files from .config/fleet/caps.tsv (P28 stage 2). Logic: caps-gen.py (same directory).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
exec python3 -I "$here/caps-gen.py" "$@"
