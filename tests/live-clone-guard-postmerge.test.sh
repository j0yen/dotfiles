#!/usr/bin/env bash
# live-clone-guard post-merge / post-rewrite / post-checkout hooks: a pull IS an install. Real git, tmp bare remote, tmp clone, tmp HOME.
# LCG_SCRIPT / INSTALL_SH override the scripts under test (mutation runs).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LCG=${LCG_SCRIPT:-$here/.local/bin/live-clone-guard.sh}
INSTALL_SH=${INSTALL_SH:-$here/install.sh}
t=$(mktemp -d "${TMPDIR:-/tmp}/lcgpm-test.XXXXXX"); t=$(cd "$t" && pwd -P); trap '[ -n "${KEEP:-}" ] || rm -rf "$t"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export HOME="$t/home" XDG_CONFIG_HOME="$t/home/.config" XDG_STATE_HOME="$t/home/.local/state"
mkdir -p "$HOME"
unset LIVE_CLONE_GUARD_DRY GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
LOG="$XDG_STATE_HOME/live-clone-guard/postmerge.log"
lastline() { grep -v '^  ' "$LOG" | tail -n1; }   # last summary line (detail lines are indented)
loglines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

# seed <dir>: a dotfiles-like work repo (install.sh + stubs + .claude/hooks/a.sh), pushed to $t/remote.git
git init -q --bare -b main "$t/remote.git"
S="$t/seed"; mkdir -p "$S/.claude/hooks" "$S/.local/bin"; git init -q -b main "$S"
cp "$INSTALL_SH" "$S/install.sh"; chmod 755 "$S/install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/.local/bin/watcher-lib-postapply.sh"; chmod 755 "$S/.local/bin/watcher-lib-postapply.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/.claude/hooks/protected-hooks-check.sh"; chmod 755 "$S/.claude/hooks/protected-hooks-check.sh"
printf '{}\n' > "$S/.claude/settings.json"
printf '#!/usr/bin/env bash\necho a\n' > "$S/.claude/hooks/a.sh"; chmod 755 "$S/.claude/hooks/a.sh"
git -C "$S" add -A && git -C "$S" commit -q -m seed && git -C "$S" remote add origin "$t/remote.git" && git -C "$S" push -q origin main
seedcommit() { git -C "$S" add -A && git -C "$S" commit -q -m "$1" && git -C "$S" push -q origin main; }

L="$t/live"; git clone -q "$t/remote.git" "$L"; L=$(cd "$L" && pwd -P)
mkdir -p "$XDG_CONFIG_HOME/live-clone-guard"; printf '%s\n' "$L" > "$XDG_CONFIG_HOME/live-clone-guard/repos"

# ---- ensure writes all hooks; check reports four ok ----
out=$("$LCG" ensure 2>&1); rc=$?
if [ $rc -eq 0 ] && ( for h in post-merge post-rewrite post-checkout; do grep -q "$L $h installed" <<<"$out" && [ -x "$L/.git/hooks/$h" ] || exit 1; done ); then ok "ensure writes post-merge + post-rewrite + post-checkout into a clone with install.sh --link-only"
else bad "ensure rc=$rc out=$out"; fi
out=$("$LCG" check "$L" 2>&1); rc=$?
{ [ $rc -eq 0 ] && [ "$(grep -c ' ok$' <<<"$out")" = 4 ]; } && ok "check reports all four hooks ok (exit 0)" || bad "check rc=$rc out=$out"
out=$("$LCG" ensure 2>&1); grep -q "$L post-merge already" <<<"$out" && ok "ensure is idempotent (already)" || bad "ensure rerun: $out"

# ---- end-to-end: a real git pull --ff-only that adds .claude/hooks/x.sh links it; only the diff's files ----
printf '#!/usr/bin/env bash\necho x\n' > "$S/.claude/hooks/x.sh"; chmod 755 "$S/.claude/hooks/x.sh"; seedcommit addx
pullout=$(git -C "$L" pull --ff-only 2>&1); prc=$?
if [ $prc -eq 0 ] && [ -L "$HOME/.claude/hooks/x.sh" ] && [ "$(readlink "$HOME/.claude/hooks/x.sh")" = "$L/.claude/hooks/x.sh" ]; then ok "END-TO-END: git pull --ff-only adding .claude/hooks/x.sh links \$HOME/.claude/hooks/x.sh"
else bad "e2e pull rc=$prc x.sh link=$(readlink "$HOME/.claude/hooks/x.sh" 2>&1) out=$pullout"; fi
[ ! -e "$HOME/.claude/hooks/a.sh" ] && ok "pull used --paths-from (unchanged a.sh not linked)" || bad "a.sh linked: paths-from not used"
lastline | grep -Eq '^[0-9T:Z-]+ [0-9a-f]{12}\.\.[0-9a-f]{12} rc=0 linked=1 stale=0 conflict=0 selftest=skipped hook=post-merge squash=0$' && ok "postmerge.log line: <iso> <old>..<new> rc=0 linked=1 stale=0 ..." || bad "log line: $(tail -n1 "$LOG")"

