#!/usr/bin/env bash
# SessionStart hook: in an rb/r7/ctl seat (tmux session named rb, r7 or ctl),
# print goal.md § Stage and the fleet-operations playbook so the seat starts on
# the current stage without anyone remembering to paste it. In a NON-tmux session
# on carbon (the aide, Joe's channel) print the short AIDE CARD instead. Silent elsewhere.
# PREMISE: seats are identified by WM_SEAT (systemd units) or tmux session names; the seats live in tmux sessions named rb/r7/ctl on carbon (CLAUDE.md § Hosts); the aide is the non-tmux carbon session.
set -u
aide_card() {  # <= 8 lines; every source optional; never fails
  local fd="$HOME/.cache/fleet-dash" tmr=disabled lt=none last fs fsl age tick ts tt
  [ "$(timeout 5 systemctl --user is-enabled seat-tick@ctl.timer 2>/dev/null)" = enabled ] && tmr=enabled
  lt=$(timeout 5 jq -r '.last_tick.epoch // empty' "$fd/ctl-tick.json" 2>/dev/null); [ -n "$lt" ] && lt=$(date -d "@$lt" '+%-I:%M %p' 2>/dev/null); [ -n "$lt" ] || lt=none
  echo "=== AIDE CARD (carbon, this session is Joe's channel) ==="
  echo "role: aide · controller: unit seat-tick@ctl (timer: $tmr, last tick: $lt) · approvals: ~/.claude/state/approvals.log (writer: approve.sh \"<quote>\" \"<re>\")"
  last=$(timeout 5 "$HOME/.local/bin/approve.sh" --last 2 2>/dev/null | cut -c1-200)
  if [ -n "$last" ] && [ "$last" != none ]; then
    echo "last approvals: $(printf '%s\n' "$last" | head -n1)"; printf '%s\n' "$last" | sed -n '2p' | sed 's/^/                /'
  else echo "last approvals: none"; fi
  fs="$fd/fleet-status.md"
  if [ -r "$fs" ]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$fs" 2>/dev/null || date +%s) ) / 60 )); fsl=$(head -n1 "$fs" 2>/dev/null | cut -c1-140)
    echo "fleet-status.md: $age min old · $fsl"
  else echo 'fleet-status.md: absent: ask jsy-f1 for a digest'; fi
  tick="$fd/ctl-tick.json"
  if [ -r "$tick" ]; then
    ts=$(timeout 5 jq -r '.ticks_skipped // empty' "$tick" 2>/dev/null); tt=$(timeout 5 jq -r '.sends_total // empty' "$tick" 2>/dev/null)
    if [ -n "$ts" ] && [ -n "$tt" ]; then echo "ctl tick: $ts/$tt from ~/.cache/fleet-dash/ctl-tick.json"; else echo "ctl tick: unreadable ~/.cache/fleet-dash/ctl-tick.json"; fi
  else echo "ctl tick: no tick state"; fi
}
# Seat identity: env WM_SEAT (rb|r7|ctl; systemd-unit seats, no tmux) FIRST, else the tmux session name.
case "${WM_SEAT:-}" in rb|r7|ctl) sess="$WM_SEAT" ;; *) sess="" ;; esac
if [ -z "$sess" ]; then
  if [ -z "${TMUX:-}" ]; then
    [ "$(hostname 2>/dev/null)" = carbon ] && aide_card
    exit 0
  fi
  sess=$(tmux display-message -p '#S' 2>/dev/null) || exit 0
fi
case "$sess" in rb|r7|ctl) ;; *) exit 0 ;; esac
goal="$HOME/Notes/wiki/goal.md"
play="$HOME/Notes/wiki/playbooks/fleet-operations.md"
echo "=== goal.md § Stage (seat $sess; read goal.md after a ff-only pull before acting on it) ==="
if [ -r "$goal" ]; then
  awk '/^## Stage/{p=1} p&&/^## /&&!/^## Stage/{exit} p' "$goal"
else
  echo "goal.md missing at $goal"
fi
echo "=== wiki/playbooks/fleet-operations.md ==="
if [ -r "$play" ]; then cat "$play"; else echo "playbook missing at $play"; fi
