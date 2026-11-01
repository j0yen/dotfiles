#!/usr/bin/env bash
# wmb-agent-search-gate.sh — PreToolUse hook (Bash): refuses whole-tree searches (find/bfs/fd/rg/ugrep/grep -r
# rooted at /, $HOME, an ancestor of the cwd, ~/.local, ~/.cache, ~/.cargo, /mnt/data/hand) from wm-build agents.
# Keys on env WM_BUILD_AGENT=1 (set by wm-build for every inner/land/verifier agent); seats and Joe are untouched.
# 10-30 10:08 AM: a land agent's `bfs -S dfs / -name PRD-...` and `ugrep -rl X . ~/.local/state/wm-build` drove
# RedBaron IO full avg10 to 97. Classifier = wmb-agent-search-gate.py; each refusal appends to
# ~/.cache/wmb-agent-search-gate/fires.log (live evidence the marker reaches the hook). Internal errors allow.
[ "${WM_BUILD_AGENT:-}" = 1 ] || exit 0
python3 -I "$(dirname "$(readlink -f "$0")")/wmb-agent-search-gate.py"
rc=$?
[ "$rc" = 2 ] && exit 2
exit 0
