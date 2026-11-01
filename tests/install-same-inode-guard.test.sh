#!/usr/bin/env bash
# install.sh must not replace a file with a symlink to itself when the target path already resolves to the source
# through a parent-directory symlink (the 10-22 ~/.config/claude-seat incident).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/.config/seat" "$t/home/.config"
printf '{"a":1}\n' > "$t/repo/.config/seat/s.json"
ln -s "$t/repo/.config/seat" "$t/home/.config/seat"
( cd "$t/repo" && HOME="$t/home" bash "$here/install.sh" >/dev/null 2>&1 )
fail=0
[ -f "$t/repo/.config/seat/s.json" ] && [ ! -L "$t/repo/.config/seat/s.json" ] && echo "PASS repo file still a regular file" || { echo "FAIL repo file replaced ($(ls -la "$t/repo/.config/seat/" | tail -n +4 | tr '\n' ' '))"; fail=1; }
[ "$(cat "$t/home/.config/seat/s.json" 2>/dev/null)" = '{"a":1}' ] && echo "PASS target still readable" || { echo "FAIL target unreadable"; fail=1; }
ls "$t/repo/.config/seat/" | grep -q '\.bak\.' && { echo "FAIL backup created"; fail=1; } || echo "PASS no backup created"
exit $fail
