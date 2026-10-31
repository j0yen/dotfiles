#!/usr/bin/env bash
# fake PROBE_CMD: logs "<host> <cmd>"; passes iff the command names exists-art.
printf '%s %s\n' "$1" "$2" >>"${PROBE_LOG:?}"
case "$2" in *exists-art*) exit 0 ;; *) exit 1 ;; esac
