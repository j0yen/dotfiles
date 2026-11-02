#!/usr/bin/env bash
# watcher-premise.sh -- CLI over the shared lib .local/lib/watcher-premise.sh (WATCHERS rule: premise + expiry, disarm when expired).
#   watcher-premise.sh --selftest                          lib scenarios in throwaway HOMEs; rc 0 = all passed
#   watcher-premise.sh gate NAME PREMISE_CMD EXPIRES_ISO   rc 0 = writes allowed, 1 = disarmed (GONE or past EXPIRES), 2 = bad arguments
#   watcher-premise.sh status NAME                         print the watcher's one-line status file (rc 1 = none)
# Shell watchers source the lib directly; this entry point is for cron/unit ExecCondition= lines and for checks.
# Env: WP_LIB (lib path override)  WP_STATE (status dir, default ~/.local/state/watcher-premise)
set -uo pipefail
self=$(readlink -f "${BASH_SOURCE[0]}")
lib=${WP_LIB:-$(dirname "$self")/../lib/watcher-premise.sh}
[ -r "$lib" ] || lib=$HOME/.local/lib/watcher-premise.sh
[ -r "$lib" ] || { echo "watcher-premise.sh: lib not found ($lib)" >&2; exit 2; }
# shellcheck source=/dev/null
source "$lib"
case "${1:-}" in
  --selftest|selftest) wp_selftest; exit $? ;;
  gate)
    [ "$#" -eq 4 ] || { echo "usage: watcher-premise.sh gate NAME PREMISE_CMD EXPIRES_ISO" >&2; exit 2; }
    wp_arm "$2" "$3" "$4" || { echo "watcher-premise.sh: invalid NAME, PREMISE_CMD or EXPIRES_ISO" >&2; exit 2; }
    wp_gate; exit $? ;;
  status)
    [ "$#" -eq 2 ] || { echo "usage: watcher-premise.sh status NAME" >&2; exit 2; }
    case "$2" in ""|*[!A-Za-z0-9._-]*) echo "watcher-premise.sh: invalid NAME" >&2; exit 2;; esac
    f=$WP_STATE/$2.tsv
    [ -r "$f" ] || { echo "no status for $2" >&2; exit 1; }
    cat "$f"; exit 0 ;;
  *) echo "usage: watcher-premise.sh --selftest | gate NAME PREMISE_CMD EXPIRES_ISO | status NAME" >&2; exit 2 ;;
esac
