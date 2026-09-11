#!/usr/bin/env bash
# agorabus-reap-selftest.sh — proves agorabus-reap.sh's classifier tells a
# stale worker from a live one, and never mistakes the real daemon for a
# reapable process, WITHOUT ever performing a real kill on a production
# process. Exit 0 = pass.
#
# Fixtures:
#   - "stale": a real `sleep 600` process whose cmdline embeds
#     agorabus-worker.sh plus a genuinely dead pid, double-forked so it
#     reparents under init (PPID=1) — satisfies TWO of the three STALE
#     criteria independently.
#   - "live": a real `sleep 600` process whose cmdline embeds
#     agorabus-worker.sh plus this selftest's own (alive) pid.
# Both fixtures are killed -9 on exit.

set -u

reap_script="$HOME/.claude/scripts/agorabus-reap.sh"
if [ ! -r "$reap_script" ]; then
    echo "FAIL: reap script not found at $reap_script" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$reap_script"

fail=0

assert_eq() {
    local desc="$1" expect="$2" got="$3"
    if [ "$got" = "$expect" ]; then
        echo "PASS: $desc (got '$got')"
    else
        echo "FAIL: $desc (expected '$expect', got '$got')" >&2
        fail=1
    fi
}

assert_prefix() {
    local desc="$1" prefix="$2" got="$3"
    case "$got" in
        "$prefix"*) echo "PASS: $desc (got '$got')" ;;
        *) echo "FAIL: $desc (expected prefix '$prefix', got '$got')" >&2; fail=1 ;;
    esac
}

# --- fixture: a pid guaranteed to be dead ---
( : ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
if kill -0 "$dead_pid" 2>/dev/null; then
    echo "FAIL: fixture dead_pid=$dead_pid is somehow still alive" >&2
    exit 1
fi

# --- fixture: fake STALE worker — double-forked (reparents to init) with
#     cmdline embedding agorabus-worker.sh + the dead pid above. ---
stale_pidfile=$(mktemp -u "${TMPDIR:-/tmp}/agorabus-reap-selftest.stale.XXXXXX")
( ( bash -c 'sleep 600 & wait' agorabus-worker.sh fake-cwd "$dead_pid" \
        </dev/null >/dev/null 2>&1 &
    echo $! >"$stale_pidfile"
  ) & )
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$stale_pidfile" ] && break
    sleep 0.1
done
stale_pid=$(cat "$stale_pidfile" 2>/dev/null || true)
rm -f "$stale_pidfile"

# --- fixture: fake LIVE worker — owner is this selftest's own (alive) pid.
bash -c 'sleep 600 & wait' agorabus-worker.sh fake-cwd "$$" \
    </dev/null >/dev/null 2>&1 &
live_pid=$!

cleanup() {
    local p child
    for p in "${stale_pid:-}" "${live_pid:-}"; do
        [ -n "$p" ] || continue
        # Each fixture is `bash -c 'sleep 600 & wait' ...`; kill its sleep
        # child too, by exact pid, before the fixture itself.
        for child in $(pgrep -P "$p" 2>/dev/null || true); do
            kill -9 "$child" 2>/dev/null || true
        done
        kill -9 "$p" 2>/dev/null || true
    done
}
trap cleanup EXIT

if [ -z "$stale_pid" ] || ! kill -0 "$stale_pid" 2>/dev/null; then
    echo "FAIL: stale fixture did not start (pid='$stale_pid')" >&2
    exit 1
fi
if ! kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: live fixture did not start (pid='$live_pid')" >&2
    exit 1
fi

daemon_pid=$(agorabus_reap_daemon_pid)

stale_class=$(agorabus_reap_classify_pid "$stale_pid" "$daemon_pid")
live_class=$(agorabus_reap_classify_pid "$live_pid" "$daemon_pid")

assert_prefix "fake stale worker (dead owner + reparented) classified STALE" "STALE:" "$stale_class"
assert_eq "fake live worker (alive owner) classified LIVE" "LIVE" "$live_class"

if [ -n "$daemon_pid" ] && [ -d "/proc/$daemon_pid" ]; then
    daemon_class=$(agorabus_reap_classify_pid "$daemon_pid" "$daemon_pid")
    assert_eq "real agorabus daemon pid excluded as DAEMON" "DAEMON" "$daemon_class"
else
    echo "SKIP: no live agorabus daemon found (agorabus.service not active?) — cannot test DAEMON exclusion"
fi

exit "$fail"
