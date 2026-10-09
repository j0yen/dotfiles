#!/usr/bin/env bash
# statusline-prd-counts.sh — refresh the PRD counts the status line shows.
# Writes ~/.cache/wm-build-statusline/counts as one line:
#   building=<open runs> queued=<eligible PRDs> ts=<epoch>
# building = `runs` rows with ended IS NULL (what the daemon is driving now).
# queued   = `wm-build queue` rows with eligible=true (what it can admit next).
# Only meaningful on the host whose wm-build daemon is alive; the status line
# checks that before calling this. Runs detached, at most once per interval,
# under an flock so N Claude sessions share one refresh.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
dir="$HOME/.cache/wm-build-statusline"; mkdir -p "$dir"
exec 9>"$dir/lock"; flock -n 9 || exit 0
db="$HOME/.local/state/wm-build/state.db"
building=$(sqlite3 -readonly "$db" "select count(*) from runs where ended is null;" 2>/dev/null)
queued=$(timeout 30 wm-build queue 2>/dev/null | jq '[.[]|select(.eligible)]|length' 2>/dev/null)
[ -n "${building:-}" ] && [ -n "${queued:-}" ] || exit 1
printf 'building=%s queued=%s ts=%s\n' "$building" "$queued" "$(date +%s)" >"$dir/counts.tmp" \
  && mv -f "$dir/counts.tmp" "$dir/counts"
