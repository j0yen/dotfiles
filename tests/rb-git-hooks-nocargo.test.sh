#!/usr/bin/env bash
# rb-git-hooks (pre-commit + pre-push) run wmb-nocargo-checks.sh for a --no-cargo rb coder (ctl 8220): synthetic repos under mktemp.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hooks="$here/.local/share/rb-git-hooks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export NOCARGO_MIN_LITERALS=0 GIT_CONFIG_NOSYSTEM=1 HOME="$tmp/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1 ${2:-}"; }
g() { git -c user.email=t@t -c user.name=t -c core.hooksPath="$hooks" "$@"; }

mk() {
    mkdir -p "$1/src"; git -C "$1" init -q -b main
    cat > "$1/src/actor.rs" <<'RS'
pub const OPERATOR_OPS: &[&str] = &[
    "run-paused",
];
pub const NON_OPERATOR_OPS: &[&str] = &[
    "tick",
];
RS
    printf '%s\n' 'fn a() { s.journal("runs", "run-paused", &j); }' > "$1/src/a.rs"
    printf '%s\n' 'fn b() { s.journal("daemon", "tick", &j); }' > "$1/src/b.rs"
}

r="$tmp/wmb"; mk "$r"; g -C "$r" add -A
out=$(g -C "$r" commit -q -m clean 2>&1) && ok "clean wm-build tree commits" || bad "clean wm-build tree commits" "$out"

printf '%s\n' 'fn c() { s.journal("runs", "mystery-op", &j); }' > "$r/src/c.rs"; g -C "$r" add -A
out=$(g -C "$r" commit -q -m red 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'pre-commit: REFUSED' && printf '%s' "$out" | grep -q 'UNCLASSIFIED mystery-op'; then ok "unclassified op refuses the commit"
else bad "unclassified op refuses the commit" "rc=$rc $out"; fi

# staged tree is what counts: a fix left unstaged still refuses
sed -i 's/"tick",/"tick",\n    "mystery-op",/' "$r/src/actor.rs"
out=$(g -C "$r" commit -q -m red2 2>&1) && bad "unstaged fix still refuses" "$out" || ok "unstaged fix still refuses"
g -C "$r" add -A
out=$(g -C "$r" commit -q -m fixed 2>&1) && ok "staged fix commits" || bad "staged fix commits" "$out"

# pre-push: a red commit made with --no-verify is refused at push
git init -q --bare "$tmp/remote.git"; g -C "$r" remote add origin "$tmp/remote.git"
out=$(g -C "$r" push -q origin main 2>&1) && ok "green tip pushes" || bad "green tip pushes" "$out"
printf '%s\n' 'fn d() { s.journal("runs", "other-op", &j); }' > "$r/src/d.rs"; g -C "$r" add -A
g -C "$r" commit -q --no-verify -m sneak >/dev/null 2>&1
out=$(g -C "$r" push -q origin main 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'pre-push: REFUSED'; then ok "red tip refuses the push"; else bad "red tip refuses the push" "rc=$rc $out"; fi

# any other repo passes untouched
o="$tmp/other"; mkdir -p "$o"; git -C "$o" init -q -b main; echo x > "$o/f"; g -C "$o" add -A
out=$(g -C "$o" commit -q -m x 2>&1) && ok "non-wm-build repo commits" || bad "non-wm-build repo commits" "$out"

# rb-run-coder wires the hooks only for --no-cargo
rc_sh="$here/.local/bin/rb-run-coder.sh"
if grep -q 'rb-git-hooks' "$rc_sh" && grep -qE 'nocargo" = 1 \].*GIT_CONFIG_KEY_0=core.hooksPath' "$rc_sh"; then ok "rb-run-coder wires core.hooksPath for --no-cargo"
else bad "rb-run-coder wires core.hooksPath for --no-cargo"; fi

echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
