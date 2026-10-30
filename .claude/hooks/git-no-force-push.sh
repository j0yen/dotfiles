#!/usr/bin/env bash
# PreToolUse(Bash) hook, active in EVERY session (no WM_SEAT gate): deny force pushes and history rewrites.
# Joe 10-29 11:1x PM "why force push?"; CLAUDE.md § Authorization: NEVER force push or rewrite history.
# Parsing: a quote-aware tokenizer splits the command line into simple-command segments on ; & | ( ) ` and newlines.
# `git` must be the COMMAND WORD of its segment (after VAR=val, env/command/nohup/exec/xargs/sudo/timeout wrappers),
# so `echo git push --force` and `grep -- --force file` ALLOW. The bodies of `bash -c`, `sh -c`, `eval` and `ssh <host>`
# are re-parsed recursively as their own command line. `-f` belonging to another command (`rm -f x && git push ...`) never denies.
# Fail open: non-JSON stdin or no command field exits 0 silently, never 2.
# `--selftest` runs the built-in fixture table (same lists as tests/git-no-force-push.test.sh).
set -euo pipefail

REASON='NEVER force push (Joe 10-29 \"why force push?\", CLAUDE.md): use a real merge of origin/main'
SEP=$'\x01SEP'
NFP_MATCH=""
FORCE_ALIAS_RE='(^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--force[a-z-]*|--mirror|\+[^[:space:]])'

_cur=""; _have=0
TOKS=()

_flush() { if [ "$_have" -eq 1 ]; then TOKS+=("$_cur"); fi; _cur=""; _have=0; }

# tokenize <string> -> TOKS (quotes removed, separators as $SEP)
tokenize() {
  local s=$1 i=0 n=${#1} c q="" nx
  TOKS=(); _cur=""; _have=0
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""; else _cur+=$c; fi
    elif [ "$q" = '"' ]; then
      if [ "$c" = '"' ]; then q=""
      elif [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then i=$((i + 1)); _cur+=${s:i:1}
      else _cur+=$c; fi
    else
      case "$c" in
        "'") q="'"; _have=1 ;;
        '"') q='"'; _have=1 ;;
        '\')
          if [ $((i + 1)) -lt "$n" ]; then
            nx=${s:i+1:1}; i=$((i + 1))
            if [ "$nx" != $'\n' ]; then _cur+=$nx; _have=1; fi
          fi ;;
        ' '|$'\t') _flush ;;
        ';'|'&'|'|'|$'\n'|'('|')'|'`') _flush; TOKS+=("$SEP") ;;
        *) _cur+=$c; _have=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  _flush
}

hit() { NFP_MATCH=$1; return 0; }

force_alias() { [[ $1 == *push* ]] && [[ $1 =~ $FORCE_ALIAS_RE ]]; }

is_protected_ref() {
  case "$1" in main|master|refs/heads/main|refs/heads/master) return 0 ;; esac
  return 1
}

scan_push() {
  local t delete=0 p ref
  local -a pos=()
  for t in "$@"; do
    case "$t" in
      --force|-f|--force-with-lease|--force-with-lease=*|--force-if-includes|--mirror) hit "$t"; return 0 ;;
      --delete|-d) delete=1 ;;
      --*) ;;
      -?*)
        if [[ $t =~ ^-[a-zA-Z]+$ ]] && [[ $t == *f* ]]; then hit "$t"; return 0; fi ;;
      +*) hit "$t"; return 0 ;;
      :*)
        ref=${t#:}
        if is_protected_ref "$ref"; then hit "$t"; return 0; fi ;;
      *) pos+=("$t") ;;
    esac
  done
  if [ "$delete" -eq 1 ] && [ "${#pos[@]}" -gt 0 ]; then
    for p in "${pos[@]}"; do
      if is_protected_ref "$p"; then hit "--delete $p"; return 0; fi
    done
  fi
  return 1
}

scan_git() {
  local -a a=("$@")
  local i=0 n=$# t v sub joined
  while [ "$i" -lt "$n" ]; do
    t=${a[i]}
    case "$t" in
      -c)
        v=${a[i + 1]:-}
        if [[ $v == alias.*=* ]] && force_alias "${v#*=}"; then hit "alias"; return 0; fi
        i=$((i + 2)) ;;
      -C|--git-dir|--work-tree|--namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  sub=${a[i]}
  case "$sub" in
    filter-branch|filter-repo) hit "$sub"; return 0 ;;
    push) scan_push "${a[@]:i+1}"; return ;;
    config)
      joined="${a[*]:i+1}"
      if [[ $joined == *alias.* ]] && force_alias "$joined"; then hit "alias"; return 0; fi ;;
  esac
  return 1
}

