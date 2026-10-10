#!/usr/bin/env bash
# statusline-prd-counts.sh — refresh the PRD counts the status line shows.
# Writes ~/.cache/wm-build-statusline/counts as one line:
#   building=<open runs> queued=<eligible PRDs> shipped6=<tags in 6h> ts=<epoch>
# building = `runs` rows with ended IS NULL (what the daemon is driving now).
# queued   = `wm-build queue` rows with eligible=true (what it can admit next).
# shipped6 = `wm-build ledger --since 6h --json` .shipped (0.73.4+: distinct runs tagged in
#   the window at/after `archived`). ONE source of truth; never re-derive it in sqlite here
#   (10-09: a hand query compared RFC3339 'T' stamps against sqlite's ' ' stamps and overcounted).
# Only meaningful on the host whose wm-build daemon is alive; the status line
# checks that before calling this. Runs detached, at most once per interval,
# under an flock so N Claude sessions share one refresh.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
dir="$HOME/.cache/wm-build-statusline"; mkdir -p "$dir"
exec 9>"$dir/lock"; flock -n 9 || exit 0
db="$HOME/.local/state/wm-build/state.db"
building=$(sqlite3 -readonly "$db" "select count(*) from runs where ended is null;" 2>/dev/null)
shipped6=$(timeout 10 wm-build ledger --since 6h --json 2>/dev/null | jq -r '.shipped' 2>/dev/null)
queued=$(timeout 30 wm-build queue 2>/dev/null | jq '[.[]|select(.eligible)]|length' 2>/dev/null)
# total = PRD files still `Status: queued` (eligible + waiting on Depends-on/claims); 10-10 Joe "status bar prd queue count seems wrong" — 191 ready read as the whole queue of 377
total=$(grep -l '^- Status: queued' "$HOME/Documents/PRDs/build-queue/"*.md 2>/dev/null | wc -l)
[ -n "${building:-}" ] && [ -n "${queued:-}" ] && [ -n "${shipped6:-}" ] || exit 1
printf 'building=%s queued=%s shipped6=%s ts=%s total=%s\n' "$building" "$queued" "$shipped6" "$(date +%s)" "${total:-?}" >"$dir/counts.tmp" \
  && mv -f "$dir/counts.tmp" "$dir/counts"
