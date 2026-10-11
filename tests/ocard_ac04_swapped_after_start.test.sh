#!/usr/bin/env bash
# PRD dotfiles-operator-status-card AC4: meta.daemon_started_at older than the
# binary mtime -> the daemon line says "swapped after start" and carries both
# version strings; a daemon started after the binary does not.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/ocard_test_helpers.sh"
OC_STARTED="$(iso_ago 600)" OC_RUN_VERSION=0.73.1 OC_BIN_VERSION=0.73.2 ocard_setup
touch -d '1 hour ago' "$work/bin/wm-build"   # binary mtime (60 min ago) is newer than the start (600 min ago)
line="$("$CARD" --section daemon)"
echo "# $line"
assert_contains "$line" "swapped after start" "daemon line flags the swap"
assert_contains "$line" "0.73.1" "daemon line has the running version"
assert_contains "$line" "0.73.2" "daemon line has the binary version"
# control: started after the binary was installed
sqlite3 "$work/state/state.db" "update meta set value='$(iso_ago 5)' where key='daemon_started_at'"
rm -f "$OPERATOR_CACHE_DIR/status.json"
line="$("$CARD" --section daemon)"
case "$line" in *"swapped after start"*) echo "NOT OK - control must not say swapped: $line"; fail=1 ;; *) echo "ok - no swap flag when daemon is newer than binary" ;; esac
exit $fail
