#!/usr/bin/env bash
# tests/quota-level.test.sh -- quota-level.sh (read-only governor: quota.level L0..L3 file + alarm on change). Run: bash tests/quota-level.test.sh
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
s="$root/.local/bin/quota-level.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
bash -n "$s" && ok "bash -n" || bad "bash -n"
[ -x "$s" ] && ok "executable" || bad "executable"
if out="$(env -i PATH="$PATH" HOME="$(mktemp -d)" bash "$s" --selftest 2>&1)"; then rc=0; else rc=$?; fi
if [ "$rc" = 0 ] && grep -q '^SELFTEST PASS' <<<"$out" && ! grep -q '^FAIL' <<<"$out"; then ok "selftest ($(grep -c '^PASS' <<<"$out") cases)"; else bad "selftest"; echo "$out" | grep -E '^(FAIL|SELFTEST)' | head; fi
if grep -nE 'max_runs|kill|systemctl|wm-build' "$s" | grep -v '^[0-9]*:#' | grep -q .; then bad "governor must not touch caps, runs or units"; else ok "no throttle verbs in code"; fi
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
