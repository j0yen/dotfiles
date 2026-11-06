#!/usr/bin/env bash
# aide-launch.sh: compat shim since 2026-11-06 (hermes-handover item 2.1); the launcher is ctl-launch.sh.
exec "$(dirname "$(readlink -f "$0")")/ctl-launch.sh" "$@"
