#!/bin/bash
# r7-mcp-gate-remote.sh <base-sha> <head-sha> — ryzen7 side of the mcphost hand-PR merge-gate log (G3: "-D warnings EXIT=0" +
# "clippy delta=0" + "cargo test ... EXIT=0"). Called by r7-mcp-gate.sh on carbon INSIDE a memory-admitted slot (wm-build
# builder cargo-jobs acquire, ctl c0f8) and a cgroup scope at the slot's price. Everything lives in its own mktemp dir
# (clone + target); removed at the end. Exit = cargo check's rc, or 1 if clippy delta > 0, or the touched-test rc.
# --selftest: the touched-test target mapping and the "0 tests ran" rule on a stub cargo in a mktemp dir (no clone, no cargo).
set -u
export PATH=$HOME/.cargo/bin:$PATH CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-6}
CARGO=${R7_GATE_CARGO:-cargo}

# test_args <stem>: argv for `cargo test` of tests/<stem>.rs. A file a suite target #[path]-includes is no target of its own
# (mcphost suites, row 2726) -> its parent target, filtered to `<stem>::`. Run from the repo root.
test_args() {
  local p; p=$(grep -lxF "#[path = \"$1.rs\"]" tests/*.rs 2>/dev/null | head -1 | sed -nE 's#^tests/([^/]+)\.rs$#\1#p')
  if [ -n "$p" ]; then printf '%s\n' --test "$p" "$1::"; else printf '%s\n' --test "$1"; fi
}
# run_touched <stem>: one `cargo test` + its EXIT line; rc 0 with no "test result: ok. [1-9]" = 0 tests ran = rc 1.
run_touched() {
  local a o r; mapfile -t a < <(test_args "$1")
  o=$("$CARGO" test --locked "${a[@]}" 2>&1); r=$?; printf '%s\n' "$o" | grep -E '^test result:|^error' | tail -3
  [ "$r" = 0 ] && ! printf '%s\n' "$o" | grep -qE '^test result: ok\. [1-9]' && { echo "cargo test ${a[*]}: 0 tests ran"; r=1; }
  echo "cargo test --locked ${a[*]} EXIT=$r"; return $r
}

selftest() {
  local S fail=0 o; S=$(mktemp -d); mkdir -p "$S/tests"
  printf '#[path = "inner_a.rs"]\nmod inner_a;\n' > "$S/tests/suite_x_01.rs"; : > "$S/tests/inner_a.rs"; : > "$S/tests/solo_b.rs"
  printf '#!/bin/bash\n# stub cargo: argv to a file; R7_STUB_OUT is the test output\necho "$*" >> "%s/argv"; printf "%%s\\n" "$R7_STUB_OUT"; exit ${R7_STUB_RC:-0}\n' "$S" > "$S/cargo"
  chmod +x "$S/cargo"
  ck() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
  ( cd "$S" && [ "$(test_args inner_a | tr '\n' ' ')" = "--test suite_x_01 inner_a:: " ] ); ck $? "a #[path] module runs as its parent target filtered to <stem>::"
  ( cd "$S" && [ "$(test_args solo_b | tr '\n' ' ')" = "--test solo_b " ] ); ck $? "a standalone test file runs as its own target"
  o=$(cd "$S" && R7_GATE_CARGO=$S/cargo R7_STUB_OUT='test result: ok. 0 passed; 0 failed' CARGO=$S/cargo run_touched inner_a); r=$?
  [ $r = 1 ] && printf '%s\n' "$o" | grep -q '0 tests ran' && printf '%s\n' "$o" | grep -q 'EXIT=1$'; ck $? "rc 0 with 0 tests ran -> EXIT=1"
  o=$(cd "$S" && R7_STUB_OUT='test result: ok. 3 passed; 0 failed' CARGO=$S/cargo run_touched inner_a); r=$?
  [ $r = 0 ] && printf '%s\n' "$o" | grep -q 'cargo test --locked --test suite_x_01 inner_a:: EXIT=0'; ck $? "3 tests ran -> EXIT=0 with the parent-target argv"
  o=$(cd "$S" && R7_STUB_OUT='test result: FAILED. 2 passed; 1 failed' R7_STUB_RC=101 CARGO=$S/cargo run_touched solo_b); r=$?
  [ $r = 101 ] && printf '%s\n' "$o" | grep -q 'EXIT=101$'; ck $? "a red test keeps cargo's rc"
  rm -rf "$S"; [ $fail = 0 ] && echo "selftest ok" || echo "selftest FAIL"; return $fail
}
if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

B=$1 H=$2; D=$(mktemp -d -p "$HOME/.cache" r7-mcpgate.XXXX); trap 'rm -rf "$D"' EXIT
URL=https://github.com/j0yen/mcphost.git
git clone -q "$URL" "$D/m" && cd "$D/m" && git fetch -q origin "$H" || { echo "clone/fetch failed"; exit 3; }
export CARGO_TARGET_DIR=$D/target
# clippy delta at CI scope (.github/workflows/ci.yml: cargo clippy --locked --workspace -- -D warnings); --all-targets new lines = info only
lint_lines() { "$CARGO" clippy --locked --keep-going --message-format=short "$@" 2>&1 | grep -E '^[^ ]+:[0-9]+:[0-9]+: (warning|error)' | sed -E 's/:[0-9]+:[0-9]+:/:/' | sort; }
git checkout -q "$B" && lint_lines --workspace > "$D/bw" && lint_lines --workspace --all-targets > "$D/ba"
git checkout -q "$H" && lint_lines --workspace > "$D/hw" && lint_lines --workspace --all-targets > "$D/ha"
nb=$(wc -l < "$D/bw"); nh=$(wc -l < "$D/hw")
echo "clippy scope=--workspace (CI) base=$B lints=$nb head=$H lints=$nh"; echo "clippy delta=$((nh-nb))"
echo "info: --all-targets base=$(wc -l < "$D/ba") head=$(wc -l < "$D/ha"); lines new at head:"; comm -13 "$D/ba" "$D/ha" | head -12
RUSTFLAGS='-D warnings' "$CARGO" check --locked --all-targets 2>&1 | tail -3; rc=${PIPESTATUS[0]}; echo "RUSTFLAGS=-D warnings cargo check --all-targets EXIT=$rc"
# cargo test token line (ctl 1:2x item 3: check + clippy alone never ran the edited tests): every tests/*.rs the PR touches runs
# via run_touched; none touched -> the workspace lib tests. One EXIT line each.
trc=0; ts=$(git diff --name-only "$B" "$H" -- 'tests/*.rs' | sed -nE 's#^tests/([^/]+)\.rs$#\1#p')
if [ -n "$ts" ]; then for t in $ts; do [ -f "tests/$t.rs" ] || { echo "cargo test --test $t SKIP (deleted at head)"; continue; }
    run_touched "$t" || trc=$?; done
else "$CARGO" test --locked --workspace --lib 2>&1 | grep -E '^test result:|^error' | tail -3; trc=${PIPESTATUS[0]}; echo "cargo test --locked --workspace --lib EXIT=$trc"; fi
echo "cargo test touched=$(echo $ts | wc -w) EXIT=$trc"
[ "$rc" = 0 ] && [ $((nh-nb)) -le 0 ] || { [ "$rc" = 0 ] && rc=1; }
[ "$rc" = 0 ] && [ "$trc" != 0 ] && rc=$trc
exit $rc
