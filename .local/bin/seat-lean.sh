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
