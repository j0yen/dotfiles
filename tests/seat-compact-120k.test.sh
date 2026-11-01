#!/usr/bin/env bash
# Seats (ctl, rb, r7) auto-compact at 120K = 240000 x 50 % (Joe 10-26 "go c and a" #31, amended "yes, set 120K" #32; 80K thrashed, post-compaction p50 72-83K).
# The aide stays at 360000 x 50 % = 180K. Window and pct are always changed together.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
chk() { # name file expected
  local w p
  w=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' "$2"); p=$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE // empty' "$2")
  if [ -z "$w" ] || [ -z "$p" ]; then echo "NOT OK - $1: $2 lacks .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW or CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"; fail=1; return; fi
  if [ "$(( w * p / 100 ))" = "$3" ]; then echo "ok - $1: $w x $p % = $3"; else echo "NOT OK - $1: $w x $p % != $3"; fail=1; fi
}
chk "ctl-settings.json" "$here/.config/claude-seat/ctl-settings.json" 120000
chk "rb/r7 settings.json" "$here/.config/claude-seat/settings.json" 120000
# Aide pin: default = a fixture carrying the aide's documented values (the live $HOME/.claude is never read).
# DOTFILES_LIVE_CHECKS=1 = also check the live aide file, only where it can apply: it carries the keys, or this host is carbon
# (carbon missing keys FAILS; elsewhere SKIP).
T="$(mktemp -d "${TMPDIR:-/tmp}/seat-compact.XXXXXX")"; trap 'rm -rf "$T"' EXIT
printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"360000","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"}}\n' > "$T/aide.json"
chk "aide settings fixture" "$T/aide.json" 180000
printf '{"env":{}}\n' > "$T/nokeys.json"
if [ "$(chk "fixture without keys" "$T/nokeys.json" 180000 2>&1 | head -1 | cut -c1-6)" = "NOT OK" ]; then echo "ok - missing aide keys are reported, not a crash"; else echo "NOT OK - missing aide keys not reported"; fail=1; fi
if [ "${DOTFILES_LIVE_CHECKS:-}" = 1 ]; then
  A="$HOME/.claude/settings.local.json"; host="$(hostname -s)"
  if [ -f "$A" ] && jq -e '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW and .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$A" >/dev/null 2>&1; then chk "aide settings.local.json (live)" "$A" 180000
  elif [ "$host" = carbon ]; then echo "NOT OK - live: no aide keys in $A on carbon"; fail=1
  else echo "SKIP live: no aide keys on $host"; fi
else echo "SKIP live: aide settings.local.json (set DOTFILES_LIVE_CHECKS=1)"; fi
exit $fail
