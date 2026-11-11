#!/usr/bin/env bash
# aide-relaunch.sh: compat shim since 2026-11-06 (hermes-handover item 2.1); the script is ctl-relaunch.sh.
exec "$(dirname "$(readlink -f "$0")")/ctl-relaunch.sh" "$@"
