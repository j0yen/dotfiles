#!/usr/bin/env bash
# statusline-prd-counts.sh — refresh the PRD counts the status line shows.
# Writes ~/.cache/wm-build-statusline/counts as one line:
#   building=<open runs> queued=<eligible PRDs> shipped6=<tags in 6h> ts=<epoch>
# building = `runs` rows with ended IS NULL (what the daemon is driving now).
# queued   = `wm-build queue` rows with eligible=true (what it can admit next).
# shipped6 = `land_versions` rows tagged in the last 6 h (merged + release tag);
#   PRDs/hour = shipped6 / 6 (Joe 10-09: "over last 6 hours"). NOT `wm-build ledger`, which counts land runs that
#   reached `archived` and lags hand archives (10-09: ledger 2 vs tagged 8 over 48 h).
# Only meaningful on the host whose wm-build daemon is alive; the status line
# checks that before calling this. Runs detached, at most once per interval,
# under an flock so N Claude sessions share one refresh.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
dir="$HOME/.cache/wm-build-statusline"; mkdir -p "$dir"
exec 9>"$dir/lock"; flock -n 9 || exit 0
db="$HOME/.local/state/wm-build/state.db"
building=$(sqlite3 -readonly "$db" "select count(*) from runs where ended is null;" 2>/dev/null)
shipped6=$(sqlite3 -readonly "$db" "select count(*) from land_versions where tagged_at > datetime('now','-6 hours');" 2>/dev/null)
queued=$(timeout 30 wm-build queue 2>/dev/null | jq '[.[]|select(.eligible)]|length' 2>/dev/null)
[ -n "${building:-}" ] && [ -n "${queued:-}" ] && [ -n "${shipped6:-}" ] || exit 1
printf 'building=%s queued=%s shipped6=%s ts=%s\n' "$building" "$queued" "$shipped6" "$(date +%s)" >"$dir/counts.tmp" \
  && mv -f "$dir/counts.tmp" "$dir/counts"