scan_seg() {
  local -a a=("$@")
  local i=0 n=$# w base t
  # leading VAR=val, shell keywords and command wrappers
  while [ "$i" -lt "$n" ]; do
    w=${a[i]}
    if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
    base=${w##*/}
    case "$base" in
      do|then|else|elif|if|while|until|'!'|'{'|time) i=$((i + 1)) ;;
      env|command|nohup|exec|sudo)
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && { [[ ${a[i]} == -* ]] || [[ ${a[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }; do i=$((i + 1)); done ;;
      xargs)
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [[ ${a[i]} == -* ]]; do
          case "${a[i]}" in -I|-n|-P|-L|-d|-E|-s) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac
        done ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [[ ${a[i]} == -* ]]; do i=$((i + 1)); done
        i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  w=${a[i]}; base=${w##*/}
  case "$base" in
    git) scan_git "${a[@]:i+1}"; return ;;
    git-filter-repo) hit "git-filter-repo"; return 0 ;;
    bash|sh|zsh|dash|ksh)
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        t=${a[i]}
        if [[ $t =~ ^-[a-zA-Z]*c[a-zA-Z]*$ ]]; then
          [ $((i + 1)) -lt "$n" ] || return 1
          scan_cmd "${a[i + 1]}"; return
        fi
        [[ $t == -* ]] || return 1
        i=$((i + 1))
      done ;;
    eval) scan_cmd "${a[*]:i+1}"; return ;;
    ssh)
      i=$((i + 1))
      while [ "$i" -lt "$n" ] && [[ ${a[i]} == -* ]]; do
        case "${a[i]}" in -p|-i|-l|-o|-F|-J|-L|-R|-D|-b|-c|-E|-e|-S|-W|-w|-m|-O|-B) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac
      done
      i=$((i + 1)) # host
      [ "$i" -lt "$n" ] || return 1
      scan_cmd "${a[*]:i}"; return ;;
  esac
  return 1
}

NFP_DEPTH=0
# scan_cmd <command line>: returns 0 (and sets NFP_MATCH) when any segment is a forbidden git operation
scan_cmd() {
  [ "$NFP_DEPTH" -lt 6 ] || return 1
  NFP_DEPTH=$((NFP_DEPTH + 1))
  tokenize "$1"
  local -a T=("${TOKS[@]}")
  local -a seg=()
  local t rc=1
  for t in "${T[@]}" "$SEP"; do
    if [ "$t" = "$SEP" ]; then
      if [ "${#seg[@]}" -gt 0 ] && scan_seg "${seg[@]}"; then rc=0; break; fi
      seg=()
    else
      seg+=("$t")
    fi
  done
  NFP_DEPTH=$((NFP_DEPTH - 1))
  return $rc
}

log_fire() { # token only, never the full command
  local d=${NFP_STATE_DIR:-$HOME/.local/state/git-no-force-push} tok
  tok=$(printf '%s' "$1" | tr -d '[:cntrl:]' | cut -c1-80)
  # logging must never change the deny itself
  { mkdir -p "$d" && printf '%s | %s | %s\n' "$(date -Iseconds)" "${WM_SEAT:-plain}" "$tok" >> "$d/fires.log"; } 2>/dev/null || return 0
}

emit_deny() { # $1 = reason suffix
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s%s"}}\n' "$REASON" "$1"
}

DENY_FIXTURES=(
  'git push --force origin main' 'git push -f' 'git push -fu origin br' 'git push --force-with-lease'
  'git push --force-with-lease=main:abc origin main' 'git push --force-if-includes origin br'
  'git push origin +main' 'git push origin +HEAD:refs/heads/x' 'git -C /tmp/r push -f origin b'
  'cd x && git push --force' "ssh redbaron 'cd /w && git push -f origin b'"
  'git filter-branch --tree-filter x HEAD' 'git filter-repo --path y' 'git push --mirror'
  'git push origin --delete main' 'git push origin :main' 'env git push -f origin b'
  'bash -c "git push --force"' '/usr/bin/git push -f' 'FOO=1 git push -f'
  "git config alias.fp 'push --force'" "git -c alias.p='push -f' p"
)
ALLOW_FIXTURES=(
  'git push origin br' 'git push -u origin br' 'git push origin br:refs/heads/br' 'rm -f x && git push origin br'
  'git fetch -f origin' 'git commit -m "explain why --force is banned"' 'git push origin --delete feature-x'
  'git push origin :feature-x' 'echo git push --force' 'grep -- --force file'
)

selftest() {
  local pass=0 fail=0 c
  for c in "${DENY_FIXTURES[@]}"; do
    if scan_cmd "$c"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "selftest MISS (should deny): $c" >&2; fi
  done
  for c in "${ALLOW_FIXTURES[@]}"; do
    if scan_cmd "$c"; then fail=$((fail + 1)); echo "selftest FALSE DENY (should allow): $c" >&2; else pass=$((pass + 1)); fi
  done
  echo "git-no-force-push selftest: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

main() {
  local in cmd
  if [ "${1:-}" = "--selftest" ]; then selftest; return; fi
  in=$(cat) || return 0
  if ! command -v jq >/dev/null 2>&1; then
    if printf '%s' "$in" | grep -Eq 'git[^;&|]*push[^;&|]*( -f| --force| --mirror| \+)'; then
      log_fire "(parser missing)"
      emit_deny " (parser missing)"
    fi
    return 0
  fi
  cmd=$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null) || return 0
  [ -n "$cmd" ] || return 0
  if scan_cmd "$cmd"; then
    log_fire "$NFP_MATCH"
    emit_deny ""
  fi
  return 0
}

main "$@"
