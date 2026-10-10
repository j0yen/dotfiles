#!/usr/bin/env bash
# statusline.sh — model · context used% (warn ≥50% = ~100K on a 200K window) · PRD counts.
# GATES, TOKENS, and cost fields removed 2026-10-06 (Joe: not useful).
# PRD counts added 2026-10-09 (Joe: "live count on the number of prds being built and the number in queue"):
#   🔨 N = open daemon runs, 📋 N = eligible PRDs in the queue, read from a cache file that
#   statusline-prd-counts.sh refreshes in the background every ≤30 s — only on the host whose
#   wm-build daemon is alive, so another node never shows a stale clone's numbers.
# PRDs/hour added 2026-10-09 (Joe: "add PRDs/hour over last 6 hours"): 🚀 <shipped6/6>/h (<shipped6>/6h), shipped =
#   `wm-build ledger --since 6h` shipped (runs tagged in the window, at/after archived; fixed in 0.73.4 #195).
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

prd=""
pidfile="$HOME/.local/state/wm-build/daemon.pid"
if [ -r "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  cache="$HOME/.cache/wm-build-statusline/counts"
  now=$(date +%s); ts=0
  if [ -r "$cache" ]; then
    read -r b q s t tt <"$cache"
    building=${b#building=}; queued=${q#queued=}; shipped=${s#shipped6=}; ts=${t#ts=}; total=${tt#total=}
    rate=$(awk -v n="${shipped:-0}" 'BEGIN{printf "%.2f", n/6}')
    age=$(( now - ts ))
    stale=""; [ "$age" -gt 180 ] && stale=" (${age}s old)"
    prd="🔨 ${building} building · 📋 ${queued} ready/${total:-?} queued · 🚀 ${rate}/h (${shipped}/6h)${stale}"
  fi
  if [ $(( now - ts )) -gt 30 ]; then
    setsid -f "$HOME/.claude/statusline-prd-counts.sh" >/dev/null 2>&1 </dev/null
  fi
fi

out="$model"
[ -n "$ctx" ] && out="$out · $ctx"
[ -n "$prd" ] && out="$out · $prd"
printf '%s' "$out"
