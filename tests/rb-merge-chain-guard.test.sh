#!/usr/bin/env bash
# tests/rb-merge-chain-guard.test.sh -- .local/bin/rb-merge.sh chain guard (r7 9:26 PM, ctl 382b, approval 51): a discovery chain PR (CHAIN_REPOS) merges only
# from WM_SEAT=aide or with --handoff <d-id> naming a wm-decide row (agent aide, text names repo + this PR); anything else exits 3 before any gh / merge-gate call.
# Plain bash, run from the repo root:  bash tests/rb-merge-chain-guard.test.sh   (GUARD_WRAP=<path> points it at a scratch copy for the mutation check)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="${GUARD_WRAP:-$here/.local/bin/rb-merge.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rbmgg.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok - rb-merge chain guard: $1"; }
bad() { n=$((n+1)); echo "NOT OK - rb-merge chain guard: $1"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

OID=a1b2c3d4e5f60123456789abcdef0123456789ab
cat > "$tmp/wm-decide" <<'S'
#!/usr/bin/env bash
printf 'wmd %s\n' "$*" >> "$STUB_LOG/calls"
case "$1" in
  list) printf '%s\n' "${STUB_ROWS:-[]}"; exit 0 ;;
  merge-gate) echo "PASS verdict=$2 pr=$5#$4 oid=$STUB_OID"; exit 0 ;;
  merge-done) exit 0 ;;
esac
S
cat > "$tmp/gh" <<'S'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG/calls"
case "$1 $2" in
  "pr view") case "$*" in *mergeCommit*) echo b1b2c3d4e5f60123456789abcdef0123456789ab ;; *) echo '{"title":"T","body":"b"}' ;; esac ;;
  "api repos/"*"/pulls/"*"/commits") echo "aaaaaaaaaaaa false" ;;
  "api repos/"*) echo "T" ;;
esac
exit 0
S
chmod +x "$tmp/wm-decide" "$tmp/gh"
export STUB_LOG="$tmp" STUB_OID="$OID" WM_DECIDE_BIN="$tmp/wm-decide" RB_MERGE_GH="$tmp/gh"
V=d-20261027-210000-r7-abcd; H=d-20261027-212000-aide-1234
REFUSED='rb-merge: REFUSED discovery chain PR j0yen/synthorg#449 needs WM_SEAT=aide or --handoff <aide d-id> (approval 51)'
row() { printf '[{"id":"%s","agent":"%s","what":"%s"}]' "$H" "$1" "$2"; }
run() { : > "$tmp/calls"; "$@" >/dev/null 2>"$tmp/err"; rc=$?; }
merges() { grep -c 'pr merge' "$tmp/calls"; }

run env -u WM_SEAT bash "$wrap" $V 449 j0yen/synthorg
check "$rc:$(cat "$tmp/err"):$(wc -l <"$tmp/calls")" "3:$REFUSED:0" "a: chain repo, WM_SEAT unset -> exit 3, the REFUSED line, no gh / wm-decide call at all"
run env WM_SEAT=r7 bash "$wrap" $V 449 j0yen/synthorg
check "$rc:$(cat "$tmp/err"):$(merges)" "3:$REFUSED:0" "b: chain repo, WM_SEAT=r7 -> same refusal, no merge"
run env WM_SEAT=aide bash "$wrap" $V 449 j0yen/synthorg
check "$rc:$(grep -c '^wmd merge-gate' "$tmp/calls"):$(merges)" "0:1:1" "c: WM_SEAT=aide -> reaches the merge-gate and the merge"
run env WM_SEAT=r7 STUB_ROWS="$(row aide 'GATED j0yen/synthorg pr=449 handoff')" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(grep -c '^wmd merge-gate' "$tmp/calls"):$(merges)" "0:1:1" "d: WM_SEAT=r7 + --handoff row (agent aide, names repo + pr=449) -> proceeds"
run env WM_SEAT=r7 STUB_ROWS="$(row aide 'handoff j0yen/synthorg#449')" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(merges)" "0:1" "d2: the #N form of the row text also proceeds"
run env WM_SEAT=r7 STUB_ROWS="$(row r7 'GATED j0yen/synthorg pr=449')" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(cat "$tmp/err"):$(merges)" "3:$REFUSED:0" "e: --handoff row with agent=r7 -> refused"
run env WM_SEAT=r7 STUB_ROWS="$(row aide 'GATED j0yen/synthorg pr=4490')" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(merges)" "3:0" "f: --handoff row naming pr=4490 (not 449) -> refused"
run env WM_SEAT=r7 STUB_ROWS="$(row aide 'GATED j0yen/synthorg pr=450')" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(merges)" "3:0" "f2: --handoff row naming a different PR -> refused"
run env WM_SEAT=r7 STUB_ROWS="[]" bash "$wrap" $V 449 j0yen/synthorg --handoff $H
check "$rc:$(merges)" "3:0" "h: --handoff id with no such row -> refused"
check "$(grep -c '^wmd \(record\|merge-done\)' "$tmp/calls")" "0" "the guard only reads (no record / write call)"
run env -u WM_SEAT bash "$wrap" $V 7 j0yen/dotfiles
check "$rc:$(grep -c '^wmd merge-gate' "$tmp/calls"):$(merges):$(wc -c <"$tmp/err")" "0:1:1:0" "g: non-chain repo, WM_SEAT unset -> today's path, unchanged"

echo "rb-merge-chain-guard: $n checks, fail=$fail"
exit "$fail"
