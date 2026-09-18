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
# GATES field (PRD-build-gate-red-alarm-invariant R6): red-gate state,
# read from the same file gates-banner.sh's SessionStart hook keeps
# fresh — this script never ssh's itself (statusline fires on every
# render; a network call here would be far too slow). On RedBaron reads
# the skill's own state directly; elsewhere reads gates-banner.sh's
# ~/.cache/gate-red.summary cache, which may be up to its own 10-minute
# TTL stale — acceptable for a statusline field, never gating.
gates=""
on_rb=0
if [ "$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')" = "redbaron" ]; then
  on_rb=1; g="$HOME/.claude/skills/build/state/gate-red.summary"
else
  g="$HOME/.cache/gate-red.summary"
fi
# The cache used to refresh only at SessionStart, so a red could sit in the
# status line for hours after RedBaron went green (2026-09-17). Now: refresh
# in the background when older than 10 min (gates-banner.sh owns the fetch),
# and mark the reading stale past 15 min so old state never reads as current.
gage=99999
[ -f "$g" ] && gage=$(( $(date +%s) - $(stat -c %Y "$g" 2>/dev/null || echo 0) ))
gb="$HOME/.claude/hooks/gates-banner.sh"
if [ "$on_rb" = 0 ] && [ "$gage" -gt 600 ] && [ -x "$gb" ]; then
  setsid -f flock -n "$g.lock" bash "$gb" >/dev/null 2>&1 </dev/null || true
fi
if [ -r "$g" ]; then
  r=$(grep -oE 'red=[0-9]+' "$g" | head -1 | cut -d= -f2); gr=$(grep -oE 'green=[0-9]+' "$g" | head -1 | cut -d= -f2)
  stale=""; [ "$gage" -gt 900 ] && stale=" stale $(( gage / 60 ))m"
  if [ -n "$r" ]; then if [ "$r" -gt 0 ]; then gates="🔴 GATES red=$r green=${gr:-0}${stale}"; else gates="GATES green=${gr:-0} red=0${stale}"; fi; fi
fi
out="$model"
[ -n "$ctx" ] && out="$out · $ctx"
[ -n "$gates" ] && out="$out · $gates"
[ -n "$cost" ] && out="$out · \$$(printf '%.2f' "$cost")"
[ -n "$tok" ] && out="$out · $tok"
printf '%s' "$out"
