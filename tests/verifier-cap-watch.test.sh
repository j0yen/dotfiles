#!/usr/bin/env bash
# tests/verifier-cap-watch.test.sh: verifier-cap-watch.sh --selftest under a throwaway HOME (fake systemctl + bell, no unit, no seat), the unit pair carries PREMISE + EXPIRES
# and a 2-minute timer, and aide-verifier.sh holds the fleet contract (fixed lock path, SLOT_CEIL=4, PEAK_MB=1024, selftest-only overrides). Run: bash tests/verifier-cap-watch.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
w="$here/.local/bin/verifier-cap-watch.sh"; v="$here/.local/bin/aide-verifier.sh"; U="$here/.config/systemd/user"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/verifier-cap-watch-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
bash -n "$w" && pass "bash -n verifier-cap-watch.sh" || bad "bash -n verifier-cap-watch.sh"
out=$(HOME="$th" bash "$w" --selftest 2>&1); rc=$?; last=$(printf '%s\n' "$out" | tail -n1)
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 19 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"
else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
grep -q '^# PREMISE: ' "$w" && grep -q '^# EXPIRES: ' "$w" && pass "script carries PREMISE + EXPIRES" || bad "script PREMISE/EXPIRES missing"
grep -q '^Environment="VERIFIER_CAP_WATCH_PREMISE=' "$U/verifier-cap-watch.service" && grep -q '^Environment=VERIFIER_CAP_WATCH_EXPIRES=20' "$U/verifier-cap-watch.service" && pass "service carries PREMISE + EXPIRES Environment= lines" || bad "service PREMISE/EXPIRES missing"
grep -q '^OnUnitActiveSec=2min$' "$U/verifier-cap-watch.timer" && pass "timer fires every 2 min" || bad "timer interval"
grep -q '^ConditionHost=carbon$' "$U/verifier-cap-watch.service" && pass "service runs on carbon only" || bad "ConditionHost"
grep -qF 'LOCK="$HOME/.local/state/verifier-cap/launch.lock"' "$v" && grep -q '^SLOT_CEIL=4$' "$v" && grep -q '^PEAK_MB=1024$' "$v" && pass "aide-verifier.sh: fixed lock path + SLOT_CEIL=4 + PEAK_MB=1024 hard-coded" || bad "aide-verifier.sh fleet contract missing"
grep -qF 'if [ "${AIDE_VERIFIER_SELFTEST:-}" = 1 ]; then' "$v" && pass "aide-verifier.sh: overrides gated on AIDE_VERIFIER_SELFTEST=1" || bad "selftest gate missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
