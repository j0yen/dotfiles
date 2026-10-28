#!/usr/bin/env bash
# A host-local environment.d TMPDIR (e.g. RedBaron 50-tmpdir.conf -> /mnt/data/tmp/user) must beat the fleet 05-tmpdir.conf,
# both in environment.d lexical resolution and in install.sh (which must not link the fleet file over/beside it).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fleet=$here/.config/environment.d/05-tmpdir.conf
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

name=$(basename "$fleet")
if [[ "$name" < "50-" ]]; then pass "fleet file $name sorts before 50-"; else bad "fleet file $name does not sort before 50-"; fi

mkdir -p "$t/cfg/environment.d"
cp "$fleet" "$t/cfg/environment.d/$name"
echo 'TMPDIR=/mnt/x' > "$t/cfg/environment.d/50-tmp.conf"
got=
while IFS= read -r f; do
  v=$(sed -n 's/^TMPDIR=//p' "$f" | tail -n1)
  if [ -n "$v" ]; then got=$v; fi
done < <(find "$t/cfg/environment.d" -type f | LC_ALL=C sort)
if [ "$got" = /mnt/x ]; then pass "lexical resolve: host-local wins ($got)"; else bad "lexical resolve gave '$got'"; fi

gen=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
if [ -x "$gen" ]; then
  got=$(HOME="$t/h" XDG_CONFIG_HOME="$t/cfg" XDG_CONFIG_DIRS="$t/none" "$gen" | sed -n 's/^TMPDIR=//p' | tail -n1)
  if [ "$got" = /mnt/x ]; then pass "systemd generator: host-local wins ($got)"; else bad "systemd generator gave '$got'"; fi
else
  echo "SKIP systemd environment.d generator absent"
fi

# install.sh: host-local TMPDIR file present -> fleet file not linked; absent -> linked
mkdir -p "$t/home1/.config/environment.d" "$t/home2"
echo 'TMPDIR=/mnt/x' > "$t/home1/.config/environment.d/50-tmpdir.conf"
HOME="$t/home1" bash "$here/install.sh" >/dev/null 2>&1
if [ ! -e "$t/home1/.config/environment.d/$name" ] && [ ! -L "$t/home1/.config/environment.d/$name" ]; then pass "install.sh skipped fleet file next to host-local TMPDIR"; else bad "install.sh linked fleet file despite host-local TMPDIR"; fi
if [ "$(cat "$t/home1/.config/environment.d/50-tmpdir.conf")" = TMPDIR=/mnt/x ]; then pass "host-local file untouched"; else bad "host-local file changed"; fi
HOME="$t/home2" bash "$here/install.sh" >/dev/null 2>&1
if [ -L "$t/home2/.config/environment.d/$name" ]; then pass "install.sh links fleet file on a clean host"; else bad "install.sh did not link fleet file on a clean host"; fi

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
