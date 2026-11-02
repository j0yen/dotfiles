#!/usr/bin/env bash
# mech-registry.sh: thin wrapper; the logic is mech-registry.py (stdlib only). See its header for env and flags.
exec python3 -I "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/mech-registry.py" "$@"
