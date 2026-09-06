#!/bin/sh
# beacon-session-start.sh — SessionStart hook: surface fleet-beacon findings
# (PRD-fleet-beacon P1). Runs `beacon digest --brief`, which is silent on an
# all-healthy fleet, so this hook adds zero context on good days.
#
# Silent (exit 0, no output) when:
#   - the beacon binary isn't installed on this node yet, or
#   - beacon.toml isn't configured on this node yet (exit 2 from `beacon
#     digest` — "not deployed here" is not the same as "something's wrong").
# Any other non-empty stdout (findings, or "publishing failing since ...")
# is surfaced as additionalContext.

BEACON_BIN="$HOME/.local/bin/beacon"
[ -x "$BEACON_BIN" ] || exit 0

out=$("$BEACON_BIN" digest --brief 2>/dev/null)
rc=$?
[ "$rc" -eq 2 ] && exit 0
[ -n "$out" ] || exit 0

escaped=$(printf '%s' "$out" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/ *$//')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"beacon: %s"}}\n' "$escaped"
exit 0
