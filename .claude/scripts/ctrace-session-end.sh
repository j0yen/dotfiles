#!/usr/bin/env bash
# Stop hook: if we own the active ctrace session, stop it and render summary.
# Uses `scribe render-session` for idempotent, hook-safe rendering.
# Never blocks shutdown — always exits 0.

set -u

ctrace=/home/jsy/.local/bin/ctrace
cache=/home/jsy/.cache/ctrace
marker="$cache/claude-owns.json"
scribe=/home/jsy/.local/bin/scribe
docket=/home/jsy/.local/bin/docket
err="$cache/claude-stop.err"

# ctrace not installed on this box — nothing to stop or render.
[ -x "$ctrace" ] || exit 0

# ── Resolve log path ──────────────────────────────────────────────────────────
log=""

if [ -f "$marker" ]; then
    log=$(jq -r '.log // empty' "$marker" 2>/dev/null || true)
fi

# Stop the session regardless of whether we got a log path from the marker.
"$ctrace" stop >/dev/null 2>"$err" || true

# Marker is consumed — remove it.
rm -f "$marker"

# If marker didn't give us a log path, fall back to `ctrace status`.
if [ -z "$log" ]; then
    log=$(${ctrace} status --format json 2>/dev/null | jq -r '.log // empty' 2>/dev/null || true)
fi

# ── Render ────────────────────────────────────────────────────────────────────
if [ -x "$scribe" ] && [ -n "$log" ] && [ -f "$log" ]; then
    if ! "$scribe" render-session "$log" >/dev/null 2>>"$err"; then
        # Genuine render failure — report to docket so it shows up in the daily
        # review but does NOT block shutdown.
        if [ -x "$docket" ]; then
            "$docket" report --key ctrace-sessionend-flake --severity warn \
                --evidence "session:${CLAUDE_SESSION_ID:-unknown}" 2>/dev/null || true
        fi
    fi
else
    # No renderable log found — report only when we had a session ID to track.
    if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        if [ -x "$docket" ]; then
            "$docket" report --key ctrace-sessionend-flake --severity warn \
                --evidence "session:${CLAUDE_SESSION_ID:-unknown}:no-log" 2>/dev/null || true
        fi
    fi
fi

exit 0
