#!/usr/bin/env bash
# install.sh honours FLEET_SYNC_RETIRED (retired.tsv from fleet-sync P28 mechanism 5): a retired path is not linked,
# prints `SKIP retired <path>`; unset = unchanged; an already-linked retired file is left in place; a malformed row warns.
# Hermetic: temp repo copy, temp HOME, fake systemctl on PATH.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
printf '#!/bin/sh\nexit 0\n' > "$t/bin/systemctl"; chmod +x "$t/bin/systemctl"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkrepo() {  # mkrepo <n> -> fresh repo copy + empty home
  local r="$t/$1/repo" h="$t/$1/home"
  mkdir -p "$r/.config/systemd/user/foo.service.d" "$h"
  cp "$here/install.sh" "$r/install.sh"
  printf 'a\n' > "$r/.config/systemd/user/foo.service"
  printf '[Service]\n' > "$r/.config/systemd/user/foo.service.d/90-slow.conf"
  printf 'b\n' > "$r/keep.txt"
}
run() {  # run <n> [VAR=val ...]
  local n="$1"; shift
  ( cd "$t/$n/repo" && env -u FLEET_SYNC_RETIRED -u XDG_STATE_HOME HOME="$t/$n/home" PATH="$t/bin:$PATH" "$@" bash ./install.sh ) >"$t/$n/out" 2>"$t/$n/err"
  echo $? > "$t/$n/rc"
}
D=.config/systemd/user/foo.service.d/90-slow.conf
U=.config/systemd/user/foo.service

# (a) unset: everything linked, no SKIP retired
mkrepo a; run a
{ [ -L "$t/a/home/$D" ] && [ -L "$t/a/home/$U" ] && [ -L "$t/a/home/keep.txt" ] && ! grep -q 'SKIP retired' "$t/a/out"; } \
  && ok "(a) unset: all links made, no SKIP retired" || bad "(a) $(cat "$t/a/out")"

# (b) one retired drop-in: not linked, SKIP line, others linked
mkrepo b; printf 'df\t%s\tabc1234\t2026-11-01T00:00:00Z\n' "$D" > "$t/b/retired.tsv"
run b FLEET_SYNC_RETIRED="$t/b/retired.tsv"
{ [ ! -e "$t/b/home/$D" ] && [ ! -L "$t/b/home/$D" ] && grep -qx "SKIP retired $D" "$t/b/out" && [ -L "$t/b/home/$U" ] && [ -L "$t/b/home/keep.txt" ] && [ "$(grep -c '^SKIP retired' "$t/b/out")" = 1 ]; } \
  && ok "(b) retired drop-in not linked, one SKIP retired line, others linked" || bad "(b) $(cat "$t/b/out" "$t/b/err")"

# (c) retired unit already linked: not re-linked, not deleted, no backup
mkrepo c; mkdir -p "$t/c/home/.config/systemd/user"; ln -s "$t/c/repo/$U" "$t/c/home/$U"
printf 'df\t%s\tabc1234\t2026-11-01T00:00:00Z\n' "$U" > "$t/c/retired.tsv"
run c FLEET_SYNC_RETIRED="$t/c/retired.tsv"
{ [ -L "$t/c/home/$U" ] && [ "$(readlink "$t/c/home/$U")" = "$t/c/repo/$U" ] && grep -qx "SKIP retired $U" "$t/c/out" && ! grep -q "linked: [^ ]*$U ->" "$t/c/out" && ! ls "$t/c/home/.config/systemd/user/" | grep -q '\.bak\.'; } \
  && ok "(c) already-linked retired unit: reported, not re-linked, not removed" || bad "(c) $(cat "$t/c/out")"

# (d) malformed rows: WARN, ignored, no crash; the good row still applies
mkrepo d; printf 'justonefield\n\ndf\t/abs/path\tx\tt\ndf\t../esc\tx\tt\n# comment\ndf\t%s\tabc\tt\n' "$D" > "$t/d/retired.tsv"
run d FLEET_SYNC_RETIRED="$t/d/retired.tsv"
{ [ "$(cat "$t/d/rc")" = 0 ] && [ "$(grep -c '^WARN malformed retired row' "$t/d/err")" = 3 ] && [ ! -e "$t/d/home/$D" ] && grep -qx "SKIP retired $D" "$t/d/out" && [ -L "$t/d/home/keep.txt" ]; } \
  && ok "(d) malformed rows warn (3), good row applies, rc 0" || bad "(d) rc=$(cat "$t/d/rc") err=$(cat "$t/d/err")"

# (e) default path used when FLEET_SYNC_RETIRED unset
mkrepo e; mkdir -p "$t/e/home/.local/state/fleet-sync-retired"
printf 'df\t%s\tabc\tt\n' "$D" > "$t/e/home/.local/state/fleet-sync-retired/retired.tsv"
run e
{ [ ! -e "$t/e/home/$D" ] && grep -qx "SKIP retired $D" "$t/e/out"; } \
  && ok "(e) default retired.tsv under HOME honoured" || bad "(e) $(cat "$t/e/out")"

exit $fail
