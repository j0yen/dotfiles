#!/usr/bin/env bash
# interactive-gate.sh — skip decorative hooks (banners, changelogs, nags) when
# the session is headless (`claude -p` / `claude --print`), since nobody is
# there to read them. Fails OPEN: any detection error just runs the hook, so
# a bug here can never silently kill a hook a live buildloop depends on.
#
# Usage: interactive-gate.sh <real-hook-path> [args...]

set -u

LOG_DIR="${HOME}/.cache"
LOG_FILE="${LOG_DIR}/interactive-gate.log"
mkdir -p "$LOG_DIR" 2>/dev/null

real_hook="${1:-}"
if [ -z "$real_hook" ]; then
    # Nothing to gate — fail open with no-op success.
    exit 0
fi

log() {
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$1" >> "$LOG_FILE" 2>/dev/null
}

# Detect headless by walking the ancestor chain from $PPID looking for the
# nearest `claude` process, then checking whether it was invoked with -p /
# --print. Any failure along the way -> treat as interactive (fail open).
is_headless() {
    local pid="${PPID:-}"
    [ -n "$pid" ] || return 1

    local hops=0
    while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$hops" -lt 64 ]; do
        hops=$((hops + 1))

        local stat_path="/proc/${pid}/stat"
        local cmdline_path="/proc/${pid}/cmdline"
        [ -r "$stat_path" ] || return 1
        [ -r "$cmdline_path" ] || return 1

        # /proc/<pid>/stat field 4 is ppid. Field 2 (comm) is parenthesized
        # and may contain spaces/parens, so anchor on the LAST ')' before
        # splitting the remaining fields.
        local stat_content
        stat_content=$(cat "$stat_path" 2>/dev/null) || return 1
        local after_comm="${stat_content##*)}"
        # after_comm now: " S <ppid> ..." — field 1 is state, field 2 is ppid.
        local ppid
        ppid=$(awk '{print $2}' <<<"$after_comm" 2>/dev/null)
        [ -n "$ppid" ] || return 1

        # Read argv (NUL-delimited) from cmdline.
        local argv0 argv1
        argv0=$(tr '\0' '\n' < "$cmdline_path" 2>/dev/null | sed -n '1p')
        argv1=$(tr '\0' '\n' < "$cmdline_path" 2>/dev/null | sed -n '2p')

        if printf '%s' "$argv0" | grep -qE '(^|/)claude(\.exe)?$' \
            || printf '%s' "$argv1" | grep -qE '(^|/)claude(\.exe)?$'; then
            # Found the ancestor claude process — check its full argv for -p/--print.
            local a
            while IFS= read -r a; do
                if [ "$a" = "-p" ] || [ "$a" = "--print" ]; then
                    return 0
                fi
            done < <(tr '\0' '\n' < "$cmdline_path" 2>/dev/null)
            return 1
        fi

        pid="$ppid"
    done

    return 1
}

headless=0
if is_headless; then
    headless=1
fi

if [ "$headless" -eq 1 ]; then
    log "headless skip ${real_hook}"
    exit 0
fi

log "interactive run ${real_hook}"
exec "$@"
