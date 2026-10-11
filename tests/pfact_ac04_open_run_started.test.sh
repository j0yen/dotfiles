#!/usr/bin/env bash
# PRD dotfiles-park-requires-fresh-fact AC4: 3 commits on the slug in the last
# hour and because: run=<open run started after all three> -> exit 0 (an open
# run's started is the fact time).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/pfact_test_helpers.sh"
pfact_setup

for m in 50 40 30; do
  echo "- n$m" >>"$PRD_DIR/build-queue/PRD-x.md"; git -C "$PRD_DIR" add -A
  fx_commit "$m" "touch x at $m"
done
sqlite3 "$WM_STATE_DB" "insert into runs(id,slug,started,ended) values (700,'x','$(iso_ago 10)',NULL)"
sqlite3 "$WM_STATE_DB" "insert into runs(id,slug,started,ended) values (701,'x','$(iso_ago 20)','')"

run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/ # because: run=700")"
assert_eq "$rc" "0" "open run started after all three commits passes"
assert_eq "$out" "" "no stdout"
run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/ # because: run=701")"
assert_eq "$rc" "0" "empty-string ended also falls back to started"
sqlite3 "$WM_STATE_DB" "insert into runs(id,slug,started,ended) values (702,'x','$(iso_ago 45)',NULL)"
run_hook "$(bash_payload "git mv build-queue/PRD-x.md parked/ # because: run=702")"
assert_eq "$rc" "2" "open run started before the newest commit is refused"
exit $fail
