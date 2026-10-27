#!/usr/bin/env bash
# tests/seat-compact-payload.test.sh -- M9 stage 1, mechanism 1 (decisions/2026-10-27-m9-seat-floor-cut-wwhtbt.md leaf 2 + amendments 3/4):
# with SEAT_FLOOR_STAGE>=1, seat-context-start.sh on SessionStart `compact` AND `resume` prints for ctl|rb|r7 only § Stage + goal-lint + two pointer lines, <= 4096 B, never the playbook body,
# opens NO ssh (no `ssh`, no timers-start-trigger-live.sh --hosts), completes < 2 s; `resume` prints <= 300 B when § Stage is unchanged since the seat's last tick.
# Stage OFF (default) = today's full payload, byte for byte. The hook timeout in settings.json is not lowered. Throwaway HOME, stubs on PATH; no network, no ssh.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; HOOK="$root/.claude/hooks/seat-context-start.sh"; FX="$root/tests/fixtures/seat-floor"
fail=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/scp.XXXXXX")"; trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/.local/bin" "$H/.claude/state" "$H/Notes/wiki/playbooks" "$H/.cache/fleet-dash" "$H/.claude/projects/-home-jsy/memory" "$T/bin"
cp "$root/.local/bin/seat-lean.sh" "$H/.local/bin/"; cp "$root/.claude/state/seats.tsv" "$H/.claude/state/"
stage_body() { printf '## Stage\n'; for i in $(seq 1 "$1"); do printf 'STAGE-LINE-%s the fluid stage, goals and build order padded to a realistic width for one line of goal.md here\n' "$i"; done; printf '## Other\nOTHER-SECTION\n'; }
stage_body 22 >"$H/Notes/wiki/goal.md"   # ~2.4 KB stage like the real one
{ echo '# playbook'; for i in $(seq 1 120); do echo "PLAYBOOK-BODY-LINE-$i admission operator timer orch vault auth promote lands lanes closes unblock"; done; } >"$H/Notes/wiki/playbooks/fleet-operations.md"
printf '#!/usr/bin/env bash\necho "goal-lint: CLEARWATER ok"\n' >"$H/.local/bin/goal-lint.sh"; chmod +x "$H/.local/bin/goal-lint.sh"
printf '#!/bin/sh\necho "SSH-CALLED $*" >>"%s/ssh.log"; exit 1\n' "$T" >"$T/bin/ssh"; chmod +x "$T/bin/ssh"
printf '#!/bin/sh\necho "HELPER-CALLED $*" >>"%s/ssh.log"; echo "FAIL redbaron x.timer no start trigger"\n' "$T" >"$H/.local/bin/timers-start-trigger-live.sh"; chmod +x "$H/.local/bin/timers-start-trigger-live.sh"
touch "$H/.claude/projects/-home-jsy/memory/handoff-controller-20261015.md" "$H/.claude/projects/-home-jsy/memory/handoff-rb-20261013.md" "$H/.claude/projects/-home-jsy/memory/handoff-r7-20261013.md"
run() {  # <seat> <stdin-file|-> [extra env...]
  local seat="$1" in="$2"; shift 2
  if [ "$in" = - ]; then in=/dev/null; fi
  env -i PATH="$T/bin:$PATH" HOME="$H" TERM=dumb WM_SEAT="$seat" SEAT_LEAN=1 TIMERS_CHECK_TIMEOUT=5 "$@" bash "$HOOK" <"$in" 2>/dev/null
}
resume_json() { printf '{"hook_event_name":"SessionStart","source":"resume"}\n' >"$T/resume.json"; echo "$T/resume.json"; }
RJ="$(resume_json)"
# -- stage OFF: full payload (playbook body present), compact stdin ignored
out="$(run rb "$FX/sessionstart-rb-compact.json")"
printf '%s' "$out" | grep -q 'PLAYBOOK-BODY-LINE-120' && printf '%s' "$out" | grep -q 'STAGE-LINE-1 '; chk "stage OFF (default): compact still prints the full payload incl. the playbook body" $?
# -- stage ON, compact, one case per seat
for seat in ctl rb r7; do
  rm -f "$T/ssh.log" "$H/.cache/claude-seat/$seat.stage-hash"
  s=$(date +%s%N); out="$(run "$seat" "$FX/sessionstart-$seat-compact.json" SEAT_FLOOR_STAGE=1)"; e=$(date +%s%N)
  b=$(printf '%s' "$out" | wc -c)
  [ "$b" -le 4096 ] && [ "$b" -gt 500 ]; chk "$seat compact: payload $b B <= 4096" $?
  printf '%s' "$out" | grep -q 'STAGE-LINE-1 ' && printf '%s' "$out" | grep -q 'STAGE-LINE-22 ' && ! printf '%s' "$out" | grep -q 'OTHER-SECTION'; chk "$seat compact: § Stage present and only § Stage" $?
  printf '%s' "$out" | grep -q '^goal-lint: CLEARWATER ok'; chk "$seat compact: goal-lint line present" $?
  ! printf '%s' "$out" | grep -q 'PLAYBOOK-BODY-LINE'; chk "$seat compact: no playbook body" $?
  printf '%s' "$out" | grep -q "^playbook: $H/Notes/wiki/playbooks/fleet-operations.md" && printf '%s' "$out" | grep -q "^handoff: .*handoff-.*-2026101[35].md"; chk "$seat compact: playbook + handoff pointer lines" $?
  [ ! -e "$T/ssh.log" ]; chk "$seat compact: no ssh, helper not run" $?
  [ $(( (e - s) / 1000000 )) -lt 2000 ]; chk "$seat compact: < 2 s ($(( (e - s) / 1000000 )) ms)" $?
