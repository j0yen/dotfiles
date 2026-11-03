#!/usr/bin/env bash
# five-whys-spec-rows (A684, 11-03 ryzen7 root-fill page Fable edit 6): a numbered Mechanisms line carrying `state SPEC`
# must name an open-asks / wm-decide row id; the fixture is a copy of the 10-30 ryzen7 disk-low page's Mechanisms section.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
B="$here/.local/bin/five-whys-spec-rows.sh"; F="$here/tests/fixtures/five-whys-spec-rows"
bash -n "$B" && ok "bash -n" || bad "bash -n"
[ -x "$B" ] && ok "executable" || bad "not executable"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
printf 'id\tasked\towner\tdue\tkey\tcheck\twhat\n' > "$t/empty.tsv"
{ cat "$t/empty.tsv"; for i in 1 2 3; do printf 'A90%s\t2026-10-30T12:00\tr7\t2026-10-31T12:00\tk\tc\tw\n' "$i"; done; printf '# CLOSED\n'; } > "$t/three.tsv"
: > "$t/fu.txt"
out="$(bash "$B" --ledger "$t/empty.tsv" --followups "$t/fu.txt" "$F/page.md" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | grep -c '^FAIL')" = 3 ] && ok "fixture with an empty ledger fails (3 SPEC lines, exit 1)" || { bad "empty ledger: rc=$rc"; printf '%s\n' "$out"; }
out="$(bash "$B" --ledger "$t/three.tsv" --followups "$t/fu.txt" "$F/page.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '3 SPEC mechanism line(s) rowed' && ok "same fixture with three rows passes (exit 0)" || { bad "three rows: rc=$rc"; printf '%s\n' "$out"; }
out="$(bash "$B" --ledger "$t/three.tsv" --followups "$t/fu.txt" "$F/page-unrowed.md" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | grep -c '^FAIL')" = 1 ] && ok "a SPEC line naming no id fails alone" || { bad "unrowed line: rc=$rc"; printf '%s\n' "$out"; }
printf 'd-20261030-120000-r7-abcd\n' > "$t/fu.txt"; sed -E 's/\(A901\)/(d-20261030-120000-r7-abcd)/' "$F/page.md" > "$t/page-d.md"
out="$(bash "$B" --ledger "$t/three.tsv" --followups "$t/fu.txt" "$t/page-d.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a wm-decide d-id from the followups file counts as a row" || { bad "d-id: rc=$rc"; printf '%s\n' "$out"; }
bash "$B" >/dev/null 2>&1; [ $? = 2 ] && ok "no page = usage exit 2" || bad "usage exit"
exit $fail
