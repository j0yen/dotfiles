#!/usr/bin/env bash
# tests/rb_merge_wrapper.test.sh -- .local/bin/rb-merge.sh: the gate output is captured (never piped), a refused gate stops before gh,
# gh gets --match-head-commit with the FULL 40-hex OID the gate printed, and merge-done runs only after gh rc 0 (M7, M10).
# Plain bash, run from the repo root:  bash tests/rb_merge_wrapper.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="$here/.local/bin/rb-merge.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rbmerge.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok - rb-merge: $1"; }
bad() { echo "NOT OK - rb-merge: $1"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

OID=a1b2c3d4e5f60123456789abcdef0123456789ab
cat > "$tmp/wm-decide" <<'S'
#!/usr/bin/env bash
printf 'wmd %s\n' "$*" >> "$STUB_LOG/calls"
case "$1" in
  merge-gate) case "${STUB_GATE:-pass}" in
      pass) echo "PASS verdict=$2 pr=$5#$4 oid=$STUB_OID"; exit 0 ;;
      short) echo "PASS verdict=$2 pr=$5#$4 oid=a1b2c3d4e5f6"; exit 0 ;;
      fail) echo "G0 FAIL verdict=$2: final verdict is CORRECT" >&2; echo "G3 FAIL verdict=$2: no log" >&2; exit 2 ;;
    esac ;;
  merge-done) exit 0 ;;
esac
S
cat > "$tmp/gh" <<'S'
#!/usr/bin/env bash
printf 'gh [GATE_OK=%s] %s\n' "${WM_DECIDE_GATE_OK:-}" "$*" >> "$STUB_LOG/calls"
case "$1 $2" in
  "pr view") case "$*" in
      *mergeCommit*) echo "${STUB_MC:-b1b2c3d4e5f60123456789abcdef0123456789ab}" ;;
      *) printf '{"title":"Fix the thing","body":"line one\\nCo-authored-by: Claude <x@y>\\nGenerated with Claude Code\\n  co-authored-by: indented <z@y>\\nline two mentions a Co-authored-by: trailer line in prose"}\n' ;;
    esac; exit 0 ;;
  "pr merge")
    # keep the --body argument verbatim (it spans lines, so the calls log cannot hold it)
    prev=""; for a in "$@"; do [ "$prev" = "--body" ] && printf '%s' "$a" > "$STUB_LOG/body"; prev="$a"; done
    exit "${STUB_GH_RC:-0}" ;;
  "api repos/"*"/pulls/"*"/commits")
    [ "${STUB_API_RC:-0}" = 0 ] || exit "$STUB_API_RC"
    # RAW commit JSON through the wrapper's own -q filter with the real jq (the old stub emitted pre-filtered lines, which hid the prose false-positive)
    q=""; prev=""; for a in "$@"; do { [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; } && q="$a"; prev="$a"; done
    dflt='[{"sha":"aaaaaaaaaaaa0000","commit":{"message":"Fix the thing"}}]'
    printf '%s' "${STUB_COMMITS_JSON-$dflt}" | jq -r "$q"; exit $? ;;
  "api repos/"*) printf '%s\n' "${STUB_MSG:-Fix the thing}"; exit 0 ;;
esac
exit "${STUB_GH_RC:-0}"
S
chmod +x "$tmp/wm-decide" "$tmp/gh"
export STUB_LOG="$tmp" STUB_OID="$OID" WM_DECIDE_BIN="$tmp/wm-decide" RB_MERGE_GH="$tmp/gh"
V=d-20261022-140000-rb-abcd

