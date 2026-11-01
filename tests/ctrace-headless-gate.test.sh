#!/usr/bin/env bash
# The ctrace SessionStart/SessionEnd hooks do nothing in headless sessions (10-22 4:00 PM: a seat-tick@ctl `claude -p` turn started a root-owned
# `sudo bpftrace` inside the unit's cgroup; user-systemd could not kill it and the SessionEnd hook was cancelled -> unit failed).
# Never runs the real ctrace: the positive cases exit at the gate (asserted from a bash -x trace), the negative case sources the gate function only.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)/.claude/scripts"
START="$D/ctrace-session-start.sh"; END="$D/ctrace-session-end.sh"
fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
trace_clean() {   # $1 = trace file: the gate exited before anything touched ctrace
  ! grep -qE 'ctrace( |$)|ctrace-orphan-reap|scribe|mkdir|docket|/proc/self/cgroup' "$1" && grep -q 'ctrace_headless' "$1"
}
for h in "$START" "$END"; do
  n="$(basename "$h")"; T="$(mktemp)"
  for s in ctl rb r7; do
    env -u CTRACE_SKIP_ANCESTORS WM_SEAT=$s bash -x "$h" </dev/null >"$T.out" 2>"$T"; rc=$?
    [ "$rc" = 0 ] && [ ! -s "$T.out" ] && trace_clean "$T"; chk "$n: WM_SEAT=$s -> rc 0, silent, exits at the gate" $?
  done
  env -u WM_SEAT -u CTRACE_SKIP_ANCESTORS bash -c "exec -a 'claude -p x' bash -c 'bash -x \"$h\" </dev/null; true'" >"$T.out" 2>"$T"
  [ ! -s "$T.out" ] && trace_clean "$T"; chk "$n: a ' -p ' ancestor (headless claude) -> exits at the gate" $?
  env -u WM_SEAT -u CTRACE_SKIP_ANCESTORS bash -c "exec -a 'claude --print x' bash -c 'bash -x \"$h\" </dev/null; true'" >"$T.out" 2>"$T"
  [ ! -s "$T.out" ] && trace_clean "$T"; chk "$n: a '--print' ancestor -> exits at the gate" $?
  rm -f "$T" "$T.out"
done
diff <(sed -n '/^ctrace_headless() {/,/^}/p' "$START") <(sed -n '/^ctrace_headless() {/,/^}/p' "$END") >/dev/null && [ -n "$(sed -n '/^ctrace_headless() {/,/^}/p' "$START")" ]; chk "both hooks carry the identical gate function" $?
# negative: an interactive session (no seat, no print ancestor) is NOT headless
eval "$(sed -n '/^ctrace_headless() {/,/^}/p' "$START")"
( unset WM_SEAT; CTRACE_SKIP_ANCESTORS=1; ctrace_headless ); [ $? = 1 ]; chk "interactive (no WM_SEAT, no print ancestor): not headless, hook proceeds" $?
( WM_SEAT=other CTRACE_SKIP_ANCESTORS=1; ctrace_headless ); [ $? = 1 ]; chk "WM_SEAT=other: not headless" $?
( WM_SEAT=ctl; ctrace_headless ); [ $? = 0 ]; chk "WM_SEAT=ctl: headless" $?
# the gate sits before every side effect, in both hooks
for h in "$START" "$END"; do
  g="$(grep -n '^ctrace_headless && exit 0$' "$h" | cut -d: -f1)"; c="$(grep -n '^ctrace=' "$h" | cut -d: -f1)"
  [ -n "$g" ] && [ -n "$c" ] && [ "$g" -lt "$c" ]; chk "$(basename "$h"): the gate precedes ctrace=... (line $g < $c)" $?
done
# wiring
python3 -I - "$(dirname "$0")/../.claude/settings.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d['hooks']
def cmds(ev): return [x['command'] for g in h.get(ev,[]) for x in g['hooks']]
assert any(c.endswith('ctrace-session-start.sh') for c in cmds('SessionStart')), 'start hook not wired'
assert any(c.endswith('ctrace-session-end.sh') for c in cmds('SessionEnd')), 'end hook not wired'
PY
chk "settings.json still wires both ctrace hooks" $?
[ $fail = 0 ] && echo "ALL PASS ctrace-headless-gate" || echo "FAIL ctrace-headless-gate"
exit $fail
