#!/usr/bin/env bash
# agorabus-reap.sh — reaper backstop for orphaned agorabus workers and
# subscribers (2026-09-11, worker-leak PRD). Fixes 1 and 2 (matching sid
# derivation + owner-death self-exit) address the actual root causes; this
# is the deliberately conservative last line of defense for anything that
# still slips through (a host that hasn't picked up the fix yet, a signal
# neither watchdog catches, etc.).
#
# Safety model:
#   - Only ever considers processes matching an agorabus worker/subscriber
#     cmdline pattern. Never touches the daemon (excluded by MainPID via
#     systemctl, and defensively by cmdline match too).
#   - Kills by EXACT PID only. Never pkill -f.
#   - A process is STALE (reapable) iff:
#       (a) its /proc/PID/exe symlink is deleted, OR
#       (b) it is orphaned (PPID==1) and is not the daemon, OR
#       (c) its embedded owning-Claude pid (recovered from cmdline on a
#           best-effort basis) is dead.
#     Anything else is LIVE and is never touched.
#   - Safety valve: if STALE is >90% of the total candidate set AND fewer
#     than half of the stale set has concrete evidence (deleted-exe or
#     dead-owner — NOT orphaned-alone, which is the weakest signal), reap
#     NOTHING and log a warning instead. The classification criteria might
#     be wrong; do not mass-kill on a hunch.
#   - TERM first, KILL after 5s only for survivors.
#
# The classifier (agorabus_reap_classify_pid) and the daemon-pid lookup
# (agorabus_reap_daemon_pid) are plain functions with no side effects, so
# agorabus-reap-selftest.sh can source this file and call them directly
# against fabricated PIDs without running main() or performing any real
# kill. main() only runs when this file is executed directly (see the
# BASH_SOURCE guard at the bottom).
#
# DRY_RUN=1 ./agorabus-reap.sh logs what it WOULD do without killing
# anything or updating reaped/remaining counts.

set -u

cache="$HOME/.cache/agorabus"
log_file="$cache/reap.log"
mkdir -p "$cache" 2>/dev/null || true

_pgrep=$(command -v pgrep || true)
_systemctl=$(command -v systemctl || true)
_awk=$(command -v awk || true)

DRY_RUN="${DRY_RUN:-0}"

_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

_log() { printf '%s\n' "$1" >>"$log_file" 2>/dev/null || true; }

# Resolve the live agorabus daemon's pid via systemd (never the pattern
# match used for workers/subscribers). Empty output means "unknown" —
# callers fall back to the defensive cmdline check for "agorabus daemon".
agorabus_reap_daemon_pid() {
    [ -n "$_systemctl" ] || { printf ''; return 0; }
    "$_systemctl" --user show -p MainPID --value agorabus.service 2>/dev/null \
        | tr -d '[:space:]'
}

# Pure classifier. Args: pid [daemon_pid]
# Prints one of: DAEMON | STALE:<reason>[:<detail>] | LIVE | OTHER | GONE
agorabus_reap_classify_pid() {
    local pid="$1" daemon_pid="${2:-}"
    [ -d "/proc/$pid" ] || { printf 'GONE'; return 0; }

    if [ -n "$daemon_pid" ] && [ "$pid" = "$daemon_pid" ]; then
        printf 'DAEMON'; return 0
    fi

    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)

    # Defensive second daemon check even if MainPID lookup failed/mismatched.
    case "$cmdline" in
        *"agorabus daemon"*) printf 'DAEMON'; return 0 ;;
    esac

    # Only classify actual worker/subscriber processes; leave everything
    # else alone entirely.
    case "$cmdline" in
        *agorabus-worker.sh*|*"agorabus subscribe"*) : ;;
        *) printf 'OTHER'; return 0 ;;
    esac

    local exe_link
    exe_link=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    if [[ "$exe_link" == *" (deleted)" ]]; then
        printf 'STALE:deleted_exe'; return 0
    fi

    local ppid=""
    if [ -n "$_awk" ]; then
        ppid=$("$_awk" '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)
    fi
    if [ "$ppid" = "1" ]; then
        printf 'STALE:orphaned_ppid1'; return 0
    fi

    # Best-effort recovery of the owning Claude pid:
    #   1. agorabus-worker.sh's positional owner-pid arg (Fix 2, added
    #      2026-09-11) — the last standalone all-digit token in cmdline.
    #   2. a PID-fallback sid's embedded digits (claude-<pid>-<project>).
    # An agentns-hex sid (claude-<16hex>-<project>) carries no recoverable
    # pid this way; such a process falls through to LIVE — conservative by
    # design, never guess an owner is dead.
    local owner="" tok
    for tok in $cmdline; do
        [[ "$tok" =~ ^[0-9]+$ ]] && owner="$tok"
    done
    if [ -z "$owner" ] && [[ "$cmdline" =~ claude-([0-9]+)- ]]; then
        owner="${BASH_REMATCH[1]}"
    fi
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        printf 'STALE:dead_owner:%s' "$owner"
        return 0
    fi

    printf 'LIVE'
}

