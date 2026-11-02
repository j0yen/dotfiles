#!/usr/bin/env bash
# claude-operated.sh: list rules whose gear pointer resolves to nothing (L5 claude_operated[]).
#   claude-operated.sh [--roots "dir dir"] [--alarms file] <page.md>...   prints a JSON array of {page,line,pointer}
# A pointer is the first path-like token after a gear mark (U+2699) on a line: contains a slash or ends .sh .py .timer .service .json .tsv.
# It resolves when the token exists under any root (default: $HOME, $HOME/.claude, $HOME/.local/bin, $HOME/.claude/hooks, $HOME/dotfiles).
# A line matching an `exempt` pattern in the alarms file (judgment, money, real-users-data) is not listed.
set -u
ROOTS="$HOME $HOME/.claude $HOME/.local/bin $HOME/.claude/hooks $HOME/dotfiles"
ALARMS="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)/.config/fleet/alarms.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --roots) ROOTS="$2"; shift 2 ;;
    --alarms) ALARMS="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "usage: claude-operated.sh [--roots 'dirs'] [--alarms file] page..." >&2; exit 64 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: claude-operated.sh [--roots 'dirs'] [--alarms file] page..." >&2; exit 64; }
EX=""
[ -r "$ALARMS" ] && EX="$(jq -r '.exempt[].match' "$ALARMS" 2>/dev/null | paste -sd'|')"
out="[]"
for page in "$@"; do
  [ -r "$page" ] || continue
  n=0
  while IFS= read -r line; do
    n=$((n+1))
    case "$line" in *⚙*) ;; *) continue ;; esac
    [ -n "$EX" ] && printf '%s' "$line" | grep -Eqi "$EX" && continue
    tok="$(printf '%s' "${line#*⚙}" | tr -s ' ,;()`' '\n' | grep -E '/|\.(sh|py|timer|service|json|tsv)$' | head -n1)"
    [ -n "$tok" ] || continue
    tok="${tok#\~/}"; tok="${tok%%:*}"; tok="${tok%.}"
    found=0
    for r in $ROOTS; do [ -e "$r/$tok" ] && { found=1; break; }; done
    [ -e "$tok" ] && found=1
    [ "$found" = 1 ] || out="$(printf '%s' "$out" | jq -c --arg p "$page" --argjson l "$n" --arg t "$tok" '. + [{page:$p,line:$l,pointer:$t}]')"
  done <"$page"
done
printf '%s\n' "$out"
