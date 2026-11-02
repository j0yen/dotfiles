#!/usr/bin/env bash
# A254: ask-check-lint.sh refuses a source-shaped done-check on a page/tile/prod ask; seat-ask.sh and approve.sh call it.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
L="$here/.local/bin/ask-check-lint.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ASK_CHECK_LINT_DIR="$T/log"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
run() { "$L" "$@" 2>"$T/err"; echo $?; }
[ "$(run --subject "fleet-dash page live on carbon" --check "git ls-remote origin main = 3ec13ae")" = 2 ] && grep -q 'source-shaped check' "$T/err" && ok "ls-remote on page ask refused" || bad "ls-remote on page ask"
[ "$(run --subject "dashboard card fix" --check "git rev-parse HEAD")" = 2 ] && ok "rev-parse refused" || bad "rev-parse"
[ "$(run --subject "prod binary" --check "3ec13ae")" = 2 ] && ok "bare sha refused" || bad "bare sha"
[ "$(run --subject "prod binary" --check "git merge-base --is-ancestor a b")" = 2 ] && ok "merge refused" || bad "merge"
[ "$(run --subject "page live" --check "jq .dash.version status.json = 3ec13ae")" = 0 ] && ok "status.json key passes" || bad "status.json key"
[ "$(run --subject "binary deployed" --check "wm-build --version on rb")" = 0 ] && ok "--version passes" || bad "--version"
[ "$(run --subject "page live" --check "curl -s http://carbon:8787/ | grep Being")" = 0 ] && ok "curl page string passes" || bad "curl"
[ "$(run --subject "refactor lint helper" --check "git ls-remote origin main = abc1234")" = 0 ] && ok "non-consumer subject passes" || bad "non-consumer subject"
[ "$(run --text "page fix done-check: git ls-remote origin main = abc1234 | due 5pm")" = 2 ] && ok "--text extracts check, refuses" || bad "--text refuse"
[ "$(run --text "page fix with no check")" = 0 ] && ok "--text without check passes" || bad "--text nocheck"
f="$T/log/fires.log"
[ "$(grep -c refuse "$f")" = 5 ] && [ "$(grep -c '^' "$f")" = 10 ] && ok "fires.log has every pass and refusal (10 lines, 5 refusals)" || { bad "fires.log"; cat "$f"; }
# call sites
grep -q 'ask-check-lint.sh' "$here/.local/bin/seat-ask.sh" && grep -q 'ask-check-lint.sh' "$here/.local/bin/approve.sh" && ok "seat-ask.sh and approve.sh call the lint" || bad "call sites"
printf '# t\ntst\trb\tsid-x\t20\t100\t^x\t-\n' >"$T/seats.tsv"
out="$(SEATS_TABLE="$T/seats.tsv" SEAT_ASK_DRY=1 SEAT_ASK_TEST=1 SEAT_STAMP_NOW="9:07 PM" EVENTS_DIR="$T/ev" "$here/.local/bin/seat-ask.sh" tst "page live done-check: git ls-remote origin main = abc1234" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"source-shaped check"* ]] && ok "seat-ask.sh refuses (exit 2)" || bad "seat-ask refuse rc=$rc"
out="$(SEATS_TABLE="$T/seats.tsv" SEAT_ASK_DRY=1 SEAT_ASK_TEST=1 SEAT_STAMP_NOW="9:07 PM" EVENTS_DIR="$T/ev" "$here/.local/bin/seat-ask.sh" tst "page live done-check: curl -s http://carbon:8787/ | grep Being" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "seat-ask.sh passes consumer check" || bad "seat-ask pass rc=$rc ($out)"
exit $fail