: > "$tmp/calls"; bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc" "0" "a passing gate merges"
grep -qF "gh [GATE_OK=$V] pr merge 7 --repo j0yen/swarm-decide --squash --match-head-commit $OID" "$tmp/calls" && ok "gh got --squash --match-head-commit with the FULL 40-hex OID and WM_DECIDE_GATE_OK=<verdict>" || bad "gh call wrong: $(cat "$tmp/calls")"
check "$(grep -c '^wmd merge-done' "$tmp/calls"):$(grep -n '^wmd merge-done' "$tmp/calls" | cut -d: -f1)>$(grep -n 'pr merge' "$tmp/calls" | cut -d: -f1)" "1:$(grep -n '^wmd merge-done' "$tmp/calls" | cut -d: -f1)>$(grep -n 'pr merge' "$tmp/calls" | cut -d: -f1)" "merge-done runs once"
[ "$(grep -n '^wmd merge-done' "$tmp/calls" | cut -d: -f1)" -gt "$(grep -n 'pr merge' "$tmp/calls" | cut -d: -f1)" ] && ok "merge-done runs after gh pr merge" || bad "merge-done not after gh pr merge"
grep -q -- "--subject Fix the thing --body line one" "$tmp/calls" && ok "gh pr merge got the PR title as --subject and the body as --body" || bad "subject/body missing: $(cat "$tmp/calls")"
if grep -qiE '^[[:space:]]*(co-authored-by:|generated with)' "$tmp/body"; then bad "attribution trailer lines reached gh pr merge: $(cat "$tmp/body")"; else ok "trailer lines (incl. an indented one) stripped from the merge body"; fi
grep -qF 'line two mentions a Co-authored-by: trailer line in prose' "$tmp/body" && grep -qx 'line one' "$tmp/body" && ok "the body strip keeps a prose sentence that contains the phrase" || bad "prose line lost from the body: $(cat "$tmp/body")"

: > "$tmp/calls"; STUB_GATE=fail bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc" "2" "a refused gate exits 2 (the gate's own rc)"
check "$(grep -c 'pr merge' "$tmp/calls")" "0" "a refused gate never reaches gh pr merge"
check "$(grep -c 'FAIL' "$tmp/err")" "2" "the gate's one-line-per-rule stderr reaches the terminal"

: > "$tmp/calls"; STUB_GATE=short bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls")" "3:0" "a PASS line without a full 40-hex oid is refused before gh pr merge"

: > "$tmp/calls"; STUB_GH_RC=1 bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc:$(grep -c 'merge-done' "$tmp/calls")" "1:0" "gh failing: rc 1 and merge-done is not run (no pr-merged event)"

MC=b1b2c3d4e5f60123456789abcdef0123456789ab
: > "$tmp/calls"; STUB_MSG=$'Fix\n\nCo-authored-by: Claude <x@y>' bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c "^ATTRIBUTION-LANDED $MC\$" "$tmp/err")" "3:1" "a landed co-author trailer: ATTRIBUTION-LANDED <oid> on stderr, rc 3"
: > "$tmp/calls"; bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; check "$?" "0" "a clean merge commit message passes the post-merge check"
: > "$tmp/calls"; STUB_MSG=$'Fix\n\nThe wrapper now matches a Co-authored-by: trailer line only at line start; generated with care.' bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; check "$?" "0" "landed squash message that MENTIONS the phrases in prose passes"
: > "$tmp/calls"; STUB_MSG=$'Fix\n\nGenerated with Claude Code' bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c "^ATTRIBUTION-LANDED $MC\$" "$tmp/err")" "3:1" "a landed generated-with trailer line: ATTRIBUTION-LANDED, rc 3"

