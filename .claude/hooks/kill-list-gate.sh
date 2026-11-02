#!/usr/bin/env bash
# kill-list-gate.sh — PreToolUse hook (Bash): a command that reaches a build host
# (ssh redbaron|ryzen7) may not kill a COMPUTED pid list (kill $var, kill $(…),
# xargs kill, pkill/killall). Use rb-kill-tree.sh <pid> (descendants of one pid,
# refuses pid<1000/systemd/wm-build). Born of d-20261022-225246-rb-d26f (10-22
# 10:47 PM: an awk ppid list SIGTERMed RedBaron's user manager).
# Escape hatch (one call): touch ~/.claude/.allow-kill-list
set -u
if [ -e "$HOME/.claude/.allow-kill-list" ]; then rm -f "$HOME/.claude/.allow-kill-list"; exit 0; fi
cmd=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || exit 0
grep -qE 'ssh[^|;&]*\b(redbaron|ryzen7)\b' <<<"$cmd" || exit 0
grep -q 'rb-kill-tree.sh' <<<"$cmd" && exit 0
if grep -qE '(\bkill\b(\s+-[A-Za-z0-9]+)*\s+("?\$)|\bxargs\s+(-\S+\s+)*kill\b|\bpkill\b|\bkillall\b)' <<<"$cmd"; then
  cat >&2 <<MSG
kill-list-gate: no computed pid lists, pkill or killall on a build host.
Use: ssh <host> 'bash /mnt/data/hand/rb-kill-tree.sh <pid>' (dry run), then add --yes.
Escape hatch (one call): touch ~/.claude/.allow-kill-list
MSG
  exit 2
fi
exit 0
