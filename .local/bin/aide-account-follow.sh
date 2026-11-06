#!/usr/bin/env bash
# aide-account-follow.sh: compat shim since 2026-11-06 (hermes-handover item 2.1); the script is ctl-account-follow.sh.
exec "$(dirname "$(readlink -f "$0")")/ctl-account-follow.sh" "$@"
