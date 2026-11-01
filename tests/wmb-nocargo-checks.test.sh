#!/usr/bin/env bash
# wmb-nocargo-checks.sh gate: synthetic wm-build trees under mktemp.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sut="$here/.local/bin/wmb-nocargo-checks.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export NOCARGO_MIN_LITERALS=0
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# mk DIR : clean tree (one operator op, one non-operator op, both written)
mk() {
    mkdir -p "$1/src/sub"
    cat > "$1/src/actor.rs" <<'RS'
pub const OPERATOR_OPS: &[&str] = &[
    "run-paused",
];
pub const NON_OPERATOR_OPS: &[&str] = &[
    "tick",
];
RS
    printf '%s\n' 'fn a() { s.journal("runs", "run-paused", &j); }' > "$1/src/sub/a.rs"
    printf '%s\n' 'fn b() { s.journal("daemon", "tick", &j); }' > "$1/src/b.rs"
}

mk "$tmp/clean"
out=$(bash "$sut" "$tmp/clean"); rc=$?
check "clean tree exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "rc=$rc $out"
check "clean tree prints green" "$([ "$out" = "NOCARGO green ops=2" ] && echo 0 || echo 1)" "$out"

mk "$tmp/unl"
printf '%s\n' 'fn c() {' '    s.journal("runs",' '        "new-op", &j);' '    s.journal("runs", "new-op2", &j);' '}' > "$tmp/unl/src/sub/c.rs"
out=$(bash "$sut" "$tmp/unl"); rc=$?
check "unlisted literal exits 1" "$([ "$rc" = 1 ] && echo 0 || echo 1)" "rc=$rc"
check "unlisted literal reported" "$(printf '%s\n' "$out" | grep -q '^UNCLASSIFIED new-op2 src/sub/c.rs:4$' && echo 0 || echo 1)" "$out"
check "multi-line call matched like the Rust scan" "$(printf '%s\n' "$out" | grep -q '^UNCLASSIFIED new-op src/sub/c.rs:3$' && echo 0 || echo 1)" "$out"

mk "$tmp/both"
sed -i 's/"tick",/"tick", "run-paused",/' "$tmp/both/src/actor.rs"
out=$(bash "$sut" "$tmp/both"); rc=$?
check "op in both lists exits 1 with BOTH-LISTS" "$([ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^BOTH-LISTS run-paused$' && echo 0 || echo 1)" "rc=$rc $out"

mk "$tmp/dup"
sed -i 's/"tick",/"tick", "tick",/' "$tmp/dup/src/actor.rs"
out=$(bash "$sut" "$tmp/dup"); rc=$?
check "duplicate exits 1 with DUPLICATE" "$([ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^DUPLICATE NON_OPERATOR_OPS tick$' && echo 0 || echo 1)" "rc=$rc $out"

mk "$tmp/stale"
rm "$tmp/stale/src/sub/a.rs"
out=$(bash "$sut" "$tmp/stale"); rc=$?
check "stale operator op exits 1" "$([ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^STALE-OPERATOR run-paused$' && echo 0 || echo 1)" "rc=$rc $out"

mk "$tmp/noactor"; rm "$tmp/noactor/src/actor.rs"
bash "$sut" "$tmp/noactor" >/dev/null 2>&1; rc=$?
check "missing actor.rs exits 2" "$([ "$rc" = 2 ] && echo 0 || echo 1)" "rc=$rc"

mk "$tmp/nolist"; printf '%s\n' 'pub const OPERATOR_OPS: &[&str] = &["run-paused"];' > "$tmp/nolist/src/actor.rs"
bash "$sut" "$tmp/nolist" >/dev/null 2>&1; rc=$?
check "missing list exits 2" "$([ "$rc" = 2 ] && echo 0 || echo 1)" "rc=$rc"

bash "$sut" >/dev/null 2>&1; rc=$?
check "no args exits 2" "$([ "$rc" = 2 ] && echo 0 || echo 1)" "rc=$rc"

out=$(bash "$sut" --selftest); rc=$?
check "--selftest exits 0" "$([ "$rc" = 0 ] && [ "$out" = "SELFTEST ok" ] && echo 0 || echo 1)" "rc=$rc $out"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
