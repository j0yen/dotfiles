#!/usr/bin/env bash
# statusline.sh — model · context used% (warn ≥50% = ~100K on a 200K window) · PRD counts.
# GATES, TOKENS, and cost fields removed 2026-10-06 (Joe: not useful).
# PRD counts added 2026-10-09 (Joe: "live count on the number of prds being built and the number in queue"):
#   🔨 N = open daemon runs, 📋 N = eligible PRDs in the queue, read from a cache file that
#   statusline-prd-counts.sh refreshes in the background every ≤30 s — only on the host whose
#   wm-build daemon is alive, so another node never shows a stale clone's numbers.
# PRDs/hour added 2026-10-09 (Joe: "add PRDs/hour over last 6 hours"): 🚀 <shipped6/6>/h (<shipped6>/6h), shipped =
#   `wm-build ledger --since 6h` shipped (runs tagged in the window, at/after archived; fixed in 0.73.4 #195).
# build_share segment added 2026-10-23 (Joe: "add it to the status bar"): ` · build NN%`, or ` · 🔴 build NN% <50%` while the alarm fires.
#   Sources (token-ledger owns the numbers and the threshold; never recomputed here), under ${TOKEN_LEDGER_STATE_DIR:-$HOME/.cache/token-ledger}:
#   build-share.json (.date UTC, .build_share) — no segment when missing, null, or not today's UTC date;
#   today-summary.txt line 2 starting `ALARM build_share` = alarm firing.
set -uo pipefail
in=$(cat)
model=$(printf '%s' "$in" | jq -r '.model.display_name // .model.id // "?"')
pct=$(printf '%s' "$in" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)
size=$(printf '%s' "$in" | jq -r '.context_window.context_window_size // empty')
ctx=""
if [ -n "$pct" ]; then
  used_k=""; [ -n "$size" ] && used_k="$(( pct * size / 100000 ))K/"
  if   [ "$pct" -ge 75 ]; then ctx="🔴 ctx ${used_k}${pct}% COMPACT NOW"
  elif [ "$pct" -ge 50 ]; then ctx="⚠ ctx ${used_k}${pct}% >100K — /compact or hand off"
  else ctx="ctx ${used_k}${pct}%"; fi
fi

# PRD segment (🔨 building · 📋 ready/queued · 🚀 /h) REMOVED 2026-10-22 3:4x PM (Joe: "we can remove this from the status bar … I can see it on Fleet Dash");
# the counts live on the fleet dashboard http://carbon:8787/ and the statusline-prd-counts.sh refresher no longer spawns.

bs=""
bsdir="${TOKEN_LEDGER_STATE_DIR:-$HOME/.cache/token-ledger}"
if bsn=$(jq -r --arg d "$(date -u +%F)" 'select(.date == $d and (.build_share | type) == "number") | .build_share | round' "$bsdir/build-share.json" 2>/dev/null) && [ -n "$bsn" ]; then
  bsl=""; { IFS= read -r _; IFS= read -r bsl; } 2>/dev/null < "$bsdir/today-summary.txt" || true
  case "$bsl" in
    "ALARM build_share"*) bs="🔴 build ${bsn}% <50%" ;;
    *) bs="build ${bsn}%" ;;
  esac
fi

out="$model"
[ -n "$ctx" ] && out="$out · $ctx"
[ -n "$bs" ] && out="$out · $bs"
printf '%s' "$out"
