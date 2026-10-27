#!/usr/bin/env bash
# SessionStart hook: in an rb/r7/ctl seat (tmux session named rb, r7 or ctl),
# print goal.md § Stage and the fleet-operations playbook so the seat starts on
# the current stage without anyone remembering to paste it. In the aide
# (WM_SEAT=aide, set only by aide-launch.sh) print the short AIDE CARD instead.
# Silent elsewhere, including a plain `claude` on carbon (Joe's own session, 10-23).
# PREMISE: seats are identified by WM_SEAT (systemd units) or tmux session names; the seats live in tmux sessions named rb/r7/ctl on carbon (CLAUDE.md § Hosts); the aide is WM_SEAT=aide.
set -u
aide_card() {  # <= 8 lines; every source optional; never fails
  local fd="$HOME/.cache/fleet-dash" tmr=disabled lt=none last fs fsl age tick ts tt
  [ "$(timeout 5 systemctl --user is-enabled seat-tick@ctl.timer 2>/dev/null)" = enabled ] && tmr=enabled
  lt=$(timeout 5 jq -r '.last_tick.epoch // empty' "$fd/ctl-tick.json" 2>/dev/null); [ -n "$lt" ] && lt=$(date -d "@$lt" '+%-I:%M %p' 2>/dev/null); [ -n "$lt" ] || lt=none
  echo "=== AIDE CARD (carbon, this session is Joe's channel) ==="
  [ "${WM_AIDE_LANE:-main}" = main ] || echo "lane: $WM_AIDE_LANE"   # aide-lanes: non-main lanes only, main's card stays byte-for-byte
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
# Start-trigger check (five-whys 2026-10-24: an empty OnUnitActiveSec= wiped OnBootSec, seat ticks and the regrader never fired after a reboot, nothing alarmed):
# every enabled user timer on carbon + redbaron + ryzen7 must show a start trigger. Prints NOTHING when healthy; a FAIL/SKIP line per problem otherwise.
# Never fails the hook; bounded by timeout; silent when the helper is absent (a host without this dotfiles revision).
timers_check() {
  local h="$HOME/.local/bin/timers-start-trigger-live.sh" out
  [ -x "$h" ] || return 0
  out="$(timeout "${TIMERS_CHECK_TIMEOUT:-35}" "$h" --failures-only --hosts "${TIMERS_CHECK_HOSTS:-carbon redbaron ryzen7}" 2>/dev/null)" || true
  [ -z "$out" ] || { echo "=== TIMERS: user timer(s) without a start trigger (cannot fire after a reboot; fix the drop-in, tests/user-timers-start-trigger.test.sh) ==="; printf '%s\n' "$out" | cut -c1-200; }
  return 0
}
# Seat identity: env WM_SEAT (rb|r7|ctl; systemd-unit seats, no tmux) FIRST, else the tmux session name.
case "${WM_SEAT:-}" in rb|r7|ctl) sess="$WM_SEAT" ;; aide) aide_card; timers_check; exit 0 ;; *) sess="" ;; esac
if [ -z "$sess" ]; then
  [ -z "${TMUX:-}" ] && exit 0
  sess=$(tmux display-message -p '#S' 2>/dev/null) || exit 0
