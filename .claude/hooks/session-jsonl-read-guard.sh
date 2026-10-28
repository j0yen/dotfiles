#!/usr/bin/env bash
# session-jsonl-read-guard.sh — PreToolUse hook (Bash, Read, Grep): refuse raw reads of truth-tier session JSONL
# (ctl e16d, 10-23 11:5x: a raw grep of an orch session file printed a claim-URL prefix from a signup response; those
# lines carry tenant keys, handoff tokens and claim URLs). The only way to read them is
# $HOME/.claude/hooks/session-read.sh (filtered; --counts for shape-only scans). Exit 2 + one stderr line = refuse.
#
# A "matched" text mentions `truth-tier`, or `sessions/` followed by `.jsonl` (also .jsonl.gz, .jsonl.1).
#  Bash: strip quotes/backslashes (so ssh '...' wrappers are transparent), join heredoc bodies onto their command line,
#   split on ; && || | & newline; strip a leading `ssh [opts] host`. Every segment that is matched must BEGIN with the
#   EXACT path of session-read.sh ($HOME/.claude/hooks/ or the old $HOME/.cache/r7-seat/ shim; ~, $HOME, ${HOME}, absolute
#   forms; never a basename or ./relative) or with ls / wc / find, and contain no -exec/-execdir/-ok/-okdir/-delete/-fprint,
#   xargs, $(, backtick, process substitution, or `<` (except `wc -l < path`). Unmatched segments are free, except that
#   next to a matched segment an unmatched xargs/shell/loop/interpreter segment is refused (it could consume a listing).
#  Read: file_path matched. Grep: path/glob matched, or path under synthorg state (a bare synthorg checkout is allowed).
#  Every interpreter (python/perl/ruby/node/sqlite3/awk...) reading a matched path is refused; no marker comment bypass.
# Heuristic, not a proof. KNOWN RESIDUAL: a remote script file (`ssh orch bash ~/x.sh`) is invisible to this hook, and so is a
# path assembled from pieces. Cost: a command that merely MENTIONS truth-tier (git commit -m, echo) is refused; use --body-file.
# bash + sed-free parameter expansion only (no jq, no network); runs well under 50 ms.
IFS= read -r -d '' in
case $in in *truth-tier*|*sessions*|*synthorg*) ;; *) exit 0 ;; esac
in=${in//\\\//\/}
re_tool='"tool_name"[[:space:]]*:[[:space:]]*"([A-Za-z_]+)"'
[[ $in =~ $re_tool ]] || exit 0
tool=${BASH_REMATCH[1]}
home=${HOME:-/nonexistent}
nl=$'\n'
msg='session-jsonl-read-guard: raw read of truth-tier session JSONL refused; use ~/.claude/hooks/session-read.sh <path> (or --counts <path> for shape-only counts)'
refuse() { printf '%s\n' "$msg" >&2; exit 2; }
# a text is "matched" when it names truth-tier or a sessions/...jsonl path
matched() { [[ $1 == *truth-tier* || $1 =~ sessions/.*\.jsonl ]]; }
field() { # field <key>: sets FV to the JSON-unescaped string value of the first "key":"..." in the hook input; rc 1 if absent (no subshell: speed)
  FV=
  local re='"'$1'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"' v
  [[ $in =~ $re ]] || return 1
  v=${BASH_REMATCH[1]}
  v=${v//\\\\/$'\x01'}; v=${v//\\n/$nl}; v=${v//\\t/ }; v=${v//\\r/ }; v=${v//\\\"/\"}
  v=${v//\\u0026/&}; v=${v//\\u003c/<}; v=${v//\\u003e/>}; v=${v//\\u0027/\'}
  FV=${v//$'\x01'/\\}
}
case $tool in
  Read)
    field file_path; matched "$FV" && refuse
    exit 0 ;;
  Grep)
    field path; p=$FV; field glob; g=$FV
    t="$p $g"
    matched "$t" && refuse
    [[ $p == *synthorg* && ( $p == */state/* || $p == *sessions* || $t == *jsonl* ) ]] && refuse
    [[ $g == *jsonl* && $p == *synthorg* ]] && refuse
    exit 0 ;;
  Bash) ;;
  *) exit 0 ;;
esac
field command || { matched "$in" && refuse; exit 0; }
cmd=$FV
matched "$cmd" || exit 0
# join heredoc bodies onto the command line that opened them (body separators masked so the body stays one segment)
joined=; hd=
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$hd" ]; then
    t=${line#"${line%%[![:space:]]*}"}
    if [ "$t" = "$hd" ]; then hd=; else line=${line//[;&|]/ }; joined+=" $line"; fi
    continue
  fi
  joined+="$nl$line"
  re_hd='<<-?[[:space:]]*[\\]?["'\'']?([A-Za-z_][A-Za-z0-9_]*)'
  [[ $line =~ $re_hd ]] && hd=${BASH_REMATCH[1]}
done <<<"$cmd"
c=${joined//[\'\"\\]/}
c=${c//&&/$nl}; c=${c//||/$nl}; c=${c//;/$nl}; c=${c//|/$nl}; c=${c//&/$nl}
allow1="$home/.claude/hooks/session-read.sh"; allow2="$home/.cache/r7-seat/session-read.sh"
any_matched=0; pending_bad=0
while IFS= read -r seg; do
  seg=${seg#"${seg%%[![:space:]]*}"}
  [ -n "$seg" ] || continue
  if ! matched "$seg"; then
    read -r w _ <<<"$seg"
    case ${w##*/} in xargs|sh|bash|zsh|dash|parallel|while|for|do|eval|source|.|exec|python*|perl|ruby|node|awk|gawk|sqlite3) pending_bad=1 ;; esac
    continue
  fi
  any_matched=1
  # strip a leading ssh [opts] host so the remote command is judged
  if [[ $seg == ssh[[:space:]]* ]]; then
    read -ra ws <<<"$seg"; i=1
    while [ $i -lt ${#ws[@]} ]; do
      case ${ws[i]} in
        -[oipJlFbcEeLRDmOQSWw]) i=$((i+2)) ;;
        -*) i=$((i+1)) ;;
        *) break ;;
      esac
    done
    i=$((i+1)); seg=${ws[*]:i}
    [ -n "$seg" ] || continue
    matched "$seg" || continue
  fi
  case $seg in
    *'$('*|*'`'*|*'<('*|*'>('*|*xargs*|*' -exec'*|*' -ok'*|*' -delete'*|*' -fprint'*) refuse ;;
  esac
  read -r first _ <<<"$seg"
  # shellcheck disable=SC2088  # the ~ forms are literal command text
  case $first in
    "$allow1"|"$allow2"|'~/.claude/hooks/session-read.sh'|'~/.cache/r7-seat/session-read.sh'|'$HOME/.claude/hooks/session-read.sh'|'$HOME/.cache/r7-seat/session-read.sh'|'${HOME}/.claude/hooks/session-read.sh'|'${HOME}/.cache/r7-seat/session-read.sh')
      [[ $seg == *'<'* ]] && refuse ;;
    ls|find) [[ $seg == *'<'* ]] && refuse ;;
    wc) if [[ $seg == *'<'* ]]; then [[ $seg =~ ^wc[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*\<[[:space:]]*[^[:space:]\<]+([[:space:]]+[0-9]*\>.*)?$ ]] || refuse; fi ;;
    *) refuse ;;
  esac
done <<<"$c"
[ "$any_matched" = 1 ] && [ "$pending_bad" = 1 ] && refuse
exit 0