# ---- conflict: a real file at the dst is never replaced ----
mkdir -p "$HOME/.claude/hooks"; printf 'mine\n' > "$HOME/.claude/hooks/z.sh"
printf '#!/usr/bin/env bash\necho z\n' > "$S/.claude/hooks/z.sh"; chmod 755 "$S/.claude/hooks/z.sh"; seedcommit addz
git -C "$L" pull -q --ff-only 2>/dev/null
{ [ ! -L "$HOME/.claude/hooks/z.sh" ] && [ "$(cat "$HOME/.claude/hooks/z.sh")" = mine ] && ! ls "$HOME/.claude/hooks" | grep -q '\.bak\.'; } && ok "non-symlink dst untouched through the hook, no backup" || bad "z.sh was replaced/backed up"
{ grep -q 'conflict=1' "$LOG" && grep -q "^  conflict: $HOME/.claude/hooks/z.sh$" "$LOG"; } && ok "log carries conflict=1 and the conflict: line" || bad "conflict log: $(tail -n3 "$LOG")"

# ---- rename: old stale, new linked (a.sh is linked by the full link-only below first) ----
( cd "$L" && .git/hooks/post-rewrite rebase </dev/null ); rc=$?
{ [ $rc -eq 0 ] && [ -L "$HOME/.claude/hooks/a.sh" ] && lastline | grep -q 'hook=post-rewrite rewrite=rebase'; } && ok "post-rewrite with EMPTY stdin runs the full --link-only (a.sh linked), exit 0" || bad "post-rewrite rc=$rc"
git -C "$S" mv .claude/hooks/a.sh .claude/hooks/a2.sh && seedcommit rename
git -C "$L" pull -q --ff-only 2>/dev/null
{ [ -L "$HOME/.claude/hooks/a2.sh" ] && [ -L "$HOME/.claude/hooks/a.sh" ] && grep -q "^  stale: $HOME/.claude/hooks/a.sh$" "$LOG"; } && ok "rename: new path linked, old path reported stale and left in place" || bad "rename: $(tail -n4 "$LOG")"

# ---- reset --hard fires nothing (asserted) ----
printf '#!/usr/bin/env bash\necho y\n' > "$S/.claude/hooks/y.sh"; chmod 755 "$S/.claude/hooks/y.sh"; seedcommit addy
n0=$(loglines); git -C "$L" fetch -q origin && git -C "$L" reset -q --hard origin/main
{ [ "$(loglines)" = "$n0" ] && [ ! -e "$HOME/.claude/hooks/y.sh" ]; } && ok "git reset --hard fires no hook (y.sh not linked, log unchanged): only fleet-sync's stamp covers it" || bad "reset --hard fired a hook"

# ---- ORIG_HEAD absent -> full link-only ----
L2="$t/live2"; git clone -q "$t/remote.git" "$L2"; L2=$(cd "$L2" && pwd -P)
"$LCG" install "$L2" >/dev/null 2>&1; rm -f "$L2/.git/ORIG_HEAD"
( cd "$L2" && .git/hooks/post-merge 0 ); rc=$?
{ [ $rc -eq 0 ] && [ -L "$HOME/.claude/hooks/y.sh" ] && lastline | grep -q 'hook=post-merge'; } && ok "post-merge with ORIG_HEAD and HEAD@{1} absent runs the full --link-only (y.sh linked)" || bad "no-ORIG_HEAD rc=$rc: $(tail -n2 "$LOG")"

# ---- post-checkout: branch checkout acts, file checkout does not ----
git -C "$S" checkout -q -b side && printf 's\n' > "$S/.claude/hooks/side.sh" && git -C "$S" add -A && git -C "$S" commit -q -m side && git -C "$S" push -q origin side
git -C "$S" checkout -q main
git -C "$L" fetch -q origin
n0=$(loglines); git -C "$L" checkout -q side 2>/dev/null
{ [ -L "$HOME/.claude/hooks/side.sh" ] && [ "$(loglines)" -gt "$n0" ] && lastline | grep -q 'hook=post-checkout'; } && ok "post-checkout on a branch checkout links the new branch's files" || bad "post-checkout: $(tail -n2 "$LOG")"
n0=$(loglines); git -C "$L" checkout -q -- .claude/hooks/side.sh
[ "$(loglines)" = "$n0" ] && ok "post-checkout ignores a file checkout (\$3=0)" || bad "file checkout fired the hook"
git -C "$L" checkout -q main 2>/dev/null

# ---- a worktree of the live clone never installs ----
n0=$(loglines); git -C "$L" worktree add -q "$t/wt" -b wtb 2>/dev/null
[ "$(loglines)" = "$n0" ] && ok "worktree add (post-checkout in a non-live toplevel) does nothing" || bad "worktree fired install"

