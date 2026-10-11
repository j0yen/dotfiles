#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC5: no .git in $PRD_DIR, or sqlite3
# absent -> exit 0 within 500 ms and exactly one `cannot verify` line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

cmd="git mv build-queue/PRD-x.md parked/ # because: run=515"
timed() { # $1=label; uses current env/PATH
  local s e ms
  s=$(date +%s%N); run_hook "$(bash_payload "$cmd")"; e=$(date +%s%N); ms=$(( (e - s) / 1000000 ))
  assert_eq "$rc" "0" "$1: exit 0"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'cannot verify')" "1" "$1: one cannot verify line"
  assert_eq "$([[ $out != *$'\n'* ]] && echo 1 || echo many)" "1" "$1: nothing else printed"
  [ "$ms" -lt 500 ] && echo "ok - $1: ${ms} ms < 500" || { echo "NOT OK - $1: ${ms} ms"; fail=1; }
}

(PRD_DIR="$work/nogit"; mkdir -p "$PRD_DIR"; timed "no .git")

mkdir -p "$work/nobin"
for t in jq bash cat git date grep sort head mkdir dirname; do
  p=$(command -v "$t") && ln -sf "$p" "$work/nobin/$t"
done
(PATH="$work/nobin"; timed "no sqlite3")
exit $fail
