#!/usr/bin/env bash
# Seats (ctl, rb, r7) auto-compact at 120K = 240000 x 50 % (Joe 10-26 "go c and a" #31, amended "yes, set 120K" #32; 80K thrashed, post-compaction p50 72-83K).
# The aide stays at 360000 x 50 % = 180K. Window and pct are always changed together.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
chk() { # name file expected
  local w p
  w=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$2"); p=$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$2")
  if [ "$(( w * p / 100 ))" = "$3" ]; then echo "ok - $1: $w x $p % = $3"; else echo "NOT OK - $1: $w x $p % != $3"; fail=1; fi
}
chk "ctl-settings.json" "$here/.config/claude-seat/ctl-settings.json" 120000
chk "rb/r7 settings.json" "$here/.config/claude-seat/settings.json" 120000
A="$HOME/.claude/settings.local.json"
if [ -f "$A" ]; then chk "aide settings.local.json" "$A" 180000; else echo "skip - no $A (aide pin not on this host)"; fi
exit $fail
