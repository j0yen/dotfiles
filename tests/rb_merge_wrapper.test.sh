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
exit "${STUB_GH_RC:-0}"
S
chmod +x "$tmp/wm-decide" "$tmp/gh"
export STUB_LOG="$tmp" STUB_OID="$OID" WM_DECIDE_BIN="$tmp/wm-decide" RB_MERGE_GH="$tmp/gh"
V=d-20261022-140000-rb-abcd

: > "$tmp/calls"; bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc" "0" "a passing gate merges"
grep -qF "gh [GATE_OK=$V] pr merge 7 --repo j0yen/swarm-decide --squash --match-head-commit $OID" "$tmp/calls" && ok "gh got --squash --match-head-commit with the FULL 40-hex OID and WM_DECIDE_GATE_OK=<verdict>" || bad "gh call wrong: $(cat "$tmp/calls")"
check "$(grep -c '' "$tmp/calls"):$(sed -n 3p "$tmp/calls")" "3:wmd merge-done $V --pr 7 --repo j0yen/swarm-decide --oid $OID" "merge-done runs after gh, with the oid"

: > "$tmp/calls"; STUB_GATE=fail bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc" "2" "a refused gate exits 2 (the gate's own rc)"
check "$(grep -c '^gh' "$tmp/calls")" "0" "a refused gate never reaches gh"
check "$(grep -c 'FAIL' "$tmp/err")" "2" "the gate's one-line-per-rule stderr reaches the terminal"

: > "$tmp/calls"; STUB_GATE=short bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc:$(grep -c '^gh' "$tmp/calls")" "3:0" "a PASS line without a full 40-hex oid is refused before gh"

: > "$tmp/calls"; STUB_GH_RC=1 bash "$wrap" $V 7 j0yen/swarm-decide >/dev/null 2>&1; rc=$?
check "$rc:$(grep -c 'merge-done' "$tmp/calls")" "1:0" "gh failing: rc 1 and merge-done is not run (no pr-merged event)"

bash "$wrap" $V seven j0yen/swarm-decide >/dev/null 2>&1; check "$?" "64" "a non-numeric pr is a usage error"
bash "$wrap" $V 7 swarm-decide >/dev/null 2>&1;          check "$?" "64" "repo must be owner/name"
bash "$wrap" $V 7 j0yen/swarm-decide --auto >/dev/null 2>&1; check "$?" "64" "no extra gh flags (--auto) are accepted"

# structure: strict mode, the gate is never on the left of a pipe, merge only after && from the capture
grep -q '^set -euo pipefail' "$wrap" && ok "set -euo pipefail" || bad "set -euo pipefail missing"
if grep -nE 'merge-gate[^#]*\|' "$wrap" | grep -v '^\s*#' | grep -q .; then bad "merge-gate is piped"; else ok "merge-gate output is captured, not piped"; fi
grep -q 'merge-gate' "$wrap" && grep -q -- '--match-head-commit "\$oid"' "$wrap" && ok "gh pr merge --match-head-commit \$oid is in the wrapper" || bad "wrapper missing match-head-commit"

[ "$fail" = 0 ] && echo "ALL OK - rb-merge" || echo "FAILED - rb-merge"
exit "$fail"
