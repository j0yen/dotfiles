#!/usr/bin/env bash
# statusline.sh — model · context used% (warn ≥50% = ~100K on a 200K window) · TOKENS from token-ledger.
set -uo pipefail
in=$(cat)
model=$(printf '%s' "$in" | jq -r '.model.display_name // .model.id // "?"')
pct=$(printf '%s' "$in" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)
size=$(printf '%s' "$in" | jq -r '.context_window.context_window_size // empty')
cost=$(printf '%s' "$in" | jq -r '.cost.total_cost_usd // empty')
ctx=""
if [ -n "$pct" ]; then
  used_k=""; [ -n "$size" ] && used_k="$(( pct * size / 100000 ))K/"
  if   [ "$pct" -ge 75 ]; then ctx="🔴 ctx ${used_k}${pct}% COMPACT NOW"
  elif [ "$pct" -ge 50 ]; then ctx="⚠ ctx ${used_k}${pct}% >100K — /compact or hand off"
  else ctx="ctx ${used_k}${pct}%"; fi
fi
tok=""
s="$HOME/.cache/token-ledger/today-summary.txt"
[ -r "$s" ] && tok=$(sed -n 's/^TOKENS yesterday [0-9-]*: \([0-9]*\).*today so far \([0-9]*\).*forecast \([0-9]*\).*/TOKENS y=\1 today=\2 fc=\3/p' "$s")
out="$model"
[ -n "$ctx" ] && out="$out · $ctx"
[ -n "$cost" ] && out="$out · \$$(printf '%.2f' "$cost")"
[ -n "$tok" ] && out="$out · $tok"
printf '%s' "$out"
