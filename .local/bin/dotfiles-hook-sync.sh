#!/usr/bin/env bash
# dotfiles-hook-sync.sh - link-only pass of the repo's .claude/hooks into ~/.claude/hooks plus a post-check that every hook the LIVE
# settings files register resolves and is executable on this node. Runs from dotfiles-hook-sync.timer (3 min after boot, every 10 min).
# PREMISE: settings.json registers hooks by absolute path and a pull does not install them
# EXPIRES: 2027-01-31 (past it: result `expired`, exit 2, the unit FAILS so the expiry is loud, never a silent disarm; re-arm = a reviewed edit of EXPIRES)
#
# Link pass (only .claude/hooks/* -> ~/.claude/hooks/*), per target path:
#   missing                                   -> ln -s to the repo file
#   already a symlink into this repo          -> fine
#   a symlink elsewhere, or a real file       -> LEFT ALONE, prints `HOOK-LOCAL <path> <inode-or-link-target>` (not unresolved while it resolves + is executable)
#   Never replaces, moves or deletes anything. (install.sh backs up and replaces a real file, so it is NOT used here.)
# Post-check: ~/.claude/settings.json + settings.local.json (if present) -> every ~/ $HOME/ ${HOME}/ /home/jsy/ .claude/hooks/X token anywhere in
#   any hook command string must be [ -e ] && [ -x ]; each miss prints `HOOK-UNRESOLVED <path>`; exit 3 when any.
# Pull-in-progress guard: ~/dotfiles/.git/index.lock, MERGE_HEAD or rebase-merge -> result `skip`, exit 0, no change to the tree.
# Stamp ~/.cache/dotfiles-hook-sync/head = the HEAD of the last ok run: the link pass runs when HEAD differs from it (a HEAD change, or the
#   last result was not ok); the post-check runs every time. State ~/.cache/dotfiles-hook-sync/state = ONE JSON line:
#   {"host","ts","head","result":"ok|unresolved|skip|expired","unresolved":[...],"local":[...],"exit":N}
# Exit: 0 ok/skip, 2 expired, 3 unresolved, 64 usage. Never pulls, commits, or runs install.sh.
#   dotfiles-hook-sync.sh              run once
#   dotfiles-hook-sync.sh --selftest   throwaway HOME + fixture repo: (i) real file kept (ii) pull guard (iii) unresolved (iv) idempotent (v) expiry
# Env seams: DHS_TODAY (YYYY-MM-DD, default today), DHS_REPO (default $HOME/dotfiles).
# shellcheck disable=SC2016  # single-quoted $HOME / ${HOME} are literals by design
set -u
EXPIRES=2027-01-31
RE='(~|\$HOME|\$\{HOME\})/\.claude/hooks/[A-Za-z0-9._/-]+|/home/jsy/\.claude/hooks/[A-Za-z0-9._/-]+'

# live_paths: every distinct registered hook path in the live settings files, with ~ / $HOME / ${HOME} expanded to $HOME
live_paths() {
  local f
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    jq -r '[.. | objects | select(has("command")) | .command | strings] | .[]' "$f" 2>/dev/null
  done | grep -oE "$RE" | sed -e "s|^~|$HOME|" -e "s|^\\\$HOME|$HOME|" -e "s|^\\\${HOME}|$HOME|" | sort -u
}

# json_list: newline-separated stdin -> JSON array of strings
json_list() { jq -Rsc 'split("\n") | map(select(. != ""))'; }

# write_state RESULT HEAD UNRESOLVED_LIST LOCAL_LIST EXIT: ONE JSON line, overwritten in place (same inode, no new path)
write_state() {
  local dir=$HOME/.cache/dotfiles-hook-sync
  mkdir -p "$dir" || return 0
  jq -nc --arg host "$(hostname -s)" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg head "$2" --arg result "$1" \
    --argjson unresolved "$(printf '%s\n' "$3" | json_list)" --argjson local "$(printf '%s\n' "$4" | json_list)" --argjson exit "$5" \
    '{host:$host, ts:$ts, head:$head, result:$result, unresolved:$unresolved, local:$local, exit:$exit}' > "$dir/state"
}

