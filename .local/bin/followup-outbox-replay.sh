#!/usr/bin/env bash
# followup-outbox-replay.sh: timer-driven outbox replay (ledger ask A1307); needs no model turn. Run by followup-outbox-replay.timer so a queued escalation
# reaches its seat even when no Stop hook fires. Delivery = FOLLOWUP_DELIVER_CMD, else followup-deliver.sh.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
lib="$here/../../.claude/hooks/followup-lib.sh"; [ -f "$lib" ] || lib="$HOME/.claude/hooks/followup-lib.sh"
# shellcheck disable=SC1090
. "$lib" || exit 0
fu_outbox_replay
# Producer for the UserPromptSubmit prompt-context cache (A1296 critical-path reduction): refresh each known seat's owed-rows cache so a prompt reads local state,
# never the ledger. Reuses this existing timer (no new scheduler); one refresher per seat is enforced by owed-now.sh's lock dir. Best-effort: never fails the replay.
owed="$here/../../.claude/hooks/owed-now.sh"; [ -f "$owed" ] || owed="$HOME/.claude/hooks/owed-now.sh"
if [ -f "$owed" ]; then
  for s in $(awk -F'\t' '$1 ~ /^[a-z0-9]+$/ {print $1}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" 2>/dev/null | sort -u); do
    bash "$owed" refresh --seat "$s" >/dev/null 2>&1 || true
  done
fi
exit 0
