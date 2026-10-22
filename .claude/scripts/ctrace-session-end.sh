#!/usr/bin/env bash
# Stop hook: if we own the active ctrace session, stop it and render summary.
# Uses `scribe render-session` for idempotent, hook-safe rendering.
# Never blocks shutdown — always exits 0.

set -u

# HEADLESS = NO TRACER (10-22 4:00 PM): a seat unit's `claude -p` turn (WM_SEAT rb|r7|ctl, or any of the first 4 ancestors running in print mode: ` -p ` / `--print`)
# must not start `sudo bpftrace` here nor stop/render one at SessionEnd: the root-owned tracer lingers in the unit's cgroup, user-systemd cannot kill it
# ("Operation not permitted"), the SessionEnd hook is cancelled and the unit fails. Same test as ~/.claude/hooks/adhd-always-on.sh (adhd_headless).
# CTRACE_SKIP_ANCESTORS=1 is a test-only seam (the real ancestry cannot change a result).
ctrace_headless() {
    case "${WM_SEAT:-}" in rb|r7|ctl) return 0 ;; esac
    [ "${CTRACE_SKIP_ANCESTORS:-}" = 1 ] && return 1
    local pid=$PPID i cmd c stat
    for i in 1 2 3 4; do
        [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || return 1
        cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
        c=" ${cmd%" "} "
        [[ "$c" == *" -p "* || "$c" == *"--print"* ]] && return 0
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
        pid=$(set -- ${stat##*) }; echo "${2:-}")
    done
    return 1
}
ctrace_headless && exit 0

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