run() {
  local repo=${DHS_REPO:-$HOME/dotfiles} today=${DHS_TODAY:-$(date +%F)}
  local dir=$HOME/.cache/dotfiles-hook-sync head stamp="" rel src dst
  head=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || head=none

  if [[ $today > "$EXPIRES" ]]; then
    echo "dotfiles-hook-sync: EXPIRED ($today > $EXPIRES): premise review owed; re-arm by a reviewed edit of EXPIRES"
    write_state expired "$head" "" "" 2
    return 2
  fi

  if [ -e "$repo/.git/index.lock" ] || [ -e "$repo/.git/MERGE_HEAD" ] || [ -e "$repo/.git/rebase-merge" ]; then
    echo "dotfiles-hook-sync: SKIP a pull is in progress in $repo"
    write_state skip "$head" "" "" 0
    return 0
  fi

  [ -f "$dir/head" ] && stamp=$(cat "$dir/head" 2>/dev/null)
  local locals=""
  if [ "$head" != none ] && [ "$head" != "$stamp" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      src=$repo/$rel; dst=$HOME/$rel
      if [ -L "$dst" ]; then
        case $(readlink "$dst") in
          "$src"|"$repo"/*) continue ;;   # already a symlink into this repo
        esac
        echo "HOOK-LOCAL $dst $(readlink "$dst")"; locals+="$dst"$'\n'; continue
      fi
      if [ -e "$dst" ]; then
        # the same file reached through a parent-directory symlink is not a local copy
        if [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src")" ]; then continue; fi
        echo "HOOK-LOCAL $dst $(stat -c %i "$dst")"; locals+="$dst"$'\n'; continue
      fi
      mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" && echo "linked: $dst -> $src"
    done < <(git -C "$repo" ls-files -- .claude/hooks 2>/dev/null)
  fi

  local unresolved="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ] && [ -x "$p" ]; then :; else echo "HOOK-UNRESOLVED $p"; unresolved+="$p"$'\n'; fi
  done < <(live_paths)

  if [ -n "$unresolved" ]; then
    write_state unresolved "$head" "$unresolved" "$locals" 3
    return 3
  fi
  mkdir -p "$dir" && [ "$head" != none ] && printf '%s\n' "$head" > "$dir/head"
  write_state ok "$head" "" "$locals" 0
  return 0
}

selftest() {
  local self T H R fail=0 out rc before after ino sum
  self=$(readlink -f "${BASH_SOURCE[0]}")
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  H=$T/home; R=$H/dotfiles
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  ok() { echo "selftest $1 ok: $2"; }
  no() { echo "selftest $1 FAIL: $2"; fail=1; }
  snap() { find "$H" -printf '%p %l %i\n' | sort; }
  dhs() { HOME=$H DHS_TODAY="${DHS_TODAY_T:-2026-10-24}" "$self" 2>&1; }
  state() { jq -r ".$1" "$H/.cache/dotfiles-hook-sync/state"; }
  commit() { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm "$1"; }

  mkdir -p "$R/.claude/hooks" "$H/.claude/hooks"
  git -C "$R" init -q
  printf '#!/bin/sh\necho repo-a\n' > "$R/.claude/hooks/a.sh"; printf '#!/bin/sh\necho repo-b\n' > "$R/.claude/hooks/b.sh"
  chmod +x "$R/.claude/hooks/a.sh" "$R/.claude/hooks/b.sh"
  commit one
  # live settings (a real file on the node): registers a.sh via ${HOME}, b.sh behind `bash ~`
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:"${HOME}/.claude/hooks/a.sh"},{type:"command",command:"timeout 5 bash ~/.claude/hooks/b.sh"}]}]}}' > "$H/.claude/settings.json"

  # (i) a real, different file at a tracked hook path survives untouched, with a HOOK-LOCAL line
  printf '#!/bin/sh\necho node-local-a\n' > "$H/.claude/hooks/a.sh"; chmod +x "$H/.claude/hooks/a.sh"
  ino=$(stat -c %i "$H/.claude/hooks/a.sh"); sum=$(sha256sum < "$H/.claude/hooks/a.sh")
  out=$(dhs); rc=$?
  if [ "$(stat -c %i "$H/.claude/hooks/a.sh")" = "$ino" ] && [ "$(sha256sum < "$H/.claude/hooks/a.sh")" = "$sum" ] && [ ! -L "$H/.claude/hooks/a.sh" ] \
     && printf '%s\n' "$out" | grep -qx "HOOK-LOCAL $H/.claude/hooks/a.sh $ino" && [ $rc -eq 0 ] && [ -L "$H/.claude/hooks/b.sh" ] && [ "$(state result)" = ok ]; then
    ok "(i)" "real a.sh kept (inode $ino, content unchanged), $(printf '%s\n' "$out" | grep HOOK-LOCAL), b.sh linked, rc=$rc result=ok"
  else no "(i)" "rc=$rc out=$out"; fi

  # (ii) a pull in progress (index.lock, then MERGE_HEAD) = result skip and the tree is untouched, even though HEAD moved
  printf '#!/bin/sh\necho repo-c\n' > "$R/.claude/hooks/c.sh"; chmod +x "$R/.claude/hooks/c.sh"; commit two
  for g in index.lock MERGE_HEAD; do
    : > "$R/.git/$g"; before=$(snap)
    out=$(dhs); rc=$?; after=$(snap)
    if [ "$(state result)" = skip ] && [ $rc -eq 0 ] && [ "$before" = "$after" ] && [ ! -e "$H/.claude/hooks/c.sh" ]; then
      ok "(ii)" "$g present: result=skip rc=0, find before/after diff empty, c.sh not linked"
    else no "(ii)" "$g rc=$rc result=$(state result) diff: $(diff <(echo "$before") <(echo "$after"))"; fi
    rm -f "$R/.git/$g"
  done
  out=$(dhs)
  if [ -L "$H/.claude/hooks/c.sh" ]; then ok "(ii)" "guard cleared: c.sh linked on the next run"; else no "(ii)" "c.sh not linked after the guard cleared: $out"; fi

  # (iii) a registered hook missing from the node = HOOK-UNRESOLVED + exit 3
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:"${HOME}/.claude/hooks/a.sh"},{type:"command",command:"python3 ${HOME}/.claude/hooks/never-tracked.py"},{type:"command",command:"~/.claude/hooks/missing.sh"}]}]}}' > "$H/.claude/settings.json"
  out=$(dhs); rc=$?
  if [ $rc -eq 3 ] && printf '%s\n' "$out" | grep -qx "HOOK-UNRESOLVED $H/.claude/hooks/missing.sh" && printf '%s\n' "$out" | grep -qx "HOOK-UNRESOLVED $H/.claude/hooks/never-tracked.py" \
     && [ "$(state result)" = unresolved ] && [ "$(state exit)" = 3 ] && [ "$(state 'unresolved|length')" = 2 ]; then
    ok "(iii)" "rc=3, result=unresolved, $(printf '%s\n' "$out" | grep -c HOOK-UNRESOLVED) HOOK-UNRESOLVED lines ($(printf '%s\n' "$out" | grep HOOK-UNRESOLVED | sed "s|$H|HOME|" | tr '\n' ' '))"
  else no "(iii)" "rc=$rc out=$out"; fi

  # (iv) idempotence: the second run changes nothing, in the unresolved state (link pass reruns) and in the ok state
  for st in unresolved ok; do
    if [ $st = ok ]; then jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:"${HOME}/.claude/hooks/a.sh"}]}]}}' > "$H/.claude/settings.json"; fi
    dhs >/dev/null; before=$(snap); dhs >/dev/null; after=$(snap)
    if [ "$before" = "$after" ]; then ok "(iv)" "second run in the $st state: find before/after diff empty ($(printf '%s\n' "$after" | wc -l) paths)"
    else no "(iv)" "$st state diff: $(diff <(echo "$before") <(echo "$after"))"; fi
  done

  # (v) expiry via the DHS_TODAY seam: exit 2, result expired; the last valid day still runs
  out=$(DHS_TODAY_T=2027-02-01 dhs); rc=$?
  if [ $rc -eq 2 ] && [ "$(state result)" = expired ] && [ "$(state exit)" = 2 ]; then ok "(v)" "2027-02-01: rc=2 result=expired ($(printf '%s' "$out" | head -n1 | cut -c1-60))"
  else no "(v)" "rc=$rc out=$out"; fi
  out=$(DHS_TODAY_T=2027-01-31 dhs); rc=$?
  if [ $rc -eq 0 ] && [ "$(state result)" = ok ]; then ok "(v)" "2027-01-31 (EXPIRES day): rc=0 result=ok"; else no "(v)" "EXPIRES day rc=$rc out=$out"; fi

  [ $fail -eq 0 ] && echo "selftest: ALL PASS" || echo "selftest: FAILED"
  return $fail
}

case "${1:-}" in
  "") run; exit $? ;;
  --selftest) selftest; exit $? ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 64 ;;
esac
