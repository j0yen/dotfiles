#!/usr/bin/env bash
# wmb-nocargo-checks.sh: cargo-free mirror of wm-build act_every_journal_op_is_classified.
# Fixtures are real wm-build files (tests/fixtures/wmb-nocargo-checks/README names the shas).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
chk="$here/.local/bin/wmb-nocargo-checks.sh"
fx="$here/tests/fixtures/wmb-nocargo-checks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
five='land-hold-mark-failed land-hold-release-failed land-held-armed land-held-stale land-held-unreadable'

# (a) the script's own selftest
out=$(HOME="$tmp" bash "$chk" --selftest 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "SELFTEST PASS" ]; then ok "(a) --selftest passes"; else bad "(a) --selftest" "rc=$rc $out"; fi

# fixture tree: real actor.rs + the real fleet_hold.rs call sites + witness literals for OPERATOR_OPS
mk() { rm -rf "$tmp/t"; mkdir -p "$tmp/t/src/land"
    cp "$fx/$1/actor.rs" "$tmp/t/src/actor.rs"
    cp "$fx/ba5e1fa1/land/fleet_hold.rs" "$tmp/t/src/land/fleet_hold.rs"
    cp "$fx/ba5e1fa1/witness.rs" "$tmp/t/src/witness.rs"; }

# (b) ba5e1fa1 lists + five fleet_hold.rs ops: red, exactly the five
mk ba5e1fa1
out=$(HOME="$tmp" NOCARGO_MIN_LITERALS=1 bash "$chk" "$tmp/t" 2>&1); rc=$?
got=$(printf '%s\n' "$out" | awk '$1=="UNCLASSIFIED"{print $2}' | sort | tr '\n' ' ')
want=$(printf '%s\n' $five | sort | tr '\n' ' ')
other=$(printf '%s\n' "$out" | grep -vc -e '^UNCLASSIFIED ' -e '^NOCARGO journal-ops red n=5$')
if [ "$rc" = 1 ] && [ "$got" = "$want" ] && [ "$other" = 0 ]; then ok "(b) red, exactly the five ops"; else bad "(b) five ops" "rc=$rc got=[$got] other=$other"; fi

# (c) 254bea47 lists plus the five in NON_OPERATOR_OPS: green
mk 254bea47
extra=$(for o in $five; do printf '"%s", ' "$o"; done)
sed -i "s/^pub const NON_OPERATOR_OPS: &\[&str\] = &\[\$/&\n    $extra/" "$tmp/t/src/actor.rs"
out=$(HOME="$tmp" NOCARGO_MIN_LITERALS=1 bash "$chk" "$tmp/t" 2>&1); rc=$?
case "$out" in *"NOCARGO journal-ops green literals="*) g=1;; *) g=0;; esac
if [ "$rc" = 0 ] && [ "$g" = 1 ]; then ok "(c) green with the five classified"; else bad "(c) green" "rc=$rc $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