done
# -- resume: first = payload, second (unchanged) = <= 300 B, changed § Stage = payload again
rm -f "$H/.cache/claude-seat/rb.stage-hash"
o1="$(run rb "$RJ" SEAT_FLOOR_STAGE=1)"; o2="$(run rb "$RJ" SEAT_FLOOR_STAGE=1)"
[ "$(printf '%s' "$o1" | wc -c)" -le 4096 ] && printf '%s' "$o1" | grep -q 'STAGE-LINE-1 '; chk "rb resume (no prior hash): payload <= 4096 with § Stage" $?
[ "$(printf '%s' "$o2" | wc -c)" -le 300 ] && printf '%s' "$o2" | grep -q 'unchanged' && printf '%s' "$o2" | grep -qE 'hash [0-9a-f]{12}'; chk "rb resume (unchanged): $(printf '%s' "$o2" | wc -c) B <= 300 with the hash line" $?
stage_body 21 >"$H/Notes/wiki/goal.md"; o3="$(run rb "$RJ" SEAT_FLOOR_STAGE=1)"
printf '%s' "$o3" | grep -q 'STAGE-LINE-21 ' && ! printf '%s' "$o3" | grep -q 'STAGE-LINE-22 '; chk "rb resume: a changed § Stage prints the payload again" $?
o4="$(run r7 "$RJ" SEAT_FLOOR_STAGE=1)"; o5="$(run r7 "$RJ" SEAT_FLOOR_STAGE=1)"
[ "$(printf '%s' "$o5" | wc -c)" -le 300 ]; chk "r7 resume: the hash state is per seat" $?
o6="$(run rb "$FX/sessionstart-rb-compact.json" SEAT_FLOOR_STAGE=1)"; printf '%s' "$o6" | grep -q 'STAGE-LINE-1 '; chk "rb compact always prints the payload even when the hash is unchanged" $?
# -- startup (and no stdin) keep the full payload with the stage on
out="$(run rb - SEAT_FLOOR_STAGE=1)"; printf '%s' "$out" | grep -q 'PLAYBOOK-BODY-LINE-120'; chk "stage ON, no source (startup): full payload unchanged" $?
# -- aide + plain session unaffected
out="$(run aide "$FX/sessionstart-rb-compact.json" SEAT_FLOOR_STAGE=1)"; printf '%s' "$out" | grep -q '=== AIDE CARD' && ! printf '%s' "$out" | grep -q 'STAGE-LINE'; chk "aide: AIDE CARD path unchanged" $?
out="$(env -i PATH="$PATH" HOME="$H" TERM=dumb SEAT_FLOOR_STAGE=1 bash "$HOOK" <"$FX/sessionstart-rb-compact.json" 2>/dev/null)"; [ -z "$out" ]; chk "plain session: silent" $?
# -- an oversize § Stage is capped at 4096 B
stage_body 80 >"$H/Notes/wiki/goal.md"; rm -f "$H/.cache/claude-seat/rb.stage-hash"
out="$(run rb "$FX/sessionstart-rb-compact.json" SEAT_FLOOR_STAGE=1)"; [ "$(printf '%s' "$out" | wc -c)" -le 4096 ]; chk "oversize § Stage capped at 4096 B" $?
stage_body 22 >"$H/Notes/wiki/goal.md"
# -- timers: fresh status.json FAIL lines printed (no ssh), stale one ignored
echo '{"timers_no_start_trigger":[{"host":"redbaron","unit":"x.timer","reason":"no start trigger"},"FAIL ryzen7 y.timer no start trigger"]}' >"$H/.cache/fleet-dash/status.json"
rm -f "$T/ssh.log"; out="$(run rb "$FX/sessionstart-rb-compact.json" SEAT_FLOOR_STAGE=1)"
printf '%s' "$out" | grep -q '^FAIL redbaron x.timer no start trigger' && printf '%s' "$out" | grep -q '^FAIL ryzen7 y.timer' && [ ! -e "$T/ssh.log" ]; chk "status.json timers_no_start_trigger FAIL lines printed, still no ssh" $?
touch -d '2 hours ago' "$H/.cache/fleet-dash/status.json"; out="$(run rb "$FX/sessionstart-rb-compact.json" SEAT_FLOOR_STAGE=1)"; ! printf '%s' "$out" | grep -q 'FAIL redbaron'; chk "stale status.json (> 5 min) is not read" $?
# -- flag from floor-stage.json (no env)
mkdir -p "$H/.config/claude-seat"; echo '{"stage":1}' >"$H/.config/claude-seat/floor-stage.json"
out="$(run rb "$FX/sessionstart-rb-compact.json")"; ! printf '%s' "$out" | grep -q 'PLAYBOOK-BODY-LINE'; chk "stage from floor-stage.json (no env) turns the compact payload on" $?
# -- the hook timeout is not lowered or removed
grep -A3 'seat-context-start.sh' "$root/.claude/settings.json" | grep -q '"timeout": 5'; chk "settings.json hook timeout still 5 (never lowered)" $?
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit "$fail"