fi
case "$sess" in rb|r7|ctl) ;; *) exit 0 ;; esac
goal="$HOME/Notes/wiki/goal.md"
play="$HOME/Notes/wiki/playbooks/fleet-operations.md"
# M9 stage 1 (decisions/2026-10-27-m9-seat-floor-cut-wwhtbt.md, mechanism 1; OFF unless seat_floor_stage_on 1, i.e. SEAT_FLOOR_STAGE>=1 or floor-stage.json .stage>=1):
# on SessionStart `compact` and `resume` an operator seat (a seats.tsv row with tick_min > 0; the set is the file, never a list here) gets § Stage + goal-lint + two
# pointer lines (playbook path, handoff path) <= 4096 B, never the playbook body, and NO ssh: the start-trigger check reads status.json `timers_no_start_trigger`
# instead of `timers-start-trigger-live.sh --hosts` (35 s of ssh, the reason the hook was cancelled at its 5 s timeout on most resume ticks). The timeout is untouched.
# `resume` prints only a one-line hash note when § Stage is unchanged since this seat's last tick (state: ~/.cache/claude-seat/<seat>.stage-hash). `startup`/`clear`/no source = the full payload below.
if [ -r "$HOME/.local/bin/seat-lean.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.local/bin/seat-lean.sh"
  role=$(awk -F'\t' -v s="$sess" '!/^#/ && $1==s && ($4+0)>0 {print $2; exit}' "$HOME/.claude/state/seats.tsv" 2>/dev/null)
  src=""
  if [ -n "$role" ] && seat_floor_stage_on 1 && [ ! -t 0 ]; then   # stdin is read only when the stage is on: OFF = today's behavior exactly
    src=$(timeout 1 cat 2>/dev/null | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  if [ "$src" = compact ] || [ "$src" = resume ]; then
    stage_txt=""; [ -r "$goal" ] && stage_txt=$(awk '/^## Stage/{p=1} p&&/^## /&&!/^## Stage/{exit} p' "$goal" | head -c 3000)   # 3000 B keeps goal-lint + pointers inside the 4096 B cap
    h=$(printf '%s' "$stage_txt" | sha256sum | cut -c1-12); hf="$HOME/.cache/claude-seat/$sess.stage-hash"
    if [ "$src" = resume ] && [ "$(cat "$hf" 2>/dev/null)" = "$h" ]; then
      echo "=== goal.md § Stage unchanged since this seat's last tick (hash $h); playbook ~/Notes/wiki/playbooks/fleet-operations.md · handoff ~/.claude/projects/-home-jsy/memory/handoff-$role-*.md ==="
      exit 0
    fi
    mkdir -p "${hf%/*}" 2>/dev/null; printf '%s\n' "$h" >"$hf" 2>/dev/null
    {
      echo "=== goal.md § Stage (seat $sess, $src; read goal.md after a ff-only pull before acting on it) ==="
      if [ -n "$stage_txt" ]; then printf '%s\n' "$stage_txt"; else echo "goal.md missing at $goal"; fi
      if [ -x "$HOME/.local/bin/goal-lint.sh" ] && [ -r "$goal" ]; then
        echo "=== goal-lint ==="
        timeout 2 "$HOME/.local/bin/goal-lint.sh" "$goal" 2>&1 | sed 's/^\(goal-lint: \)\{0,1\}/goal-lint: /' || true
      fi
      ho=$(ls -t "$HOME/.claude/projects/-home-jsy/memory"/handoff-"$role"-*.md 2>/dev/null | head -n1)
      echo "=== pointers (not injected on $src; read the section you need before acting) ==="
      echo "playbook: $play"
      echo "handoff: ${ho:-$HOME/.claude/projects/-home-jsy/memory/handoff-$role-*.md (none found)}"
      sj="$HOME/.cache/fleet-dash/status.json"
      if [ -r "$sj" ] && [ $(( $(date +%s) - $(stat -c %Y "$sj" 2>/dev/null || echo 0) )) -le 300 ]; then
        tl=$(timeout 1 jq -r '(.timers_no_start_trigger // []) | .[0:6][] | if type=="string" then . else "FAIL \(.host) \(.unit) \(.reason // "no start trigger")" end' "$sj" 2>/dev/null | cut -c1-160)
        [ -z "$tl" ] || { echo "=== TIMERS: user timer(s) without a start trigger (status.json timers_no_start_trigger) ==="; printf '%s\n' "$tl"; }
      fi
    } | head -c 4096
    exit 0
  fi
fi
echo "=== goal.md § Stage (seat $sess; read goal.md after a ff-only pull before acting on it) ==="
if [ -r "$goal" ]; then
  awk '/^## Stage/{p=1} p&&/^## /&&!/^## Stage/{exit} p' "$goal"
else
  echo "goal.md missing at $goal"
fi
# goal-lint (dotfiles#13): every /goal line must carry the five stop-hook judging properties; a MISSING goal is the
# owning seat's defect, so the seat sees its line every tick. Never fails the hook; silent when the linter is absent.
if [ -x "$HOME/.local/bin/goal-lint.sh" ] && [ -r "$goal" ]; then
  echo "=== goal-lint (P1 final-message-only · P2 STATUS block · P3 unmeasured passes · P4 WAIT form · P5 never require/forbid) ==="
  "$HOME/.local/bin/goal-lint.sh" "$goal" 2>&1 | sed 's/^\(goal-lint: \)\{0,1\}/goal-lint: /' || true   # one prefix whether or not the linter adds its own
fi
echo "=== wiki/playbooks/fleet-operations.md ==="
if [ -r "$play" ]; then cat "$play"; else echo "playbook missing at $play"; fi
timers_check
