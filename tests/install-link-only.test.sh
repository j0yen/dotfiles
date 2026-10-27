#!/usr/bin/env bash
# install.sh --link-only [--paths-from <old> <new>]: a pull IS an install. Everything runs against a tmp repo + tmp HOME
# (install.sh is COPIED into the tmp repo: it resolves its repo root from its own path). INSTALL_SH overrides the script under
# test (mutation runs).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_SH=${INSTALL_SH:-$here/install.sh}
t=$(mktemp -d "${TMPDIR:-/tmp}/ilo-test.XXXXXX"); trap 'rm -rf "$t"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# mkrepo <dir>: tmp repo with install.sh, a postapply stub (touches $MARKER), a protected-hooks-check stub (exits $PHC_RC)
mkrepo() {
  local r="$1"
  mkdir -p "$r/.local/bin" "$r/.claude/hooks"
  cp "$INSTALL_SH" "$r/install.sh"; chmod 755 "$r/install.sh"
  printf '#!/usr/bin/env bash\ntouch "$MARKER"\nexit 0\n' > "$r/.local/bin/watcher-lib-postapply.sh"; chmod 755 "$r/.local/bin/watcher-lib-postapply.sh"
  printf '#!/usr/bin/env bash\nexit "${PHC_RC:-0}"\n' > "$r/.claude/hooks/protected-hooks-check.sh"; chmod 755 "$r/.claude/hooks/protected-hooks-check.sh"
  printf '{}\n' > "$r/.claude/settings.json"
  printf '#!/usr/bin/env bash\necho a\n' > "$r/.local/bin/a.sh"; chmod 755 "$r/.local/bin/a.sh"
  printf 'b\n' > "$r/.local/bin/b.txt"
  printf 'd\n' > "$r/.local/bin/d.txt"
  printf 'f\n' > "$r/.local/bin/f.txt"
  printf 'readme\n' > "$r/README.md"; printf 'x\n' > "$r/.gitignore"
  git init -q "$r" && git -C "$r" add -A && git -C "$r" commit -q -m c1
}
run() { # run <repo> <home> args... ; MARKER inherited
  local r="$1" h="$2"; shift 2
  ( cd "$r" && HOME="$h" bash ./install.sh "$@" 2>"$t/stderr" )
}

# ---- 1. no-arg still runs the postapply stub; --link-only does NOT ----
r1="$t/r1"; mkrepo "$r1"
h1="$t/h1"; mkdir -p "$h1"; export MARKER="$t/marker1"; rm -f "$MARKER"
out=$(run "$r1" "$h1"); rc=$?
{ [ $rc -eq 0 ] && [ -e "$MARKER" ] && [ -L "$h1/.local/bin/a.sh" ]; } && ok "no-arg: links + runs watcher-lib-postapply (marker touched)" || bad "no-arg rc=$rc marker=$([ -e "$MARKER" ] && echo y || echo n)"
h2="$t/h2"; mkdir -p "$h2"; export MARKER="$t/marker2"; rm -f "$MARKER"
out=$(run "$r1" "$h2" --link-only); rc=$?
if [ $rc -eq 0 ] && [ ! -e "$MARKER" ] && [ -L "$h2/.local/bin/a.sh" ] && [ -L "$h2/.local/bin/f.txt" ] && grep -q '^selftest=skipped$' <<<"$out"; then ok "--link-only: links everything, does NOT run postapply (no marker), says selftest=skipped"
else bad "--link-only rc=$rc marker=$([ -e "$MARKER" ] && echo y || echo n) out=$out"; fi

# ---- 2. skip rules hold ----
for f in README.md .gitignore install.sh; do [ -e "$h2/$f" ] && bad "--link-only linked skipped file $f"; done
printf '{}\n' > "$r1/.claude/settings.local.json"
h3="$t/h3"; mkdir -p "$h3"
out=$(run "$r1" "$h3" --link-only)
{ [ ! -e "$h3/.claude/settings.local.json" ] && grep -q 'skip (claude-self or local-only): .claude/settings.local.json' <<<"$out" && [ ! -e "$h3/README.md" ] && [ ! -e "$h3/install.sh" ]; } && ok "skip rules: README/.gitignore/install.sh/settings.local.json never linked" || bad "skip rules: $out"
rm -f "$r1/.claude/settings.local.json"

# ---- 3. exit code is protected-hooks-check's ----
h4="$t/h4"; mkdir -p "$h4"
PHC_RC=3 run "$r1" "$h4" --link-only >/dev/null; rc=$?
[ $rc -eq 3 ] && ok "--link-only exit code = protected-hooks-check's (3)" || bad "phc rc=$rc"

