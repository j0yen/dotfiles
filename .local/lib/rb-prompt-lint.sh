#!/usr/bin/env bash
# rb-prompt-lint.sh - prompt lints for rb-run-coder.sh (source it; defines rb_prompt_pair_lint).
# rb_prompt_pair_lint FILE: rc 1 (+ one stderr line per offender) when a logical line holds a `wm-decide record`
# (or `"$WMD" record`) command carrying BOTH a --pr and a --target token; rc 0 otherwise. wm-decide refuses that pair
# (v347r 10-23: `refused: --target host=redbaron contradicts --pr wm-build#347`). Logical line = physical lines joined
# across a trailing backslash (trailing spaces/tabs and CRLF tolerated); N = its first physical line; comment-only lines skipped.
# Known limit: a command assembled from variables passes; wm-decide's own refusal stays the backstop.
rb_prompt_pair_lint() {
  local f=${1:?usage: rb_prompt_pair_lint FILE} line cur="" start=0 n=0 rc=0
  local re_rec='(wm-decide|"\$WMD"|\$WMD|\$\{WMD\})[[:space:]]+record([[:space:]]|$)'
  local re_pr='(^|[[:space:]])--pr([[:space:]=]|$)' re_tg='(^|[[:space:]])--target([[:space:]=]|$)'
  _rb_pl_check() {
    [[ $cur =~ ^[[:space:]]*# ]] && return 0
    [[ $cur =~ $re_rec && $cur =~ $re_pr && $cur =~ $re_tg ]] || return 0
    echo "line $start: --target with --pr (wm-decide refuses the pair; drop --target)" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); line=${line%$'\r'}
    [ -z "$cur" ] && start=$n
    if [[ $line =~ \\[[:space:]]*$ ]]; then
      cur+="${line%\\*} "
    else
      cur+="$line"; _rb_pl_check || rc=1; cur=""
    fi
  done < "$f"
  [ -n "$cur" ] && { _rb_pl_check || rc=1; }
  unset -f _rb_pl_check
  return $rc
}
