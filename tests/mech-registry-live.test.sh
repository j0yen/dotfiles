#!/usr/bin/env bash
# mech-registry-live: the installed-artifact probe against a temp HOME: registered hook, installed script,
# active timer = LIVE; absent path, unregistered hook, PR-only pointer, inactive timer = NOT-LIVE. No ssh, no real systemctl.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/../.local/bin/mech-registry.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=$((fail+1)); fi; }
H="$T/home"; mkdir -p "$H/.claude/hooks" "$H/.local/bin" "$H/.config/systemd/user" "$T/bin" "$T/wiki/answers" "$T/wiki/decisions"
: >"$H/.claude/hooks/reg-hook.sh"; : >"$H/.claude/hooks/unreg-hook.sh"; : >"$H/.local/bin/inst-script.sh"
: >"$H/.config/systemd/user/up.timer"; : >"$H/.config/systemd/user/down.timer"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"~/.claude/hooks/reg-hook.sh"}]}]}}' >"$H/.claude/settings.json"
# fake systemctl: only up.timer is active
printf '#!/usr/bin/env bash\nfor a; do [ "$a" = up.timer ] && exit 0; done; exit 3\n' >"$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
# PROBE_CMD stub: runs the probe locally with the fake systemctl first on PATH
printf '#!/usr/bin/env bash\nPATH="%s/bin:$PATH" exec bash -c "$2"\n' "$T" >"$T/probe.sh"; chmod +x "$T/probe.sh"
cat >"$T/extra.md" <<'X'
- hook registered — ⚙ ~/.claude/hooks/reg-hook.sh — owner t — state SPEC
- hook unregistered — ⚙ ~/.claude/hooks/unreg-hook.sh — owner t — state SPEC
- script installed with a test token — ⚙ .local/bin/inst-script.sh + tests/inst-script.test.sh — owner t — state SPEC
- timer active — ⚙ ~/.local/bin/inst-script.sh + up.timer — owner t — state SPEC
- timer inactive — ⚙ down.timer — owner t — state SPEC
- path absent — ⚙ .local/bin/nope.sh — owner t — state SPEC
- pr only — ⚙ dotfiles PR #999 merged — owner t — state SPEC
X
HOME="$H" WIKI="$T/wiki" CLAUDE_MD="$T/none" MECH_EXTRA="$T/extra.md" OUT="$T/o.json" PROBE_CMD="$T/probe.sh" MECH_NOW=2026-11-02 python3 -I "$bin" >"$T/run.out" 2>&1; chk "run rc 0" $?
r() { python3 -I -c "import json;d=json.load(open('$T/o.json'));m=[x for x in d['mechanisms'] if x['line']==$1][0];print(m['state_probed'],m['reason'])"; }
[ "$(r 1)" = "LIVE " ]; chk "registered hook LIVE" $?
[ "$(r 2)" = "NOT-LIVE probe-failed" ]; chk "unregistered hook NOT-LIVE" $?
[ "$(r 3)" = "LIVE " ]; chk "installed script LIVE (tests/ token ignored)" $?
[ "$(r 4)" = "LIVE " ]; chk "script + active timer LIVE" $?
[ "$(r 5)" = "NOT-LIVE probe-failed" ]; chk "inactive timer NOT-LIVE" $?
[ "$(r 6)" = "NOT-LIVE probe-failed" ]; chk "absent path NOT-LIVE" $?
[ "$(r 7)" = "NOT-LIVE pr-only" ]; chk "PR-only pointer NOT-LIVE" $?
echo "COUNTS: ran=$n pass=$((n-fail)) fail=$fail"
exit $((fail>0))