# All agorabus worker/subscriber candidate pids (NOT the daemon — its
# cmdline is "agorabus daemon", matching neither pattern below).
agorabus_reap_candidates() {
    [ -n "$_pgrep" ] || return 0
    { "$_pgrep" -f 'agorabus subscribe' 2>/dev/null
      "$_pgrep" -f 'agorabus-worker\.sh' 2>/dev/null
    } | sort -un
}

main() {
    if [ -z "$_pgrep" ] || [ -z "$_awk" ]; then
        _log "$(_now) WARN missing pgrep or awk on PATH — nothing to do"
        return 0
    fi

    local daemon_pid
    daemon_pid=$(agorabus_reap_daemon_pid)

    local total=0 stale=0 concrete=0
    local -a stale_pids=() stale_reasons=()
    local pid cls

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cls=$(agorabus_reap_classify_pid "$pid" "$daemon_pid")
        case "$cls" in
            DAEMON)
                _log "$(_now) WARN pid=$pid matched a worker/subscriber pattern but is the daemon — excluded, not counted"
                ;;
            GONE|OTHER)
                : # raced or irrelevant; don't count
                ;;
            STALE:*)
                total=$((total + 1))
                stale=$((stale + 1))
                stale_pids+=("$pid")
                stale_reasons+=("$cls")
                case "$cls" in
                    STALE:deleted_exe*|STALE:dead_owner*) concrete=$((concrete + 1)) ;;
                esac
                ;;
            *)
                total=$((total + 1))
                ;;
        esac
    done < <(agorabus_reap_candidates)

    local reap_ok=1
    if [ "$total" -gt 0 ] && [ "$stale" -gt 0 ]; then
        local stale_pct=$(( stale * 100 / total ))
        local half_stale=$(( (stale + 1) / 2 ))
        if [ "$stale_pct" -gt 90 ] && [ "$concrete" -lt "$half_stale" ]; then
            reap_ok=0
            _log "$(_now) WARN safety-valve tripped: stale=$stale/$total (${stale_pct}%) concrete_evidence=$concrete/$stale — reaping SKIPPED, classification criteria may be wrong"
        fi
    fi

    local reaped=0 i
    if [ "$reap_ok" -eq 1 ] && [ "${#stale_pids[@]}" -gt 0 ]; then
        for i in "${!stale_pids[@]}"; do
            pid="${stale_pids[$i]}"
            if [ "$DRY_RUN" = "1" ]; then
                _log "$(_now) DRY_RUN would-reap pid=$pid reason=${stale_reasons[$i]}"
                continue
            fi
            _log "$(_now) reap-term pid=$pid reason=${stale_reasons[$i]}"
            kill -TERM "$pid" 2>/dev/null || true
        done

        if [ "$DRY_RUN" != "1" ]; then
            sleep 5
            for pid in "${stale_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    _log "$(_now) reap-kill pid=$pid (survived TERM)"
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            done
            for pid in "${stale_pids[@]}"; do
                kill -0 "$pid" 2>/dev/null || reaped=$((reaped + 1))
            done
        fi
    fi

    local remaining=$(( total - reaped ))
    _log "$(_now) total=$total stale=$stale reaped=$reaped remaining=$remaining dry_run=$DRY_RUN"
    _log "$(_now) WORKERCOUNT total=$total stale=$stale reaped=$reaped remaining=$remaining"
}

# Allow sourcing (for the selftest) without running main().
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi
