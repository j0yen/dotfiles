#!/usr/bin/env bash
# watchman-root-guard.sh: one pass, no loop. Removes every watchman root that is a DENY member (~/.config/watchman-guard/deny.list) with `watch-del`.
# This is the ONLY enforcement for library clients (pywatchman / fb-watchman talk on the socket; the ~/.local/bin/watchman shim cannot refuse them).
# Incident 10-20 14:39:39: a client added /home/jsy; 12 s later the 65536 inotify watches were gone; 10-23 systemd could not add unit watches.
# Units: watchman-root-guard.timer (every 1 min) is the REAL guard during exhaustion; watchman-root-guard.path (PathChanged on the saved-state file) is the
# fast path and needs an inotify watch itself, so it is dead exactly when the watches are exhausted.
# Every watchman call is `timeout 10 /usr/bin/watchman --no-spawn --no-local` (never the shim: self-logging noise; never a spawn: a spawned server inherits
# this env; never a hang: a watch-list hung 15 min on 10-24). Equality only: a root is removed iff it is byte-equal to a DENY member; descendants stay.
# Flow: arm (PREMISE/EXPIRES via watcher-premise.sh) -> watch-list -> [no server: exit 0 `no-server`] [timeout: exit 0 + rate-limited seat-event
#   `watchman-unresponsive`] -> debounce (same watch-list sha within 5 s: exit 0 no-op) -> per denied root: wp_gate && wp_emit_write && watch-del, a
#   clients.jsonl row (kind=sweeper-removed), and seat-event.sh ctl "WATCHMAN-GUARD removed root <p>" (one per root per 10 min; a root re-added >= 3 times
#   in 1 h adds "NAME THE CLIENT: see clients.jsonl").
# Output lines: `watchman-root-guard: no-server|clean|noop-debounce|removed <p>|unresponsive|DISARMED <why>`.
# 3c (enforce_root_files / WATCHMAN_CONFIG_FILE) is DEFERRED: un-defer when clients.jsonl names the owners of all 4 rootless roots, or at EXPIRES.
# Env: WG_WATCHMAN (/usr/bin/watchman) WG_DENY WG_STATE (default ~/.local/state/watchman-guard) WG_SEAT_EVENT (~/.local/bin/seat-event.sh) WG_EXPIRES
#   WG_LIB WG_WP_LIB WP_STATE WP_OWNER (default rb) WG_TIMEOUT (10) WG_DEBOUNCE_S (5; -1 = off) WG_EVENT_GAP_S (600) WG_READD_N (3) WG_READD_WINDOW_S (3600)
# Writes: watch-del on the watchman server (only for a DENY root), $WG_STATE/{clients.jsonl,removals.tsv,last-sha}, $WP_STATE, seat-event. Exit 0 always except usage 2.
set -u
export LC_ALL=C
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
if [ "${1:-}" = "--selftest" ]; then
  T="$HERE/../../tests/watchman-guard.test.sh"
  [ -r "$T" ] || { echo "watchman-root-guard --selftest: $T not found" >&2; exit 2; }
  exec bash "$T"
fi
[ "$#" -eq 0 ] || { echo "usage: watchman-root-guard.sh [--selftest]" >&2; exit 2; }

WM=${WG_WATCHMAN:-/usr/bin/watchman}
SEAT_EVENT=${WG_SEAT_EVENT:-$HOME/.local/bin/seat-event.sh}
EXPIRES=${WG_EXPIRES:-2026-11-24T23:59:00-08:00}
TMO=${WG_TIMEOUT:-10}
DEBOUNCE_S=${WG_DEBOUNCE_S:-5}
GAP_S=${WG_EVENT_GAP_S:-600}
READD_N=${WG_READD_N:-3}
READD_WIN=${WG_READD_WINDOW_S:-3600}
export WP_OWNER=${WP_OWNER:-rb}

for _l in "${WG_LIB:-}" "$HERE/../lib/watchman-guard-lib.sh" "$HOME/.local/lib/watchman-guard-lib.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type wg_is_denied >/dev/null 2>&1 || { echo "watchman-root-guard: watchman-guard-lib.sh not found" >&2; exit 2; }
for _l in "${WG_WP_LIB:-}" "$HERE/../lib/watcher-premise.sh" "$HOME/.local/lib/watcher-premise.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type wp_arm >/dev/null 2>&1 || { echo "watchman-root-guard: watcher-premise.sh lib not found" >&2; exit 2; }

wg_state_dir; STATE=${WG_STATE:-$REPLY}
mkdir -p "$STATE" 2>/dev/null || true

