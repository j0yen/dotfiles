#!/usr/bin/env bash
# tooling-budget.sh — coder-spawn refusal at 100 % of the tooling budget (Joe 10-29 approvals #62, goal.md § Stage TOOLING BUDGET).
# Tooling repos (j0yen/swarm-decide, j0yen/dotfiles, j0yen/wm-build) get at most 5 % of the week's weighted tokens;
# token-ledger writes tooling_share (fraction) into build-share.json and alarms at 4 %, this lib refuses at 5 %.
# Sourced by .local/bin/rb-run-coder.sh (the only coder launcher in dotfiles; r7 has none of its own, so this lib is its hook point).
#   tb_brief_repo BRIEF   -> owner/repo of the brief's first `git clone <github url>` (nothing when the brief clones nothing)
#   tb_is_tooling_repo R  -> rc 0 when owner/repo is a tooling repo
#   tb_check BRIEF        -> rc 0 = spawn allowed, rc 4 = REFUSED (message on stdout); WARN lines go to stdout too
# Fail-open on purpose: a missing or > 2 h old build-share.json (the ledger timer is 15 min) prints `WARN tooling-budget unknown`
# and allows the spawn, so a stale file never blocks product coders. Product repos are never refused or warned.
# env: TOOLING_BUDGET_JSON (default ~/.cache/token-ledger/build-share.json), TOOLING_BUDGET_MAX_AGE_S (default 7200).

TB_REPOS_RE='^j0yen/(swarm-decide|dotfiles|wm-build)$'

tb_brief_repo() {
  grep -m1 -oE 'git clone[^|;&]*github\.com[/:][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$1" 2>/dev/null \
    | sed -E 's#.*github\.com[/:]##; s#\.git$##'
}

tb_is_tooling_repo() { [[ "$1" =~ $TB_REPOS_RE ]]; }

tb_check() {
  local repo json age share max="${TOOLING_BUDGET_MAX_AGE_S:-7200}"
  repo="$(tb_brief_repo "$1")"
  tb_is_tooling_repo "$repo" || return 0
  json="${TOOLING_BUDGET_JSON:-$HOME/.cache/token-ledger/build-share.json}"
  if [ ! -r "$json" ]; then echo "WARN tooling-budget unknown (no $json)"; return 0; fi
  age=$(( $(date +%s) - $(stat -c %Y -- "$json" 2>/dev/null || echo 0) ))
  if [ "$age" -gt "$max" ]; then echo "WARN tooling-budget unknown ($json is ${age}s old > ${max}s)"; return 0; fi
  share="$(jq -r '.tooling_share // empty' "$json" 2>/dev/null)"
  if ! [[ "$share" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "WARN tooling-budget unknown (no tooling_share in $json)"; return 0; fi
  if awk -v s="$share" 'BEGIN{exit !(s >= 0.05)}'; then
    echo "REFUSED tooling-budget share=$share >= 0.05 (goal.md TOOLING BUDGET, approvals #62)"; return 4
  fi
  return 0
}
