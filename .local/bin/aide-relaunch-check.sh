#!/usr/bin/env bash
# aide-relaunch-check.sh: compat shim since 2026-11-06 (hermes-handover item 2.1); the script is ctl-relaunch-check.sh.
exec "$(dirname "$(readlink -f "$0")")/ctl-relaunch-check.sh" "$@"
