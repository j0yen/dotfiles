#!/usr/bin/env bash
# followup-deliver.sh: the default FOLLOWUP_DELIVER_CMD (ledger ask A1307). Reads one outbox entry (JSON) on stdin and rings the owning seat's bell
# with seat-event.sh (appends to the seat's events log; no model turn started by this script). Exit 0 only when the bell rang, so the outbox keeps the entry otherwise.
# Env: SEAT_EVENT_BIN (default seat-event.sh on PATH / ~/.local/bin).
set -u
command -v jq >/dev/null 2>&1 || exit 1
in="$(cat)"; [ -n "$in" ] || exit 1
seat="$(jq -r '.seat // "ctl"' <<<"$in" 2>/dev/null)"; id="$(jq -r '.id // empty' <<<"$in" 2>/dev/null)"
[ -n "$id" ] || exit 1
line="FOLLOW-UP $(jq -r '.kind // "obligation"' <<<"$in") $id: $(jq -r '.detail // ""' <<<"$in")"
bin="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"
[ -x "$bin" ] || bin="$(command -v seat-event.sh)" || exit 1
SEAT_EVENT_NOWAKE=1 EVENT_SOURCE=followup-loop "$bin" "$seat" "$line" >/dev/null 2>&1