# ---- 4. --paths-from: only the diff's files; D / R-old -> stale; dst untouched ----
r2="$t/r2"; mkrepo "$r2"; h5="$t/h5"; mkdir -p "$h5"
run "$r2" "$h5" --link-only >/dev/null
old=$(git -C "$r2" rev-parse HEAD)
printf 'a2\n' >> "$r2/.local/bin/a.sh"                       # M
printf 'c\n' > "$r2/.local/bin/c.txt"                          # A
git -C "$r2" rm -q .local/bin/b.txt                            # D
git -C "$r2" mv .local/bin/d.txt .local/bin/e.txt              # R
printf 'new readme\n' >> "$r2/README.md"; printf 'sl\n' > "$r2/.claude/settings.local.json"   # skipped paths in the diff
git -C "$r2" add -A -f && git -C "$r2" commit -q -m c2
new=$(git -C "$r2" rev-parse HEAD)
rm -f "$h5/.local/bin/f.txt"                                   # untouched by the diff: must NOT be relinked
out=$(run "$r2" "$h5" --link-only --paths-from "$old" "$new"); rc=$?
if [ $rc -eq 0 ] && [ -L "$h5/.local/bin/c.txt" ] && [ -L "$h5/.local/bin/e.txt" ] && [ ! -e "$h5/.local/bin/f.txt" ]; then ok "--paths-from links added + renamed-to files only (unchanged f.txt not relinked)"
else bad "paths-from link set rc=$rc out=$out"; fi
{ grep -q "^stale: $h5/.local/bin/b.txt$" <<<"$out" && grep -q "^stale: $h5/.local/bin/d.txt$" <<<"$out"; } && ok "deleted file and rename-old -> stale: lines" || bad "stale lines: $out"
{ [ -L "$h5/.local/bin/b.txt" ] && [ -L "$h5/.local/bin/d.txt" ]; } && ok "stale dst left untouched (report only, never delete)" || bad "stale dst was removed"
{ [ ! -e "$h5/README.md" ] && [ ! -e "$h5/.claude/settings.local.json" ]; } && ok "--paths-from honours the skip rules" || bad "paths-from linked a skipped file"
! grep -q '^stale: .*README' <<<"$out" && ok "no stale line for skipped paths" || bad "stale for skipped path"

# a stale report only for symlinks INTO the repo
r3="$t/r3"; mkrepo "$r3"; h6="$t/h6"; mkdir -p "$h6/.local/bin"
printf 'mine\n' > "$h6/.local/bin/b.txt"                       # real file at the deleted path: not stale
old=$(git -C "$r3" rev-parse HEAD); git -C "$r3" rm -q .local/bin/b.txt && git -C "$r3" commit -q -m del
out=$(run "$r3" "$h6" --link-only --paths-from "$old" HEAD)
! grep -q '^stale:' <<<"$out" && [ "$(cat "$h6/.local/bin/b.txt")" = mine ] && ok "stale only for symlinks into the repo; a real file at the deleted path is silent + intact" || bad "stale on real file: $out"

# bad revs -> full walk, not a silent skip
h7="$t/h7"; mkdir -p "$h7"
out=$(run "$r3" "$h7" --link-only --paths-from nosuchrev alsonot); rc=$?
{ [ $rc -eq 0 ] && [ -L "$h7/.local/bin/a.sh" ]; } && ok "--paths-from with unusable revs falls back to the full link-only walk" || bad "bad revs rc=$rc"

# ---- 5. never replaces / backs up a non-symlink dst ----
r4="$t/r4"; mkrepo "$r4"; h8="$t/h8"; mkdir -p "$h8/.local/bin"
printf 'precious\n' > "$h8/.local/bin/a.sh"
out=$(run "$r4" "$h8" --link-only)
if grep -q "^conflict: $h8/.local/bin/a.sh$" <<<"$out" && [ ! -L "$h8/.local/bin/a.sh" ] && [ "$(cat "$h8/.local/bin/a.sh")" = precious ] && ! ls "$h8/.local/bin/" | grep -q '\.bak\.'; then ok "non-symlink dst: conflict: line, file untouched, no backup"
else bad "conflict: $out"; fi
# ... while the full install keeps today's backup behaviour
h9="$t/h9"; mkdir -p "$h9/.local/bin"; printf 'precious\n' > "$h9/.local/bin/a.sh"; export MARKER="$t/m9"
run "$r4" "$h9" >/dev/null
{ [ -L "$h9/.local/bin/a.sh" ] && ls "$h9/.local/bin/" | grep -q '^a.sh.bak.'; } && ok "full install still backs up + replaces (unchanged)" || bad "full install backup behaviour changed"

# ---- 6. bash -n on linked *.sh (cheap half of postapply) ----
r5="$t/r5"; mkrepo "$r5"; printf 'if then\n' > "$r5/.local/bin/broken.sh"; h10="$t/h10"; mkdir -p "$h10"
out=$(run "$r5" "$h10" --link-only); rc=$?
{ [ $rc -eq 0 ] && grep -q 'bash-n FAILED' "$t/stderr" && grep -q '^bash-n: fail=1$' <<<"$out"; } && ok "bash -n runs on linked *.sh (failure reported on stderr, exit code unchanged)" || bad "bash -n rc=$rc stderr=$(cat "$t/stderr")"

# ---- 7. --dry-run prints and changes nothing, alone and combined ----
h11="$t/h11"; mkdir -p "$h11"; export MARKER="$t/m11"; rm -f "$MARKER"
out=$(run "$r2" "$h11" --link-only --dry-run)
{ grep -q '^would link:' <<<"$out" && [ -z "$(find "$h11" -mindepth 1 | head -1)" ]; } && ok "--link-only --dry-run: would link, HOME untouched" || bad "dry link-only: $out"
out=$(run "$r2" "$h11" --dry-run --link-only --paths-from "$old" "$new")
{ grep -q '^would link:' <<<"$out" && [ -z "$(find "$h11" -mindepth 1 | head -1)" ]; } && ok "--dry-run with --paths-from: would link, HOME untouched" || bad "dry paths-from: $out"
out=$(run "$r2" "$h11" --dry-run)
{ grep -q '^would run: .*watcher-lib-postapply.sh' <<<"$out" && [ ! -e "$MARKER" ] && [ -z "$(find "$h11" -mindepth 1 | head -1)" ]; } && ok "plain --dry-run unchanged (would run postapply, nothing done)" || bad "dry plain: $out"

# ---- 8. usage ----
run "$r2" "$t/h12" --paths-from a b >/dev/null 2>&1; [ $? -eq 2 ] && ok "--paths-from without --link-only -> usage, exit 2" || bad "paths-from alone accepted"
run "$r2" "$t/h12" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag -> usage, exit 2" || bad "unknown flag accepted"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
