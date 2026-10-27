#!/usr/bin/env bash
# Joe 10-26 11:5x PM "yes, run the check and trial medium" (approvals #39); trial ends 2026-10-28 12:00 AM, keep if Fable correction rate flat
# Seats (ctl, rb, r7) run at medium effort via env CLAUDE_CODE_EFFORT_LEVEL in their --settings files (the user settings modelSettings say high; the env overrides it).
# Model stays claude-opus-5-5. The aide (settings.local.json), coders and coder-opus are untouched. Revert = delete the env key from both files and this test.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "NOT OK - $1"; fail=1; fi; }
for f in settings.json ctl-settings.json; do
  [ "$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL' "$here/.config/claude-seat/$f")" = medium ]; ok "$f (rb/r7 or ctl) effort medium" $?
done
A="$HOME/.claude/settings.local.json"
if [ -f "$A" ]; then [ "$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL // "unset"' "$A")" = unset ]; ok "aide settings.local.json effort untouched" $?; else echo "skip - no $A"; fi
! grep -q -- '--effort' "$here/.local/bin/seat-tick.sh"; ok "seat-tick.sh argv carries no --effort (argv tests unchanged)" $?
exit $fail
