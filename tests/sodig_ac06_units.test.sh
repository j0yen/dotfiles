#!/usr/bin/env bash
# PRD dotfiles-sibling-overlap-digest AC6: the timer/service pass
# `systemd-analyze --user verify`; OnCalendar=hourly; TimeoutStartSec=60.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/sodig_test_helpers.sh"
d="$ROOT/.config/systemd/user"
svc="$d/operator-overlap-digest.service"; tmr="$d/operator-overlap-digest.timer"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# verify needs a user runtime dir; a scratch one keeps it hermetic on hosts without a login session.
mkdir -m 700 "$work/run"
cp "$svc" "$tmr" "$work/"
# verify needs ExecStart to exist: point %h at a scratch home holding the script.
mkdir -p "$work/home/.local/bin"; cp "$SCRIPT" "$work/home/.local/bin/"
sed -i "s#%h#$work/home#g" "$work/operator-overlap-digest.service"
out=$(HOME="$work/home" XDG_RUNTIME_DIR="$work/run" systemd-analyze --user verify "$work/operator-overlap-digest.service" "$work/operator-overlap-digest.timer" 2>&1); rc=$?
assert_eq "$rc" "0" "systemd-analyze verify exits 0"
assert_eq "$(grep -c "operator-overlap-digest" <<<"$out")" "0" "no diagnostics about our units"
assert_contains "$(cat "$tmr")" "OnCalendar=hourly" "timer is hourly"
assert_contains "$(cat "$tmr")" "RandomizedDelaySec=120" "timer jitter 120 s"
assert_contains "$(cat "$svc")" "TimeoutStartSec=60" "service timeout 60 s"
assert_contains "$(cat "$svc")" "overlap-digest.sh" "service runs the script"
exit $fail
