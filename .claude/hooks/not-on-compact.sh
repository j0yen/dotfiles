#!/usr/bin/env bash
# not-on-compact.sh — wrap a decorative SessionStart hook so a LEAN seat skips it on `compact`.
# 10-20 2026 token-cut lever B4 (compact-study/LEVERS-DESIGN.md): the hook output (CLAUDE_SELF echo, recall, nags)
# is re-injected at every compaction and re-read on every API call after it.
#
# Usage: not-on-compact.sh <real-hook-command> [args...]
#
# GATED: acts ONLY when SEAT_LEAN=1 (set by seat-relaunch.sh for a lean seat). With SEAT_LEAN unset/other it does
# `exec "$@"` BEFORE touching stdin, so every other session behaves exactly as without the wrapper.
# Fails OPEN: if the source cannot be parsed, the hook runs.
[ "$#" -ge 1 ] || exit 0
[ "${SEAT_LEAN:-}" = 1 ] || exec "$@"
if [ -t 0 ]; then exec "$@"; fi
buf=$(cat)
src=$(printf '%s' "$buf" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ "$src" = compact ] && exit 0
exec "$@" <<<"$buf"