# ---- LIVE_CLONE_GUARD_DRY passes --dry-run through ----
D="$t/dry"; git clone -q "$t/remote.git" "$D"; D=$(cd "$D" && pwd -P); "$LCG" install "$D" >/dev/null 2>&1
rm -rf "$HOME/.claude/hooks/side.sh"; ( cd "$D" && LIVE_CLONE_GUARD_DRY=1 .git/hooks/post-rewrite rebase </dev/null )
lastline | grep -q 'linked=0' && [ ! -e "$HOME/.claude/hooks/side.sh" ] && ok "LIVE_CLONE_GUARD_DRY=1 passes --dry-run (nothing linked, linked=0)" || bad "dry env: $(tail -n1 "$LOG")"

# ---- hook exits 0 even when install.sh fails; stderr says so ----
printf '#!/usr/bin/env bash\n# supports --link-only\nexit 7\n' > "$S/install.sh"; seedcommit failing-install
perr=$(git -C "$L" pull --ff-only 2>&1 >/dev/null); prc=$?
{ [ $prc -eq 0 ] && grep -q 'rc=7' <<<"$perr" && lastline | grep -q ' rc=7 '; } && ok "install.sh failing (rc=7): git pull still exits 0, one stderr line, log rc=7" || bad "failing install: prc=$prc err=$perr"

# ---- GIT_DIR unset: install.sh's own git calls in a second repo see THAT repo ----
L3="$t/live3"; git clone -q "$t/remote.git" "$L3"; L3=$(cd "$L3" && pwd -P); OTHER="$t/other"; git init -q "$OTHER"; OTHER=$(cd "$OTHER" && pwd -P)
git -C "$L3" checkout -q main 2>/dev/null
printf '#!/usr/bin/env bash\n# supports --link-only\n(cd "%s" && git rev-parse --show-toplevel > "%s/seen")\nexit 0\n' "$OTHER" "$t" > "$L3/install.sh"; chmod 755 "$L3/install.sh"
"$LCG" install "$L3" >/dev/null 2>&1
rm -f "$t/seen"; ( cd "$L3" && GIT_DIR="$L3/.git" GIT_WORK_TREE="$L3" .git/hooks/post-rewrite rebase </dev/null )
[ "$(cat "$t/seen" 2>/dev/null)" = "$OTHER" ] && ok "hook unsets GIT_DIR/GIT_WORK_TREE: install.sh's git call in a second repo sees that repo" || bad "GIT_DIR leaked into install.sh (saw: $(cat "$t/seen" 2>/dev/null))"

# ---- repo without install.sh: no post hooks; check n/a, exit 0 ----
P="$t/plain"; git init -q "$P"; git -C "$P" commit -q --allow-empty -m i; P=$(cd "$P" && pwd -P)
"$LCG" install "$P" >/dev/null 2>&1
{ [ -x "$P/.git/hooks/pre-commit" ] && [ ! -e "$P/.git/hooks/post-merge" ] && [ ! -e "$P/.git/hooks/post-rewrite" ] && [ ! -e "$P/.git/hooks/post-checkout" ]; } && ok "repo without install.sh gets pre-commit only, no post hooks" || bad "plain repo got post hooks"
"$LCG" check "$P" >/dev/null 2>&1 && ok "check on a repo without install.sh: exit 0 (post hooks n/a)" || bad "plain check non-zero"

# ---- foreign post-merge left untouched ----
F="$t/foreign"; git clone -q "$t/remote.git" "$F"; F=$(cd "$F" && pwd -P)
printf '#!/bin/sh\necho mine\n' > "$F/.git/hooks/post-merge"; chmod 755 "$F/.git/hooks/post-merge"; sum=$(cksum < "$F/.git/hooks/post-merge")
out=$("$LCG" install "$F" 2>/dev/null); rc=$?
{ [ $rc -eq 3 ] && grep -q "$F post-merge refused-foreign-hook" <<<"$out" && [ "$sum" = "$(cksum < "$F/.git/hooks/post-merge")" ] && [ -x "$F/.git/hooks/post-rewrite" ]; } && ok "foreign post-merge untouched (refused-foreign-hook, exit 3); the other hooks still written" || bad "foreign rc=$rc out=$out"
"$LCG" check "$F" >/dev/null 2>&1 && bad "check should fail on a foreign post-merge" || ok "check: foreign post-merge -> non-zero"

# ---- core.hooksPath elsewhere -> check RED ----
H="$t/hp"; git clone -q "$t/remote.git" "$H"; H=$(cd "$H" && pwd -P)
"$LCG" install "$H" >/dev/null 2>&1; git -C "$H" config core.hooksPath "$t/elsewhere"
out=$("$LCG" check "$H" 2>&1); rc=$?
{ [ $rc -ne 0 ] && grep -q 'RED core.hooksPath=' <<<"$out"; } && ok "core.hooksPath set elsewhere: check RED (non-zero)" || bad "hooksPath check rc=$rc out=$out"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
