#!/usr/bin/env bash
# lean-skip.sh — wrap a decorative SessionStart hook so a LEAN session (operator seat / controller) skips it entirely.
# 10-20 2026 token-cut lever C2 (post-compaction context floor): summa drafts, learning candidates, roundtable,
# agentns, CLAUDE_SELF preview are banners nobody acts on in a seat; they are re-read on every API call.
#
# Usage: lean-skip.sh <real-hook-command> [args...]
#
# LEAN = CLAUDE_LEAN_START=1 (controller: `CLAUDE_LEAN_START=1 claude`; seats: exported by seat-relaunch.sh) or
# SEAT_LEAN=1 (the older seat marker). With neither set it does `exec "$@"` BEFORE touching stdin, so Joe's ordinary
# sessions behave exactly as without the wrapper.
[ "$#" -ge 1 ] || exit 0
if [ "${CLAUDE_LEAN_START:-}" = 1 ] || [ "${SEAT_LEAN:-}" = 1 ]; then exit 0; fi
exec "$@"