wp_arm watchman-root-guard "test -x $(printf '%q' "$WM")" "$EXPIRES" 'carbon watchman roots in DENY exhaust inotify (10-20 incident)' || true
if ! wp_gate 2>/dev/null; then
  if [ "${WP_DEFECT:--}" = expired ]; then why=expired; elif [ "${WP_VERDICT:-}" = GONE ]; then why=premise; else why="${WP_DEFECT:--}"; fi
  echo "watchman-root-guard: DISARMED $why"
  exit 0
fi

now=$(date +%s)
REM=$STATE/removals.tsv     # epoch<TAB>root<TAB>evt(1|0)
# rate-limited bell: bell KEY LINE  (one per KEY per GAP_S; rows with evt=1 are the sent ones)
bell() {
  local key=$1 line=$2 last
  last=$(awk -F'\t' -v k="$key" '$2==k && $3==1 {t=$1} END{print t+0}' "$REM" 2>/dev/null)
  if [ $((now - ${last:-0})) -ge "$GAP_S" ]; then
    "$SEAT_EVENT" ctl "$line" >/dev/null 2>&1 || true
    printf '%s\t%s\t1\n' "$now" "$key" >> "$REM" 2>/dev/null || true
    return 0
  fi
  return 1
}

out=$(timeout "$TMO" "$WM" --no-spawn --no-local watch-list 2>/dev/null </dev/null); rc=$?
if [ "$rc" = 124 ]; then
  bell "-unresponsive-" "WATCHMAN-GUARD watchman-unresponsive: watch-list timed out after ${TMO}s" || true
  echo "watchman-root-guard: unresponsive"
  exit 0
fi
roots=$(printf '%s' "$out" | jq -r '.roots[]?' 2>/dev/null); jrc=$?
if [ "$rc" != 0 ] || [ "$jrc" != 0 ]; then
  echo "watchman-root-guard: no-server"
  exit 0
fi

sha=$(printf '%s' "$out" | sha256sum | cut -c1-16)
if [ -r "$STATE/last-sha" ]; then
  read -r lt ls < "$STATE/last-sha" 2>/dev/null || true
  if [ "${ls:-}" = "$sha" ] && [ $((now - ${lt:-0})) -le "$DEBOUNCE_S" ]; then echo "watchman-root-guard: noop-debounce"; exit 0; fi
fi
printf '%s %s\n' "$now" "$sha" > "$STATE/last-sha" 2>/dev/null || true

wg_load_deny || { echo "watchman-root-guard: deny list unreadable"; exit 0; }
removed=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  wg_is_denied "$root" || continue
  if ! { wp_gate && wp_emit_write watch-del "$root" "watchman watch-del $root" "root is a DENY member (equality); watch-list sha $sha; client pids in $STATE/clients.jsonl" "watchman watch-project $root"; }; then
    echo "watchman-root-guard: BLOCKED $root (gate or outbox)"
    continue
  fi
  timeout "$TMO" "$WM" --no-spawn --no-local watch-del "$root" >/dev/null 2>&1 </dev/null || true
  removed=$((removed + 1))
  wg_json_esc "$root"
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  wg_append_row "{\"ts\":\"$ts\",\"pid\":$$,\"kind\":\"sweeper-removed\",\"root\":\"$REPLY\",\"refused\":true}"
  readd=$(awk -F'\t' -v r="$root" -v from=$((now - READD_WIN)) '$2==r && $3==0 && $1>=from {n++} END{print n+0}' "$REM" 2>/dev/null)
  readd=${readd:-0}
  printf '%s\t%s\t0\n' "$now" "$root" >> "$REM" 2>/dev/null || true
  line="WATCHMAN-GUARD removed root $root"
  [ $((readd + 1)) -ge "$READD_N" ] && line="$line; re-added $((readd + 1))x in 1h: NAME THE CLIENT: see clients.jsonl"
  # removal rows are evt=0 (they feed the re-add count); a bell that goes out adds an evt=1 row (it feeds the 10-min gap)
  bell "$root" "$line" || true
  echo "watchman-root-guard: removed $root"
done <<< "$roots"
[ "$removed" -gt 0 ] || echo "watchman-root-guard: clean"
# keep the state file small: rows older than 24 h
if [ -s "$REM" ]; then awk -F'\t' -v from=$((now - 86400)) '$1>=from' "$REM" > "$REM.tmp" 2>/dev/null && mv -f "$REM.tmp" "$REM" 2>/dev/null || true; fi
exit 0
