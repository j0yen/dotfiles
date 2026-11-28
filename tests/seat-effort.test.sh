#!/usr/bin/env bash
# effort is a trial-tracked setting: see ~/.claude/state/trials.json (seat-effort-high-82); approvals #82 reverted trial #39 (medium)
# Joe 10-26 11:5x PM "yes, run the check and trial medium" (approvals #39); trial ends 2026-10-28 12:00 AM, keep if Fable correction rate flat
# Seats (ctl, rb, r7) run at medium effort via env CLAUDE_CODE_EFFORT_LEVEL in their --settings files (the user settings modelSettings say high; the env overrides it).
# Model stays claude-opus-5-5. The aide (settings.local.json), coders and coder-opus are untouched. Revert = delete the env key from both files and this test.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { if [ "$2" = 0 ]; then echo "ok - $1"; else echo "NOT OK - $1"; fail=1; fi; }
for f in settings.json ctl-settings.json; do
  [ "$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL' "$here/.config/claude-seat/$f")" = high ]; ok "$f (rb/r7 or ctl) effort high" $?
done
A="$HOME/.claude/settings.local.json"
if [ -f "$A" ]; then [ "$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL // "unset"' "$A")" = unset ]; ok "aide settings.local.json effort untouched" $?; else echo "skip - no $A"; fi
# 3d7f6fd (A1300 model/effort rollout, E1) replaced "seat-tick.sh argv carries no --effort": rb/r7 ticks now pass --effort read from seat-model-hold.json
# through seat_hold_effort (tests/seat-model-rollout.test.sh E1). Kept here: that is the only --effort in seat-tick.sh, scoped to rb|r7, never a hard-coded level.
ef="$(grep -n -- '--effort' "$here/.local/bin/seat-tick.sh")"
[ -n "$ef" ] && ! grep -v 'rb|r7) _ef="$(seat_hold_effort "$ROLE")"' <<<"$ef" | grep -q . && ! grep -qE -- '--effort[ "]+(low|medium|high|xhigh|max)' <<<"$ef"
ok "seat-tick.sh --effort comes only from seat_hold_effort for rb|r7 (no hard-coded level, ctl tick unchanged)" $?
exit $fail
