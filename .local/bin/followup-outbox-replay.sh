#!/usr/bin/env bash
# followup-outbox-replay.sh: timer-driven outbox replay (ledger ask A1307); needs no model turn. Run by followup-outbox-replay.timer so a queued escalation
# reaches its seat even when no Stop hook fires. Delivery = FOLLOWUP_DELIVER_CMD, else followup-deliver.sh.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
lib="$here/../../.claude/hooks/followup-lib.sh"; [ -f "$lib" ] || lib="$HOME/.claude/hooks/followup-lib.sh"
# shellcheck disable=SC1090
. "$lib" || exit 0
fu_outbox_replay
