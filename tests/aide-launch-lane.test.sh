#!/usr/bin/env bash
# ctl-launch.sh --lane (aide-lanes step 3; the launcher is ctl-launch.sh since 2026-11-06, aide-launch.sh = shim, hermes-handover 2.1): main default, 65 without the lane-branch marker, ROOM check (75) for non-main only, 64 bad name.
# Throwaway HOME, stub claude binary (prints WM_SEAT / WM_AIDE_LANE by name and the args), never a real claude.
set -u
L="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/ctl-launch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
mkdir -p "$T/.config/environment.d" "$T/.cache/fleet-dash" "$T/.config/wm-decide"
printf '%s\n' '{"ctl":{"model":"claude-sonnet-5-5","effort":"medium"}}' >"$T/.config/wm-decide/seat-model-hold.json"   # ctl-launch.sh validates the approved model policy from the HOME it runs under
echo 'CLAUDE_CODE_OAUTH_TOKEN=test-not-a-token' >"$T/.config/environment.d/90-claude-oauth.conf"
cat >"$T/stub" <<'S'
#!/usr/bin/env bash
echo "STUB WM_SEAT=${WM_SEAT:-} WM_AIDE_LANE=${WM_AIDE_LANE:-} ARGS=$*" >>"$STUBLOG"
S
chmod +x "$T/stub"
printf 'MemAvailable:   12000000 kB\n' >"$T/mem-big"; printf 'MemAvailable:    2000000 kB\n' >"$T/mem-small"
printf '# WM_AIDE_LANE\n' >"$T/hook-yes"; printf '# nothing\n' >"$T/hook-no"
go() { # <meminfo> <hook> args... ; extra env via E=
  local mem="$1" hook="$2"; shift 2; : >"$T/stublog"
  env HOME="$T" STUBLOG="$T/stublog" AIDE_CLAUDE_BIN="$T/stub" AIDE_LANE_MEMINFO="$mem" AIDE_INBOX_HOOK="$hook" $E bash "$L" "$@" >"$T/out" 2>"$T/err"; rc=$?
}
E=; go "$T/mem-small" "$T/hook-no"
[ $rc = 0 ] && grep -q 'WM_SEAT=ctl WM_AIDE_LANE=main' "$T/stublog" && ! grep -q disallowedTools "$T/stublog"; [ $? = 0 ] && ok "no flag: WM_AIDE_LANE=main, no --disallowedTools, no room check even at 2000000 kB, no marker needed" || bad "no flag path"
grep -q -- '--dangerously-skip-permissions' "$T/stublog" && ok "main args keep --dangerously-skip-permissions" || bad "main args"
go "$T/mem-big" "$T/hook-no" --lane build
[ $rc = 65 ] && [ ! -s "$T/stublog" ] && grep -q 'needs the lane branch deployed' "$T/err" && ok "--lane build without marker: exit 65, stub never called" || bad "marker refusal rc=$rc"
go "$T/mem-big" "$T/hook-yes" --lane build
[ $rc = 0 ] && grep -q 'WM_AIDE_LANE=build' "$T/stublog" && grep -q -- '--disallowedTools ScheduleWakeup' "$T/stublog" && ok "--lane build with marker + room: WM_AIDE_LANE=build, ScheduleWakeup disallowed" || bad "lane launch rc=$rc"
go "$T/mem-small" "$T/hook-yes" --lane build
[ $rc = 75 ] && [ ! -s "$T/stublog" ] && grep -q 'no room for lane build: MemAvailable 1953 MB - peak 2048 MB < 3072 MB floor' "$T/err" && ok "2000000 kB: exit 75 naming the three numbers, stub never called" || bad "room refusal rc=$rc: $(cat "$T/err")"
E="AIDE_LANE_SKIP_ROOM=1"; go "$T/mem-small" "$T/hook-yes" --lane build
[ $rc = 0 ] && grep -q 'WM_AIDE_LANE=build' "$T/stublog" && ok "AIDE_LANE_SKIP_ROOM=1: launched at 2000000 kB" || bad "skip room rc=$rc"
E="AIDE_LANE_PEAK_MB=100"; go "$T/mem-small" "$T/hook-yes" --lane build
[ $rc = 75 ] && grep -q 'MemAvailable 1953 MB - peak 100 MB' "$T/err" && ok "AIDE_LANE_PEAK_MB override is honoured (1953 - 100 < 3072)" || bad "peak override rc=$rc"
E=; go "$T/mem-big" "$T/hook-yes" --lane 'bad name'
[ $rc = 64 ] && [ ! -s "$T/stublog" ] && ok "--lane 'bad name': exit 64" || bad "bad name rc=$rc"
go "$T/mem-big" "$T/hook-yes" --lane build --model claude-sonnet-5-5
grep -q -- '--disallowedTools ScheduleWakeup --model' "$T/stublog" && ok "caller claude args follow the lane flags" || bad "arg order"
go "$T/mem-big" "$T/hook-yes" --lane build --resume abc
grep -q -- '--resume abc' "$T/stublog" && ok "--resume passes through" || bad "resume passthrough"
# compat shim: aide-launch.sh execs ctl-launch.sh (same stub, same WM_SEAT=ctl) and carries no launcher logic of its own
SH="$(dirname "$L")/aide-launch.sh"
: >"$T/stublog"; env HOME="$T" STUBLOG="$T/stublog" AIDE_CLAUDE_BIN="$T/stub" bash "$SH" --model claude-sonnet-5-5 >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q 'WM_SEAT=ctl WM_AIDE_LANE=main' "$T/stublog" && ok "aide-launch.sh shim reaches the stub with WM_SEAT=ctl" || bad "shim launch rc=$rc"
grep -q 'ctl-launch.sh' "$SH" && [ "$(grep -vc '^#' "$SH")" -le 3 ] && ok "aide-launch.sh is a shim that names ctl-launch.sh" || bad "aide-launch.sh not a shim"
grep -q '^export WM_SEAT=ctl$' "$L" && ! grep -q '^export WM_SEAT=aide' "$L" && ok "ctl-launch.sh exports WM_SEAT=ctl" || bad "ctl-launch.sh WM_SEAT assignment"
# AIDE CARD: a lane prints `lane: <name>`; main's card has no lane line (byte-for-byte)
H="$(cd "$(dirname "$L")/../.." && pwd)/.claude/hooks/seat-context-start.sh"
card() { env -u TMUX HOME="$T" WM_SEAT=aide WM_AIDE_LANE="$1" bash "$H" </dev/null 2>/dev/null | head -n3; }
card build | grep -qx 'lane: build' && ok "AIDE CARD shows 'lane: build'" || bad "card lane line"
card main | grep -q '^lane:' && bad "main card gained a lane line" || ok "main card unchanged (no lane line)"
# WM_SEAT=ctl is shared: ctl-launch.sh exports it WITH WM_AIDE_LANE (card); the seat-tick@ctl unit has no lane (compact/resume payload, tests/seat-compact-payload.test.sh)
cardc() { env -u TMUX -u WM_AIDE_LANE HOME="$T" WM_SEAT="$1" ${2:+WM_AIDE_LANE="$2"} bash "$H" </dev/null 2>/dev/null | head -n3; }
cardc ctl main | grep -q '^=== CTL CARD' && ok "WM_SEAT=ctl + WM_AIDE_LANE prints CTL CARD" || bad "ctl card header"
cardc ctl | grep -q '^=== CTL CARD' && bad "WM_SEAT=ctl without WM_AIDE_LANE printed the card (seat-tick@ctl unit path)" || ok "WM_SEAT=ctl without a lane skips the card"
cardc aide | grep -q '^=== AIDE CARD' && ok "WM_SEAT=aide still prints AIDE CARD" || bad "aide card header"
exit $fail
