#!/usr/bin/env bash
# seat-lean.sh — ONE source for the lean launch overlay of the rb/r7 operator seats (10-20 token-cut levers B3/B4, C2/C5).
# Sourced by seat-relaunch.sh (interactive tmux launch) and seat-tick.sh (claude -p tick/ask turns); never run directly.
#   LEAN_ENV_VARS  space-separated K=V env: keeps the decorative SessionStart banners (lean-skip.sh, recall self:, ADHD ruleset) silent
#   LEAN_FLAGS     claude flags: the lean settings overlay (stripe + library-skills plugins off) and an EMPTY mcp config under
#                  --strict-mcp-config (no mcphost). Holds a literal $HOME: seat-relaunch.sh types it into the pane's shell,
#                  seat-tick.sh expands it before exec.
# ctl is NOT lean by design (full hook set, default settings); both callers apply this to roles rb and r7 only.
# `seat-relaunch.sh --drift-test` asserts LEAN_FLAGS appears verbatim in the rb dry-run command line.
LEAN_ENV_VARS="SEAT_LEAN=1 CLAUDE_LEAN_START=1"
LEAN_FLAGS="--settings \$HOME/.config/claude-seat/settings.json --mcp-config \$HOME/.config/claude-seat/mcp.json --strict-mcp-config"
# M9 seat floor cut (decisions/2026-10-27-m9-seat-floor-cut-wwhtbt.md, mechanism 7): ONE flag per stage, nothing else changes when it flips.
#   seat_floor_stage  -> prints the stage in force: env SEAT_FLOOR_STAGE wins, else `.stage` of ~/.config/claude-seat/floor-stage.json, else 0 (OFF = today's behavior).
#   seat_floor_stage_on <n>  -> exit 0 when the stage in force is >= n. Rollback of any stage = lower the number (the flag), no code change.
# Stages: 1 = compact/resume SessionStart payload (seat-context-start.sh), 2 = ctl without mcphost MCP, 3 = seat skill subset, 4 = seat memory index, 5 = summary cap.
seat_floor_stage() {
  local n="${SEAT_FLOOR_STAGE:-}"
  [ -n "$n" ] || n="$(jq -r '.stage // 0' "${SEAT_FLOOR_STAGE_FILE:-$HOME/.config/claude-seat/floor-stage.json}" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
}
seat_floor_stage_on() { [ "$(seat_floor_stage)" -ge "$1" ]; }
