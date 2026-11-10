#!/usr/bin/env bash
# agorabus-lock-refresh-consume.sh: stub wm-asks on a temp dir (A1493).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="${LOCKREF_CONSUME_SCRIPT:-$here/.local/bin/agorabus-lock-refresh-consume.sh}"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok() { echo "ok - $1"; }
no() { echo "NOT OK - $1"; fail=1; }
G='2026-11-09T22:30:01-08:00 deny=green refreshed=yes tests=pass dir=/x/20261109 head=71b4e63'

# setup <name> <stub rc>: dir with a stub wm-asks that logs argv and prints an ask id
setup() {
  local d="$tmp/$1"; mkdir -p "$d/state"
  cat > "$d/stub" <<T
#!/bin/sh
echo "\$*" >> "$d/asklog"
[ $2 -eq 0 ] && echo "A9001 added"
exit $2
T
  chmod +x "$d/stub"
}
run() { LOCK_REFRESH_DIR="$tmp/$1/state" WM_ASKS_BIN="$tmp/$1/stub" bash "$S" >"$tmp/$1/out" 2>&1; }
n() { [ -f "$tmp/$1/asklog" ] && wc -l < "$tmp/$1/asklog" || echo 0; }

setup g 0; echo "$G" > "$tmp/g/state/pending.txt"; run g; rc=$?
[ $rc -eq 0 ] && [ "$(n g)" = 1 ] && ok "green: one ask" || no "green: one ask (rc=$rc n=$(n g))"
grep -q -- '--by rb --owner rb' "$tmp/g/asklog" && grep -q '71b4e63' "$tmp/g/asklog" && ok "ask args" || no "ask args"
[ ! -e "$tmp/g/state/pending.txt" ] && [ -f "$tmp/g/state/pending.consumed-71b4e63.txt" ] && ok "pending renamed" || no "pending renamed"
awk -F'\t' '$2=="71b4e63" && $3=="A9001"{f=1} END{exit !f}' "$tmp/g/state/consumed.tsv" && ok "consumed.tsv row" || no "consumed.tsv row"

echo "$G" > "$tmp/g/state/pending.txt"; run g; rc=$?
[ $rc -eq 0 ] && [ "$(n g)" = 1 ] && [ "$(wc -l < "$tmp/g/state/consumed.tsv")" = 1 ] && ok "same head twice: still one ask" || no "same head twice"

setup r 0; echo "${G/deny=green/deny=red}" > "$tmp/r/state/pending.txt"; run r; rc=$?
[ $rc -eq 0 ] && [ "$(n r)" = 0 ] && [ -s "$tmp/r/state/pending.txt" ] && [ -s "$tmp/r/state/refused.txt" ] && ok "deny=red: refused, left in place" || no "deny=red"

setup t 0; echo "${G/tests=pass/tests=fail}" > "$tmp/t/state/pending.txt"; run t
[ "$(n t)" = 0 ] && [ -s "$tmp/t/state/pending.txt" ] && [ -s "$tmp/t/state/refused.txt" ] && ok "tests=fail refused" || no "tests=fail"

setup m 0; echo "garbage line" > "$tmp/m/state/pending.txt"; run m
[ "$(n m)" = 0 ] && [ -s "$tmp/m/state/pending.txt" ] && [ -s "$tmp/m/state/refused.txt" ] && ok "malformed refused" || no "malformed"

setup f 1; echo "$G" > "$tmp/f/state/pending.txt"; run f; rc=$?
[ $rc -ne 0 ] && [ -s "$tmp/f/state/pending.txt" ] && [ ! -e "$tmp/f/state/consumed.tsv" ] && ok "stub failure: untouched, rc!=0" || no "stub failure (rc=$rc)"

setup e 0; : > "$tmp/e/state/pending.txt"; run e; rc=$?
[ $rc -eq 0 ] && [ "$(n e)" = 0 ] && ok "empty: no-op" || no "empty"
setup a 0; run a; rc=$?
[ $rc -eq 0 ] && [ "$(n a)" = 0 ] && ok "absent: no-op" || no "absent"

exit $fail