# PRE-merge branch-commit attribution check (controller row 1475: synthorg#398 b44486e9)
: > "$tmp/calls"; bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls")" "0:1" "a clean branch (no trailer commit) merges"
grep -q 'api repos/j0yen/swarm-decide/pulls/7/commits --paginate' "$tmp/calls" && ok "the branch commits are read via pulls/N/commits --paginate" || bad "pulls/N/commits call missing: $(cat "$tmp/calls")"
mkcommits() { jq -n -c --arg p1 "$1" --arg p2 "$2" --arg p3 "$3" --arg p4 "$4" '[{sha:"aaaaaaaaaaaa1111",commit:{message:$p1}},{sha:"b44486e9c0de2222",commit:{message:$p2}},{sha:"cccccccccccc3333",commit:{message:$p3}},{sha:"dddddddddddd4444",commit:{message:$p4}}]'; }
PROSE=$'Fix the wrapper\n\nPR 19 was refused because the check matched a trailer line phrase such as co-authored-by or generated with anywhere in prose.'
: > "$tmp/calls"; STUB_COMMITS_JSON="$(mkcommits "$PROSE" "Add Co-authored-by: in a sentence" "Say generated with care" "Mention the Co-authored-by: header mid-line")" bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls")" "0:1" "commit messages that MENTION a trailer phrase in prose mid-sentence pass"
: > "$tmp/calls"; STUB_COMMITS_JSON="$(mkcommits "clean" $'Subject\n\nCo-authored-by: Claude <x@y>' "clean" "clean")" bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls"):$(grep -c 'merge-done' "$tmp/calls"):$(grep -c '^ATTRIBUTION-BRANCH b44486e9c0de$' "$tmp/err")" "3:0:0:1" "a real trailer line fails with its sha: exit 3, no gh pr merge, no merge-done"
: > "$tmp/calls"; STUB_COMMITS_JSON="$(mkcommits "$PROSE" $'Subject\n\nCo-authored-by: Claude <x@y>' "clean" $'Subject\n   Generated with Claude Code')" bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls"):$(grep -c '^ATTRIBUTION-BRANCH b44486e9c0de dddddddddddd$' "$tmp/err")" "3:0:1" "a mixed PR (prose + trailer + indented trailer): only the trailer commits are named, no merge"
: > "$tmp/calls"; RB_MERGE_ALLOW_BRANCH_TRAILERS=1 STUB_COMMITS_JSON='[{"sha":"b44486e9c0de2222","commit":{"message":"S\n\nCo-authored-by: C <x@y>"}}]' bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls")" "0:1" "RB_MERGE_ALLOW_BRANCH_TRAILERS=1 lets a trailer branch merge"
grep -q 'RB_MERGE_ALLOW_BRANCH_TRAILERS=1' "$tmp/err" && ok "the bypass prints a stderr note" || bad "bypass note missing"
check "$(grep -c 'pulls/7/commits' "$tmp/calls")" "0" "the bypass skips the branch-commit read"
: > "$tmp/calls"; STUB_API_RC=1 bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls"):$(grep -c 'ATTRIBUTION-UNCHECKED' "$tmp/err")" "3:0:1" "branch-commit API failure fails closed: exit 3 ATTRIBUTION-UNCHECKED, no merge"
: > "$tmp/calls"; STUB_COMMITS_JSON='[]' bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(grep -c 'pr merge' "$tmp/calls")" "3:0" "an empty branch-commit list fails closed"

bash "$wrap" $V seven j0yen/swarm-decide >/dev/null 2>&1; check "$?" "64" "a non-numeric pr is a usage error"
bash "$wrap" $V 7 swarm-decide >/dev/null 2>&1;          check "$?" "64" "repo must be owner/name"
bash "$wrap" $V 7 j0yen/swarm-decide --auto >/dev/null 2>&1; check "$?" "64" "no extra gh flags (--auto) are accepted"

# structure: strict mode, the gate is never on the left of a pipe, merge only after && from the capture
grep -q '^set -euo pipefail' "$wrap" && ok "set -euo pipefail" || bad "set -euo pipefail missing"
if grep -nE 'merge-gate[^#]*\|' "$wrap" | grep -v '^\s*#' | grep -q .; then bad "merge-gate is piped"; else ok "merge-gate output is captured, not piped"; fi
grep -q 'merge-gate' "$wrap" && grep -q -- '--match-head-commit "\$oid"' "$wrap" && ok "gh pr merge --match-head-commit \$oid is in the wrapper" || bad "wrapper missing match-head-commit"

[ "$fail" = 0 ] && echo "ALL OK - rb-merge" || echo "FAILED - rb-merge"
exit "$fail"
