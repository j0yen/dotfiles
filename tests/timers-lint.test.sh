#!/usr/bin/env bash
# timers-lint (hermes-handover 2.5): the committed tree lints clean; dropping a launching unit's hold drop-in is named and fails;
# an edited timers.tsv fails the no-drift check.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
L="$here/.local/bin/timers-lint.sh"; G="$here/.local/bin/timers-gen.py"

out="$(TIMERS_ROOT="$here" bash "$L" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "findings: 0" ]; then ok "committed tree lints clean (findings: 0)"; else bad "committed tree (rc=$rc)"; printf '%s\n' "$out" | tail -5; fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.config" "$tmp/.local"
cp -a "$here/.config/systemd" "$here/.config/fleet" "$tmp/.config/"; cp -a "$here/.local/bin" "$tmp/.local/"

rm -rf "$tmp/.config/systemd/user/fleet-merge.timer.d"
out="$(TIMERS_ROOT="$tmp" bash "$L" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'launching unit fleet-merge.timer is not hold-gated' <<<"$out" && [ "$(printf '%s\n' "$out" | tail -1)" != "findings: 0" ]; then ok "removed drop-in makes lint exit 1 and name fleet-merge.timer"; else bad "missing drop-in not caught (rc=$rc)"; printf '%s\n' "$out" | tail -5; fi

cp -a "$here/.config/fleet/timers.tsv" "$tmp/.config/fleet/timers.tsv"; cp -a "$here/.config/systemd/user/fleet-merge.timer.d" "$tmp/.config/systemd/user/"
TIMERS_ROOT="$tmp" python3 -I "$G" --check >/dev/null 2>&1 && ok "--check passes on the unedited copy" || bad "--check on unedited copy"
sed -i 's/^fleet-merge.service\tlaunching/fleet-merge.service\tmechanical/' "$tmp/.config/fleet/timers.tsv"
TIMERS_ROOT="$tmp" python3 -I "$G" --check >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "--check exits 1 after the TSV is edited" || bad "--check after edit (rc=$rc)"
exit $fail
