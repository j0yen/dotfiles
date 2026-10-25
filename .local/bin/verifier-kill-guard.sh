#!/usr/bin/env bash
# verifier-kill-guard.sh: PreToolUse(Bash) hook for aide-verifier units (registered only through the unit's own settings.json, so it never touches other sessions).
# Denies (exit 2) a Bash command that kills by pattern: pkill, killall, `xargs kill`, or `kill` with any argument that is not a PID, signal or $var.
# Why: a verifier ran `pkill -f 'wm-verify-run'` on 10-24 11:05 PM and killed every seat's suite on carbon. Allowed: `kill 12345`, `kill -9 $pid`.
set -u
cmd="$(jq -r '.tool_input.command // ""' 2>/dev/null)"
deny() { echo "verifier-kill-guard: refused ($1). Kill only PIDs you started, or stop your own unit with: systemctl --user stop <your unit>." >&2; exit 2; }
grep -qE '(^|[^[:alnum:]_.-])(pkill|killall)([^[:alnum:]_-]|$)' <<<"$cmd" && deny "pkill/killall"
grep -qE 'xargs[[:space:]]+([^[:space:]|;&]+[[:space:]]+)*kill([^[:alnum:]_-]|$)' <<<"$cmd" && deny "xargs kill"
while IFS= read -r m; do
  m="${m#"${m%%[![:space:];&|(\`]*}"}"       # drop the leading separator
  args="${m#kill}"
  for a in $args; do
    a="${a//[\"\']/}"
    case "$a" in
      -[0-9]*|-[A-Z]*|-l|-s|-n|[0-9]*|%*|'$'[A-Za-z_{!?]*|SIG*|[A-Z]*) ;;
      *) deny "kill with pattern argument '$a'" ;;
    esac
  done
done < <(grep -oE '(^|[;&|(`[:space:]])kill([[:space:]]+[^;&|)`]*)?' <<<"$cmd")
exit 0
