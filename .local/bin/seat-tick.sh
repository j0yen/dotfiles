#!/usr/bin/env bash
# seat-tick.sh: one operator-seat turn as a daemon run (like wm-build): `claude -p --resume <seat SID> "<prompt>"`.
# ctl-sweep.sh generalized: ONE script, one row per seat in ~/.claude/state/seats.tsv (seat role sid tick_min timeout_sec goal_pattern old_pid).
#   seat-tick.sh <seat>                  tick turn (timer seat-tick@<seat>.timer)
#       ctl : SWEEP <time> <date> tick=<n> status_age=<N|none>m approvals_new=<k>  + a "First act:" line
#       rb/r7: TICK <time> <date> seat=<seat> tick=<n> + the seat's /goal line from goal.md (after a ff-only pull) + the rules line
#   seat-tick.sh <seat> --ask "<text>"   ASK turn (Joe's / the controller's fast path, see seat-ask.sh)  prompt: ASK <time> <date> seat=<seat> [approvals_new=<k>]: <text>
#   seat-tick.sh <seat> --event          EVENT turn (seat-event.sh's wake): prompt EVENT <time> <date> seat=<seat> [approvals_new=<k>] events_new=<k>; lock wait 0:
#                                        lock held -> touch <seat>.wake and exit 0 quietly (the running turn chains one EVENT turn at its end); no new events -> exit 0, claude not run
#   seat-tick.sh <seat> --status         print <seat>-tick.json
#   seat-tick.sh <seat> --guard-check    run only the guard (exit 0 clear / 4 refused), changes nothing
#   seat-tick.sh --selftest              fake claude only, never the real one, never a real seat SID
# EVENTS (10-22): every prompt (TICK/SWEEP/EVENT/ASK) ends its first line with events_new=<k> and, when k>0, carries `EVENTS since <last prompt time>:` + the new
# <seat>-events.log lines (oldest first, max 40, then `... +N more`). events_offset (bytes) in <seat>-tick.json advances only on exit 0. At turn end (exit 0) a
# <seat>.wake file or unread events chain ONE more EVENT turn in the same process (exec; env SEAT_TICK_CHAINED=1 forbids a second chain, chained=1 in the state).
# State keys: seat last_tick last_sent ticks_skipped last_skip_reason sends_total last_exit last_duration_s last_prompt_kind status_file approvals_seen guard_since events_offset last_prompt events_new chained.
# Order: flock (serializes ticks and asks per seat) -> guard (exit 4 if the interactive seat still holds the session; never kills
# anything) -> compose prompt -> model row (exit 3) -> [ctl tick only: fleet-status-write.sh --open, after every precondition] -> claude -p under `timeout` (95 % of timeout_sec).
# LOCK: a tick that cannot lock within 60 s exits 5 and counts a skip (3 in a row = ALARM line); an ASK waits up to 1800 s instead.
# The goal loop (/goal stop hook) is disabled in `claude -p`, so a rb/r7 tick carries the seat's /goal line itself.
# approvals_new / status_age exist for ctl only (log is read-only here; approvals_seen in ctl-tick.json is the high-water mark).
# LEAN (10-22): seats whose ROLE is rb or r7 run the same lean overlay seat-relaunch.sh gives their interactive launch (env LEAN_ENV_VARS +
# flags LEAN_FLAGS from seat-lean.sh, flags placed before --resume). ctl stays on the default settings with the full hook set, by design;
# its only flag is --settings ~/.config/claude-seat/ctl-settings.json ({"autoCompactEnabled": true, "autoCompactWindow": "auto"}: ~/.claude/settings.local.json turns auto-compact off / sets a 500000 window for $HOME and the --settings layer beats it; rb/r7 get the same from claude-seat/settings.json).
# Env overrides: SEAT_TICK_CHAINED SEAT_TICK_T0 (chain plumbing, set by this script) FLEET_DASH_DIR SEATS_TABLE MRC_TABLE GOAL_MD APPROVALS_FILE SEAT_CLAUDE_BIN SEAT_OAUTH_ENV SEAT_LOCK_WAIT SEAT_ASK_LOCK_WAIT SEAT_UNIT_DIR
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
DASH="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}"
SEATS="${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}"
MRC="${MRC_TABLE:-$HOME/.claude/state/controller-model-required}"
GOAL_FILE="${GOAL_MD:-$HOME/Notes/wiki/goal.md}"
APPROVALS="${APPROVALS_FILE:-$HOME/.claude/state/approvals.log}"
CLAUDE_BIN="${SEAT_CLAUDE_BIN:-$HOME/.npm-global/bin/claude}"
OAUTH_ENV="${SEAT_OAUTH_ENV:-$HOME/.config/environment.d/90-claude-oauth.conf}"
LOCK_WAIT="${SEAT_LOCK_WAIT:-60}"
ASK_LOCK_WAIT="${SEAT_ASK_LOCK_WAIT:-1800}"
UNIT_DIR="${SEAT_UNIT_DIR:-$HOME/.config/systemd/user}"
CTL_SETTINGS="${SEAT_CTL_SETTINGS:-$HOME/.config/claude-seat/ctl-settings.json}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
WRITER="$HERE/fleet-status-write.sh"
. "$HERE/seat-lean.sh"   # LEAN_ENV_VARS + LEAN_FLAGS: ONE source with seat-relaunch.sh (10-22)
ALARM_AT=3
EVENT_RULE='every EVENT line gets a read and, if real, a mitigation this turn; log a DECISION row for each action'
RULES_LINE='Rules of this shape: one sweep toward the goal per tick; every DECISION is a wm-decide ledger row the same turn; wake the controller with ctl-ask.sh "<text>"; any background process you need outlives this turn only as a systemd-run --user unit with premise + expiry; '"$EVENT_RULE"'; this turn ends when you print the timestamped STATUS block.'
EV_MAX=40   # event lines shown in one prompt

usage() { echo 'usage: seat-tick.sh <seat> [--ask "<text>" | --event | --status | --guard-check]   |   seat-tick.sh --selftest' >&2; exit 64; }

# seat row from the table; sets ROLE SID TICK_MIN TIMEOUT_SEC GOAL_RE OLD_PID or returns 1
load_seat() {
  local row
  row="$(awk -F'\t' -v s="$1" '!/^[[:space:]]*(#|$)/ && $1==s {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7; exit}' "$SEATS" 2>/dev/null)"
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r ROLE SID TICK_MIN TIMEOUT_SEC GOAL_RE OLD_PID <<<"$row"
  [ -n "$SID" ] && [ -n "${OLD_PID:-}" ]
}

# guard: prints the reason and returns 1 if the interactive seat (old_pid, or any claude/node holding this SID) is alive
guard() {
  local p cl comm
  if [ "$OLD_PID" != "-" ] && [ -r "/proc/$OLD_PID/cmdline" ]; then
    cl="$(tr '\0' ' ' <"/proc/$OLD_PID/cmdline")"
    case "$cl" in *claude*) echo "pid $OLD_PID alive: ${cl:0:80}"; return 1 ;; esac
  fi
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    cl="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)" || continue
    case "$cl" in *"$SID"*) ;; *) continue ;; esac
    comm="$(cat "$p/comm" 2>/dev/null)"
    # only a process whose own command is claude (or node running claude): not a shell that merely mentions the SID
    if [ "$comm" = claude ] || [ "$comm" = node ] || [[ "$cl" =~ ^([^\ ]*/)?claude(\ |$) ]] || [[ "$cl" =~ ^([^\ ]*/)?node\ [^\ ]*claude ]]; then
      echo "pid ${p#/proc/} holds session $SID: ${cl:0:80}"; return 1
    fi
  done
  return 0
}

# ---- selftest -------------------------------------------------------------------------------------
ST_T=""; ST_PIDS=""
st_cleanup() { local p; for p in $ST_PIDS; do kill "$p" 2>/dev/null; done; [ -n "$ST_T" ] && [ -z "${SELFTEST_KEEP:-}" ] && rm -rf "$ST_T"; [ -n "${SELFTEST_KEEP:-}" ] && echo "kept $ST_T"; }
selftest() {
  local T fail=0 rc ts_re='[0-9]{1,2}:[0-9]{2} (AM|PM) [A-Za-z0-9+-]+ [0-9]{4}-[0-9]{2}-[0-9]{2}'
  T="$(mktemp -d)"; ST_T="$T"; trap st_cleanup EXIT
  unset SEAT_LEAN CLAUDE_LEAN_START   # a selftest run from inside a lean seat must not make ctl look lean
  local CA="--settings $HOME/.config/claude-seat/ctl-settings.json"
  local LA="--settings $HOME/.config/claude-seat/settings.json --mcp-config $HOME/.config/claude-seat/mcp.json --strict-mcp-config"
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  local CS=selftest-ctl-sid-0001 RS=selftest-rb-sid-0002 SS=selftest-r7-sid-0003 TS=selftest-tmo-sid-0004
  export FLEET_DASH_DIR="$T/dash" SEATS_TABLE="$T/seats.tsv" MRC_TABLE="$T/mrc" GOAL_MD="$T/notes/wiki/goal.md" APPROVALS_FILE="$T/approvals.log" \
         SEAT_CLAUDE_BIN="$T/claude" SEAT_OAUTH_ENV="$T/oauth.conf" SEAT_LOCK_WAIT=1 SEAT_ASK_LOCK_WAIT=1
  mkdir -p "$T/dash"
  printf '# test table\nctl\tcontroller\t%s\t20\t14400\t^/goal SWARM-CONTROL\t999999999\nrb\trb\t%s\t20\t14400\t^/goal CLEARWATER:\t-\nr7\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\ntmo\trb\t%s\t20\t4\t^/goal CLEARWATER:\t-\n' \
    "$CS" "$RS" "$SS" "$TS" >"$SEATS_TABLE"
  printf 'controller test-model-1\nrb test-model-rb\nr7 test-model-r7\n' >"$MRC_TABLE"
  echo 'CLAUDE_CODE_OAUTH_TOKEN=fake-not-a-token' >"$SEAT_OAUTH_ENV"
  printf '# c1\n# c2\n\nl1\nl2\nl3\n' >"$APPROVALS_FILE"
  # goal.md in a git work tree cloned from a bare temp remote, so the ff-only pull step runs for real
  local G="git -c user.name=t -c user.email=t@t.invalid"
  git init -q --bare -b main "$T/remote.git" && git clone -q "$T/remote.git" "$T/notes" 2>/dev/null && mkdir -p "$T/notes/wiki"
  cat >"$GOAL_MD" <<'GOAL'
# goal.md (selftest)
/goal FULLQUEUE old expired line that must not match
/goal CLEARWATER: first-pass yield >= 60 % v1 (rb seat line, "quoted" & $dollar `tick` chars)
/goal CLEARWATER-R7 (carbon seat, ryzen7 only) v1
/goal SWARM-CONTROL (carbon ctl seat) v1
GOAL
  ( cd "$T/notes" && $G add -A && $G commit -qm v1 && $G push -q -u origin HEAD:main ) >/dev/null 2>&1
  cat >"$SEAT_CLAUDE_BIN" <<'FAKE'
#!/bin/bash
echo "START $(date +%s.%N)"
echo "ARGV: $*"
echo "token_set=${CLAUDE_CODE_OAUTH_TOKEN:+yes} cwd=$PWD"
echo "seat_env=WM_SEAT=${WM_SEAT:-} CLAUDE_SESSION_NAME=${CLAUDE_SESSION_NAME:-}"
echo "lean_env=SEAT_LEAN=${SEAT_LEAN:-} CLAUDE_LEAN_START=${CLAUDE_LEAN_START:-}"
echo "status_line2=$(sed -n 2p "$FLEET_DASH_DIR/fleet-status.md" 2>/dev/null)"
printf '%s' "${@: -1}" >"$FLEET_DASH_DIR/prompt.${WM_SEAT:-x}.txt"
sleep "${FAKE_SLEEP:-2}"
echo "END $(date +%s.%N)"
exit "${FAKE_EXIT:-0}"
FAKE
  chmod +x "$SEAT_CLAUDE_BIN"
  j() { jq -r "$1" "$T/dash/ctl-tick.json"; }
  jseat() { jq -r "$2" "$T/dash/$1-tick.json"; }
  setpid() { awk -F'\t' -v OFS='\t' -v s="$1" -v p="$2" '$1==s && !/^#/ {$7=p} {print}' "$SEATS_TABLE" >"$SEATS_TABLE.new" && mv "$SEATS_TABLE.new" "$SEATS_TABLE"; }
  pl() { sed -n "${2}p" "$T/dash/prompt.$1.txt"; }
  local goal_rb goal_r7
  goal_rb="$(grep -m1 '^/goal CLEARWATER:' "$GOAL_MD")"; goal_r7="$(grep -m1 '^/goal CLEARWATER-R7' "$GOAL_MD")"

  # 1. ctl SWEEP #1: no status file yet, 3 approvals pending
  "$SELF" ctl >"$T/o1" 2>"$T/e1"; rc=$?
  [ "$rc" = 0 ]; chk "sweep 1: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-1 $CA --resume $CS SWEEP $ts_re tick=1 status_age=none approvals_new=3 events_new=0\$" "$T/o1"; chk "sweep 1: argv/prompt '$(grep -m1 ^ARGV "$T/o1" | cut -c1-200)'" $?
  grep -q "model test-model-1" "$T/o1"; chk "model comes from MRC_TABLE controller row" $?
  grep -q "token_set=yes cwd=$HOME\$" "$T/o1"; chk "oauth env sourced (token present, value not shown), cwd=\$HOME" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl$' "$T/o1"; chk "SWEEP: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
  grep -q '^status_line2=boundary: open$' "$T/o1"; chk "SWEEP wrote 'boundary: open' before claude ran" $?
  grep -q '^ARGV:' "$T/dash/ctl-tick-last.log"; chk "ctl-tick-last.log holds the run output" $?
  [ "$(j .sends_total)" = 1 ] && [ "$(j .last_exit)" = 0 ] && [ "$(j .last_prompt_kind)" = sweep ] && [ "$(j .ticks_skipped)" = 0 ] && [ "$(j .approvals_seen)" = 3 ] && [ "$(j .last_duration_s)" -ge 2 ] && [ "$(j .last_sent)" -gt 0 ]; chk "state: sends_total=1 last_exit=0 kind=sweep approvals_seen=3 duration=$(j .last_duration_s)s" $?
  [ "$(pl ctl 2)" = 'First act: read pending wm-decide rows and approval-check.sh --since "24 hours ago"; end by piping FLEET STATUS into fleet-status-write.sh.' ] && [ "$(wc -l <"$T/dash/prompt.ctl.txt")" = 1 ]; chk "ctl sweep 1: second prompt line = First act (no prior tick: since 24 hours ago): '$(pl ctl 2 | cut -c1-120)'" $?

  # 2. ctl SWEEP #2: status file 7 min old, 2 new approvals
  touch -d '7 minutes ago' "$T/dash/fleet-status.md"
  printf 'l4\nl5\n# comment\n' >>"$APPROVALS_FILE"
  "$SELF" ctl >"$T/o2" 2>"$T/e2"
  grep -Eq "SWEEP $ts_re tick=2 status_age=7m approvals_new=2 events_new=0\$" "$T/o2"; chk "sweep 2: status_age + approvals_new in prompt: '$(grep -o 'SWEEP.*' "$T/o2" | head -1)'" $?
  [ "$(j .sends_total)" = 2 ] && [ "$(j .approvals_seen)" = 5 ]; chk "sweep 2: sends_total=2 approvals_seen=5" $?
  grep -Eq '^First act: read pending wm-decide rows and approval-check.sh --since "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{1,2}:[0-9]{2} (AM|PM)"; end by piping FLEET STATUS into fleet-status-write.sh\.$' <(pl ctl 2); chk "sweep 2: First act names the previous tick's time: '$(pl ctl 2 | cut -c1-110)'" $?

  # 3. ctl ASK: no --open, model table re-read, ask log, sends_total unchanged
  rm -f "$T/dash/fleet-status.md"; printf 'controller test-model-2\nrb test-model-rb\nr7 test-model-r7\n' >"$MRC_TABLE"
  "$SELF" ctl --ask "what is rb doing?" >"$T/o3" 2>"$T/e3"; rc=$?
  [ "$rc" = 0 ]; chk "ask: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-2 $CA --resume $CS ASK $ts_re seat=ctl approvals_new=0 events_new=0: what is rb doing\?\$" "$T/o3"; chk "ask: prompt '$(grep -m1 ^ARGV "$T/o3" | cut -c1-200)'" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl$' "$T/o3"; chk "ASK: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
  [ ! -e "$T/dash/fleet-status.md" ]; chk "ASK did not write the boundary marker (SWEEP only)" $?
  [ -s "$T/dash/ctl-ask-last.log" ]; chk "ctl-ask-last.log written" $?
  [ "$(j .last_prompt_kind)" = ask ] && [ "$(j .sends_total)" = 2 ] && [ "$(j .last_exit)" = 0 ]; chk "ask: kind=ask, sends_total stays 2" $?

  # 4. exit code recorded
  FAKE_SLEEP=0 FAKE_EXIT=7 "$SELF" ctl >"$T/o4" 2>"$T/e4"; rc=$?
  [ "$rc" = 7 ] && [ "$(j .last_exit)" = 7 ] && [ "$(j .approvals_seen)" = 5 ]; chk "claude exit 7: script exits 7, last_exit=7, approvals_seen not advanced" $?

  # 5. lock serialization: A (sweep, 2 s) running, B (ask) must wait for A's END
  SEAT_LOCK_WAIT=30 SEAT_ASK_LOCK_WAIT=30 "$SELF" ctl >"$T/oA" 2>&1 & ST_PIDS="$ST_PIDS $!"; local pa=$!
  sleep 0.7
  SEAT_LOCK_WAIT=30 SEAT_ASK_LOCK_WAIT=30 "$SELF" ctl --ask second >"$T/oB" 2>&1 & ST_PIDS="$ST_PIDS $!"; local pb=$!
  wait "$pa" "$pb"
  local aend bstart
  aend="$(awk '/^END/{print $2}' "$T/oA")"; bstart="$(awk '/^START/{print $2}' "$T/oB")"
  awk -v e="$aend" -v s="$bstart" 'BEGIN{exit !(s+0 >= e+0 && e != "" && s != "")}'; chk "lock: second run started ($bstart) after first ended ($aend)" $?

  # 6. lock timeout: a held lock -> exit 5, ticks_skipped counts, ALARM at 3, success resets
  ( exec 8>"$T/dash/ctl.lock"; flock 8; sleep 8 ) & ST_PIDS="$ST_PIDS $!"; local ph=$!
  sleep 0.4
  local i
  for i in 1 2 3; do "$SELF" ctl >"$T/o6$i" 2>"$T/e6$i"; rc=$?; [ "$rc" = 5 ] || break; done
  [ "$rc" = 5 ] && [ "$(j .ticks_skipped)" = 3 ] && [ "$(j .last_skip_reason)" = lock-busy ]; chk "lock busy x3: exit 5, ticks_skipped=3, reason=$(j .last_skip_reason)" $?
  ! grep -q ALARM "$T/e61" "$T/e62"; chk "no ALARM before the 3rd skip" $?
  grep -q 'ALARM ctl tick skipped 3 ticks' "$T/e63"; chk "ALARM on stderr at ticks_skipped>=3: '$(grep ALARM "$T/e63")'" $?
  "$SELF" ctl --ask while-locked >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(j .ticks_skipped)" = 3 ]; chk "ask that cannot lock: exit 5, ticks_skipped unchanged" $?
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(j .ticks_skipped)" = 0 ]; chk "next successful run resets ticks_skipped to 0" $?

  # 7. guard, ctl: a process shaped like the interactive controller holding the SID
  local runs_before; runs_before="$(j .sends_total)"
  bash -c "exec -a 'claude --resume $CS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pg=$!
  sleep 0.4
  "$SELF" ctl >"$T/o7" 2>"$T/e7"; rc=$?
  [ "$rc" = 4 ] && grep -q 'ALARM ctl guard' "$T/e7" && [ "$(j .sends_total)" = "$runs_before" ] && ! grep -q '^ARGV' "$T/o7"; chk "guard: process 'claude --resume <SID>' -> exit 4, ALARM, claude not run ('$(grep ALARM "$T/e7" | cut -c1-140)')" $?
  [[ "$(j .last_skip_reason)" == guard:* ]]; chk "guard: last_skip_reason=$(j .last_skip_reason | cut -c1-60)" $?
  "$SELF" ctl --guard-check >/dev/null 2>&1; [ $? = 4 ]; chk "--guard-check: exit 4 while it is alive" $?
  kill "$pg"; wait "$pg" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; [ $? = 0 ]; chk "guard clear after the fake exits: runs" $?
  bash -c "exec -a claude python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pq=$!
  sleep 0.4
  setpid ctl "$pq"
  "$SELF" ctl >/dev/null 2>"$T/e7b"; rc=$?
  [ "$rc" = 4 ] && grep -q "pid $pq alive" "$T/e7b"; chk "guard: old_pid from seats.tsv alive with 'claude' in cmdline -> exit 4" $?
  kill "$pq"; wait "$pq" 2>/dev/null
  setpid ctl "$$"
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; [ $? = 0 ]; chk "guard: old_pid alive but cmdline without 'claude' -> not refused" $?
  setpid ctl 999999999
  bash -c "sleep 20; : $CS claude" & ST_PIDS="$ST_PIDS $!"; local pm=$!
  sleep 0.3
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; [ $? = 0 ]; chk "guard: a shell that merely mentions the SID is not a holder" $?
  kill "$pm" 2>/dev/null

  # 8. wiring (ctl)
  local real_row; real_row="$(SEATS_TABLE="$HOME/.claude/state/seats.tsv" awk -F'\t' '$1=="ctl"{print $3 "|" $7}' "$HOME/.claude/state/seats.tsv" 2>/dev/null)"
  [ "$real_row" = "de73e73c-5095-4d39-9703-1fc439e7236d|3845" ]; chk "defaults: real seats.tsv ctl row = SID de73e73c-..., old pid 3845" $?
  out="$(CTL_ASK_DRY=1 "$HERE/ctl-ask.sh" "hello there" 2>&1)"
  [[ "$out" == *"systemd-run --user --collect --unit seat-ask-ctl-"*"seat-tick.sh ctl --ask hello there"* ]]; chk "ctl-ask.sh wrapper (dry): '${out:0:170}'" $?
  "$SELF" ctl --status | jq -e 'has("last_tick") and has("last_sent") and has("ticks_skipped") and has("last_skip_reason") and has("sends_total") and has("last_exit") and has("last_duration_s") and has("last_prompt_kind") and has("status_file") and has("approvals_seen")' >/dev/null; chk "--status prints state JSON with all keys" $?
  [ "$("$HERE/ctl-sweep.sh" --status | jq -c .)" = "$("$SELF" ctl --status | jq -c .)" ]; chk "ctl-sweep.sh wrapper --status == seat-tick.sh ctl --status" $?

  # ---- the generalization: rb and r7 (33 ctl assertions above) ---------------------------------------
  # 9. rb TICK
  rm -f "$T/dash/fleet-status.md"
  "$SELF" rb >"$T/orb" 2>"$T/erb"; rc=$?
  [ "$rc" = 0 ]; chk "rb tick: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-rb $LA --resume $RS TICK $ts_re seat=rb tick=1 events_new=0\$" "$T/orb"; chk "rb: argv has model from row rb + SID from seats.tsv + TICK line 1 '$(grep -m1 ^ARGV "$T/orb" | cut -c1-170)'" $?
  [ "$(pl rb 2 | head -1)" = "$goal_rb" ] && [ "$goal_rb" != "" ]; chk "rb: prompt line 2 = the /goal CLEARWATER: line verbatim ('$(pl rb 2 | cut -c1-70)...')" $?
  [ "$(pl rb 3)" = 'Rules of this shape: one sweep toward the goal per tick; every DECISION is a wm-decide ledger row the same turn; wake the controller with ctl-ask.sh "<text>"; any background process you need outlives this turn only as a systemd-run --user unit with premise + expiry; every EVENT line gets a read and, if real, a mitigation this turn; log a DECISION row for each action; this turn ends when you print the timestamped STATUS block.' ] && [ "$(wc -l <"$T/dash/prompt.rb.txt")" = 2 ]; chk "rb: prompt line 3 = the rules line verbatim, exactly 3 lines" $?
  ! grep -q 'approvals_new\|status_age' "$T/dash/prompt.rb.txt"; chk "rb: no approvals_new / status_age in the prompt" $?
  grep -q '^seat_env=WM_SEAT=rb CLAUDE_SESSION_NAME=rb$' "$T/orb"; chk "rb: fake claude saw WM_SEAT=rb CLAUDE_SESSION_NAME=rb" $?
  grep -q -- ' --strict-mcp-config ' <(grep -m1 '^ARGV' "$T/orb") && grep -q '^lean_env=SEAT_LEAN=1 CLAUDE_LEAN_START=1$' "$T/orb"; chk "rb LEAN: fake claude got --strict-mcp-config and env SEAT_LEAN=1 CLAUDE_LEAN_START=1" $?
  ! grep -q -- 'strict-mcp-config' <(grep -m1 '^ARGV' "$T/o1") && ! grep -q -- '--mcp-config' <(grep -m1 '^ARGV' "$T/o1") && grep -q '^lean_env=SEAT_LEAN= CLAUDE_LEAN_START=$' "$T/o1"; chk "ctl NOT lean: sweep 1 has no --strict-mcp-config / --mcp-config and no SEAT_LEAN/CLAUDE_LEAN_START env" $?
  grep -m1 '^ARGV' "$T/o1" | grep -q -- " $CA --resume "; chk "ctl argv carries --settings ctl-settings.json (autoCompactEnabled) and nothing else lean" $?
  [ "$(jq -c . "$HOME/.config/claude-seat/ctl-settings.json")" = '{"autoCompactEnabled":true,"autoCompactWindow":"auto"}' ]; chk "real ctl-settings.json is exactly {autoCompactEnabled: true, autoCompactWindow: auto} (no hooks/plugins keys)" $?
  [ "$(jq -r '[.autoCompactEnabled, .autoCompactWindow] | join(" ")' "$HOME/.config/claude-seat/settings.json")" = "true auto" ]; chk "rb/r7 lean settings.json carries autoCompactEnabled=true autoCompactWindow=auto" $?
  SEAT_CTL_SETTINGS="$T/nonexistent.json" FAKE_SLEEP=0 "$SELF" ctl >"$T/octlm" 2>"$T/ectlm"; ! grep -q -- '--settings' <(grep -m1 '^ARGV' "$T/octlm") && grep -q 'WARN .*nonexistent.json missing' "$T/ectlm"; chk "ctl-settings.json missing: WARN on stderr, tick still runs without the flag" $?
  rm -f "$T/dash/fleet-status.md"   # that extra ctl sweep wrote its boundary marker; the rb/r7 "no --open" checks below look for its absence
  [ ! -e "$T/dash/fleet-status.md" ]; chk "rb: no --open written (fleet-status.md absent)" $?
  [ -e "$T/dash/rb.lock" ] && [ -s "$T/dash/rb-tick-last.log" ]; chk "rb: lock path rb.lock, log rb-tick-last.log" $?
  [ "$(jseat rb .sends_total)" = 1 ] && [ "$(jseat rb .last_prompt_kind)" = tick ] && [ "$(jseat rb .last_exit)" = 0 ] && [ "$(jseat rb .status_file)" = null ] && [ "$(jseat rb .approvals_seen)" = 0 ]; chk "rb: state rb-tick.json sends_total=1 kind=tick exit 0 status_file null approvals_seen 0" $?
  [ "$(j .sends_total)" = "$(jq -r .sends_total "$T/dash/ctl-tick.json")" ] && [ "$(j .last_prompt_kind)" = sweep ]; chk "rb tick did not touch ctl-tick.json" $?
  # pull step: a new commit on the remote reaches the next tick
  ( cd "$T" && git clone -q remote.git other && cd other && sed -i 's/CLEARWATER: first-pass yield >= 60 % v1/CLEARWATER: first-pass yield >= 60 % v2-pulled/' wiki/goal.md && $G commit -qam v2 && $G push -q origin HEAD:main ) >/dev/null 2>&1
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  pl rb 2 | grep -q 'v2-pulled' && [ "$(jseat rb .sends_total)" = 2 ] && pl rb 1 | grep -Eq "tick=2 events_new=0\$"; chk "rb: git pull --ff-only ran (remote v2 line reached the prompt, tick=2)" $?
  # pull failure: remote gone -> local copy, prefixed
  mv "$T/remote.git" "$T/remote.gone"
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>"$T/erbp"; rc=$?
  [ "$rc" = 0 ] && [ "$(pl rb 2)" = "goal.md pull FAILED, local copy: $(grep -m1 '^/goal CLEARWATER:' "$GOAL_MD")" ]; chk "rb: pull failure -> 'goal.md pull FAILED, local copy: ' + local line, tick still runs" $?
  mv "$T/remote.gone" "$T/remote.git"
  # no goal line at all -> refuse, claude not run
  cp "$GOAL_MD" "$T/goal.keep"; grep -v '^/goal CLEARWATER:' "$T/goal.keep" >"$GOAL_MD"
  local rb_sends; rb_sends="$(jseat rb .sends_total)"
  FAKE_SLEEP=0 "$SELF" rb >"$T/orbn" 2>"$T/erbn"; rc=$?
  [ "$rc" = 6 ] && grep -q 'ALARM rb no /goal line' "$T/erbn" && ! grep -q '^ARGV' "$T/orbn" && [ "$(jseat rb .sends_total)" = "$rb_sends" ]; chk "rb: goal_pattern matches nothing -> exit 6, ALARM, claude not run" $?
  cp "$T/goal.keep" "$GOAL_MD"
  ( cd "$T/notes" && git checkout -q -- wiki/goal.md ) 2>/dev/null
  # rb ASK
  "$SELF" rb --ask "status of 1025?" >"$T/orba" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-rb $LA --resume $RS ASK $ts_re seat=rb events_new=0: status of 1025\?\$" "$T/orba" && [ -s "$T/dash/rb-ask-last.log" ] && [ "$(jseat rb .last_prompt_kind)" = ask ] && [ "$(jseat rb .sends_total)" = 3 ]; chk "rb ASK: 'ASK <time> <date> seat=rb: <text>', rb-ask-last.log, sends_total unchanged" $?

  # 10. r7 TICK
  "$SELF" r7 >"$T/or7" 2>"$T/er7"; rc=$?
  [ "$rc" = 0 ]; chk "r7 tick: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-r7 $LA --resume $SS TICK $ts_re seat=r7 tick=1 events_new=0\$" "$T/or7"; chk "r7: argv has model from row r7 + SID from seats.tsv + TICK line 1" $?
  [ "$(pl r7 2)" = "$goal_r7" ] && [ "$(pl r7 3 | cut -c1-23)" = "Rules of this shape: on" ] && [ "$(wc -l <"$T/dash/prompt.r7.txt")" = 2 ]; chk "r7: line 2 = the /goal CLEARWATER-R7 line verbatim (not the rb line), line 3 = rules, 3 lines" $?
  grep -q '^seat_env=WM_SEAT=r7 CLAUDE_SESSION_NAME=r7$' "$T/or7" && [ -e "$T/dash/r7.lock" ] && [ -s "$T/dash/r7-tick-last.log" ] && [ ! -e "$T/dash/fleet-status.md" ] && ! grep -q 'approvals_new' "$T/dash/prompt.r7.txt"; chk "r7: WM_SEAT=r7, r7.lock, r7-tick-last.log, no --open, no approvals_new" $?
  [ "$(jseat r7 .sends_total)" = 1 ] && [ "$(jseat r7 .last_prompt_kind)" = tick ]; chk "r7: state r7-tick.json sends_total=1 kind=tick" $?

  # 11. guard per seat: a fake 'claude --resume <sid>' blocks only its own seat
  local s sid
  for s in rb r7 ctl; do
    case "$s" in rb) sid="$RS" ;; r7) sid="$SS" ;; ctl) sid="$CS" ;; esac
    bash -c "exec -a 'claude --resume $sid' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pz=$!
    sleep 0.4
    rm -f "$T/dash/prompt.$s.txt"
    "$SELF" "$s" >"$T/og$s" 2>"$T/eg$s"; rc=$?
    [ "$rc" = 4 ] && grep -q "ALARM $s guard" "$T/eg$s" && ! grep -q '^ARGV' "$T/og$s" && [ ! -e "$T/dash/prompt.$s.txt" ] && [[ "$(jseat "$s" .last_skip_reason)" == guard:* ]]; chk "guard $s: fake 'claude --resume $sid' -> exit 4, ALARM, claude not run" $?
    "$SELF" "$s" --guard-check >/dev/null 2>&1; [ $? = 4 ]; chk "guard $s: --guard-check exit 4" $?
    kill "$pz"; wait "$pz" 2>/dev/null; sleep 0.3
  done
  bash -c "exec -a 'claude --resume $RS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pr=$!
  sleep 0.4
  FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ]; chk "guard is per seat: a holder of the rb SID does not block r7" $?
  kill "$pr"; wait "$pr" 2>/dev/null

  # 11b. guard_since marks the first refusal of a run of refusals (fleet-dash alarm: guard-blocked > 60 min) and clears on a clean run
  bash -c "exec -a 'claude --resume $SS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pk=$!
  sleep 0.4
  "$SELF" r7 >/dev/null 2>&1; local gs1; gs1="$(jseat r7 .guard_since)"
  sleep 1.2; "$SELF" r7 >/dev/null 2>&1
  [ "$gs1" != null ] && [ "$gs1" -gt 0 ] && [ "$(jseat r7 .guard_since)" = "$gs1" ]; chk "guard_since set on the first refusal ($gs1) and kept by the second" $?
  kill "$pk"; wait "$pk" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1
  [ "$(jseat r7 .guard_since)" = null ] && [ "$(jseat r7 .last_skip_reason)" = null ]; chk "guard_since and last_skip_reason clear after a clean run" $?

  # 12. ASK waits for the lock up to the longer bound; a tick gives up at the short one
  ( exec 8>"$T/dash/rb.lock"; flock 8; sleep 3 ) & ST_PIDS="$ST_PIDS $!"; local pw=$!
  sleep 0.4
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ]; chk "tick with the lock held past SEAT_LOCK_WAIT=1: exit 5 (gives up)" $?
  SEAT_LOCK_WAIT=1 SEAT_ASK_LOCK_WAIT=15 FAKE_SLEEP=0 "$SELF" rb --ask "must land" >"$T/ow" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV:.*ASK .*seat=rb events_new=0: must land' "$T/ow"; chk "ASK with the same lock held waits (SEAT_ASK_LOCK_WAIT=15) and lands: exit 0" $?
  wait "$pw" 2>/dev/null
  grep -q 'LOCK_WAIT="${SEAT_LOCK_WAIT:-60}"' "$SELF" && grep -q 'ASK_LOCK_WAIT="${SEAT_ASK_LOCK_WAIT:-1800}"' "$SELF"; chk "defaults: tick lock wait 60 s, ask lock wait 1800 s" $?

  # 13. timeout_sec column is the per-turn ceiling (95 %): row tmo has 4 s -> cap 3 s
  local t0; t0=$(date +%s)
  FAKE_SLEEP=20 "$SELF" tmo >"$T/otmo" 2>&1; rc=$?
  [ "$rc" = 124 ] && [ $(( $(date +%s) - t0 )) -lt 15 ] && [ "$(jseat tmo .last_exit)" = 124 ]; chk "timeout_sec=4: a 20 s claude is stopped at 3 s, exit 124 recorded ($(( $(date +%s) - t0 ))s wall)" $?

  # 14. unknown seat / usage
  "$SELF" nosuchseat >/dev/null 2>&1; [ $? = 64 ]; chk "unknown seat: exit 64" $?
  "$SELF" rb --ask >/dev/null 2>&1; [ $? = 64 ]; chk "--ask without text: exit 64" $?

  # 15. seat-ask.sh
  out="$(SEAT_ASK_DRY=1 "$HERE/seat-ask.sh" r7 "hello there" 2>&1)"
  [[ "$out" == *"systemd-run --user --collect --unit seat-ask-r7-"*"seat-tick.sh r7 --ask hello there"* ]]; chk "seat-ask.sh r7 (dry): '${out:0:170}'" $?
  SEAT_ASK_DRY=1 "$HERE/seat-ask.sh" nosuchseat x >/dev/null 2>&1; [ $? = 64 ]; chk "seat-ask.sh: unknown seat -> exit 64" $?

  # 15b. preconditions run before --open: a missing model row refuses (exit 3) and leaves no fleet-status.md (no `boundary: open`)
  printf 'rb test-model-rb\nr7 test-model-r7\n' >"$MRC_TABLE"; rm -f "$T/dash/fleet-status.md"
  "$SELF" ctl >"$T/o15b" 2>"$T/e15b"; rc=$?
  [ "$rc" = 3 ] && grep -q "ALARM ctl: no 'controller' model row" "$T/e15b" && ! grep -q '^ARGV' "$T/o15b" && [ ! -e "$T/dash/fleet-status.md" ] && [ "$(j .last_skip_reason)" = no-model ]; chk "ctl tick, no controller model row: exit 3, claude not run, fleet-status.md NOT written (no boundary: open)" $?
  printf 'controller test-model-2\nrb test-model-rb\nr7 test-model-r7\n' >"$MRC_TABLE"

  # 15c. seat-ask.sh: a refused ASK is visible (fake tick bin, real transient unit; nothing touches a seat)
  printf '#!/bin/bash\necho "ALARM $1 guard: fake refusal"\nexit "$(cat "$0.rc")"\n' >"$T/fake-tick"; chmod +x "$T/fake-tick"; echo 4 >"$T/fake-tick.rc"
  out="$(SEAT_ASK_TICK_BIN="$T/fake-tick" "$HERE/seat-ask.sh" r7 "refuse me" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 4 ] && [ "$out" = "ASK REFUSED r7: ALARM r7 guard: fake refusal" ]; chk "seat-ask.sh: unit exit 4 -> exit 4 + 'ASK REFUSED r7: <last line>' on stderr ($rc: ${out:0:70})" $?
  echo 6 >"$T/fake-tick.rc"; out="$(SEAT_ASK_TICK_BIN="$T/fake-tick" "$HERE/seat-ask.sh" r7 "refuse me" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 6 ] && [[ "$out" == "ASK REFUSED r7: "* ]]; chk "seat-ask.sh: unit exit 6 -> exit 6 + ASK REFUSED" $?
  echo 0 >"$T/fake-tick.rc"; out="$(SEAT_ASK_TICK_BIN="$T/fake-tick" "$HERE/seat-ask.sh" r7 "fine" 2>"$T/e15c")"; rc=$?
  [ "$rc" = 0 ] && [[ "$out" == seat-ask-r7-* ]] && [ ! -s "$T/e15c" ]; chk "seat-ask.sh: unit exit 0 -> exit 0, prints the unit name, nothing on stderr" $?

  # 15d. EVENTS (10-22): events block in every prompt, offset, --event, wake, chain
  local EVD="$T/dash" evsz
  ev() { printf '%s | selftest | %s\n' "$(date -Iseconds)" "$2" >>"$EVD/$1-events.log"; }
  local rb_s0 rb_off0; rb_s0="$(jseat rb .sends_total)"
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oe0" 2>&1; rc=$?
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oe0" && grep -q 'no new events' "$T/oe0" && [ "$(jseat rb .sends_total)" = "$rb_s0" ]; chk "--event with an empty log: exit 0, claude not run, nothing counted" $?
  ev rb "ALARM landrisk: 1025 CI red"; ev rb "ALARM inner-ws: 953 stalled"; ev rb "ALARM deploy: mcphost .64 pending"
  FAKE_SLEEP=0 "$SELF" rb >"$T/oe1" 2>&1; rc=$?; evsz="$(stat -c %s "$EVD/rb-events.log")"
  [ "$rc" = 0 ] && grep -Eq "^ARGV: .* TICK $ts_re seat=rb tick=[0-9]+ events_new=3\$" "$T/oe1"; chk "tick with 3 new events: first prompt line ends events_new=3 ('$(grep -m1 ^ARGV "$T/oe1" | grep -o 'TICK.*' | cut -c1-70)')" $?
  [ "$(grep -c '^EVENTS since ' "$EVD/prompt.rb.txt")" = 1 ] && grep -Eq '^EVENTS since (the start|[0-9]{1,2}:[0-9]{2} [AP]M):$' "$EVD/prompt.rb.txt" && [ "$(grep -c ' | selftest | ' "$EVD/prompt.rb.txt")" = 3 ] \
    && [ "$(grep -n 'landrisk' "$EVD/prompt.rb.txt" | cut -d: -f1)" -lt "$(grep -n 'deploy: mcphost' "$EVD/prompt.rb.txt" | cut -d: -f1)" ]; chk "prompt carries 'EVENTS since <time>:' + the 3 lines, oldest first" $?
  [ "$(jseat rb .events_offset)" = "$evsz" ] && [ "$(jseat rb .events_new)" = 3 ] && [ "$(jseat rb .chained)" = 0 ]; chk "state: events_offset=$evsz (log size) events_new=3 chained=0" $?
  FAKE_SLEEP=0 "$SELF" rb >"$T/oe2" 2>&1
  grep -Eq " TICK $ts_re seat=rb tick=[0-9]+ events_new=0\$" <(grep -m1 ^ARGV "$T/oe2") && ! grep -q '^EVENTS since' "$EVD/prompt.rb.txt"; chk "next tick: events_new=0 and no EVENTS block (delivered once)" $?
  # --event: EVENT first line, goal line, rules line with the EVENT rule
  ev rb "ALARM reprice: rate card moved"
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oe3" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -Eq "^ARGV: .* --resume $RS EVENT $ts_re seat=rb events_new=1\$" <(grep -m1 ^ARGV "$T/oe3") && [ "$(pl rb 2)" = "$(grep -m1 '^/goal CLEARWATER:' "$GOAL_MD")" ] \
    && pl rb 3 | grep -q 'every EVENT line gets a read and, if real, a mitigation this turn; log a DECISION row for each action' && pl rb 4 | grep -q '^EVENTS since' && pl rb 5 | grep -q 'rate card moved'; chk "--event: 'EVENT <time> <date> seat=rb events_new=1', goal line, rules line (EVENT rule), EVENTS block" $?
  [ "$(jseat rb .last_prompt_kind)" = event ] && [ -s "$EVD/rb-event-last.log" ] && [ "$(jseat rb .sends_total)" = "$(( rb_s0 + 2 ))" ]; chk "--event: kind=event, rb-event-last.log, sends_total counts ticks only" $?
  # cap: 45 new lines -> 40 shown + '... +5 more'; whole log delivered (offset at the end)
  local i; for i in $(seq 1 45); do ev rb "burst $i"; done
  FAKE_SLEEP=0 "$SELF" rb >"$T/oe4" 2>&1; evsz="$(stat -c %s "$EVD/rb-events.log")"
  [ "$(grep -c ' | selftest | burst ' "$EVD/prompt.rb.txt")" = 40 ] && grep -q '^\.\.\. +5 more' "$EVD/prompt.rb.txt" && grep -q 'events_new=45' "$EVD/prompt.rb.txt" && grep -q ' | burst 1$' "$EVD/prompt.rb.txt" && ! grep -q ' | burst 41$' "$EVD/prompt.rb.txt" && [ "$(jseat rb .events_offset)" = "$evsz" ]; chk "45 new events: first 40 oldest-first, '... +5 more', events_new=45, offset at the end" $?
  # a half-written line waits
  printf '%s | selftest | half' "$(date -Iseconds)" >>"$EVD/rb-events.log"
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oe5" 2>&1
  ! grep -q '^ARGV' "$T/oe5"; chk "a line without its newline is not delivered yet" $?
  printf ' line\n' >>"$EVD/rb-events.log"
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oe6" 2>&1
  grep -q 'events_new=1' "$EVD/prompt.rb.txt" && grep -q ' | selftest | half line$' "$EVD/prompt.rb.txt"; chk "...and arrives whole once complete" $?
  # rotation: log shorter than the offset -> read from 0
  printf '%s | selftest | after rotate\n' "$(date -Iseconds)" >"$EVD/rb-events.log"
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  grep -q 'events_new=1' "$EVD/prompt.rb.txt" && grep -q 'after rotate' "$EVD/prompt.rb.txt"; chk "log shorter than events_offset (rotated): read from 0" $?
  # a failing turn does not advance the offset (the lines come again)
  ev rb "retry me"; FAKE_EXIT=3 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  grep -q 'events_new=1' "$EVD/prompt.rb.txt" && grep -q 'retry me' "$EVD/prompt.rb.txt"; chk "claude exit 3: events_offset not advanced, line re-delivered by the next turn" $?
  # ASK carries events too
  ev rb "ask-time event"; FAKE_SLEEP=0 "$SELF" rb --ask "anything?" >"$T/oe7" 2>&1
  grep -Eq "ASK $ts_re seat=rb events_new=1: anything\?" "$T/oe7" && grep -q 'ask-time event' "$EVD/prompt.rb.txt"; chk "ASK: events_new=1 + EVENTS block after the text" $?
  # ctl: SWEEP and EVENT
  ev ctl "ALARM ryzen7 load 15"; rm -f "$EVD/fleet-status.md"
  FAKE_SLEEP=0 "$SELF" ctl --event >"$T/oe8" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -Eq "^ARGV: .* EVENT $ts_re seat=ctl approvals_new=[0-9]+ events_new=1\$" <(grep -m1 ^ARGV "$T/oe8") && [ ! -e "$EVD/fleet-status.md" ] \
    && pl ctl 2 | grep -q '^Rules of this shape: every EVENT line gets a read' && pl ctl 4 | grep -q 'ryzen7 load 15'; chk "ctl --event: EVENT prompt, rules line, block, no boundary: open written" $?
  ev ctl "ALARM second"; FAKE_SLEEP=0 "$SELF" ctl >"$T/oe9" 2>&1
  grep -Eq "SWEEP $ts_re tick=[0-9]+ status_age=[^ ]+ approvals_new=[0-9]+ events_new=1\$" <(grep -m1 ^ARGV "$T/oe9") && grep -q 'ALARM second' "$EVD/prompt.ctl.txt"; chk "ctl SWEEP: events_new=1 + block" $?
  # --event with the lock held: .wake, exit 0, no skip counted
  local sk0; sk0="$(jseat rb .ticks_skipped)"; ev rb "while locked"
  ( exec 8>"$EVD/rb.lock"; flock 8; sleep 3 ) & ST_PIDS="$ST_PIDS $!"; local pe=$!
  sleep 0.4
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oe10" 2>&1; rc=$?
  [ "$rc" = 0 ] && [ -e "$EVD/rb.wake" ] && ! grep -q '^ARGV' "$T/oe10" && [ "$(jseat rb .ticks_skipped)" = "$sk0" ] && [ -z "$(grep ALARM "$T/oe10")" ]; chk "--event, lock held: exit 0, rb.wake touched, no ARGV, ticks_skipped unchanged, no ALARM" $?
  kill "$pe" 2>/dev/null; wait "$pe" 2>/dev/null; rm -f "$EVD/rb.wake"
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1   # drain "while locked"
  # chain: a bell during the turn -> exactly one more EVENT turn in the same process; a second bell during the chained turn waits for the next tick
  local o_ch="$T/och" r7s0=0; : >"$EVD/r7-events.log"; rm -f "$EVD/r7-tick.json" "$EVD/r7.wake"
  FAKE_SLEEP=3 "$SELF" r7 >"$o_ch" 2>&1 & ST_PIDS="$ST_PIDS $!"; local pc=$!
  for i in $(seq 1 100); do grep -q '^START' "$o_ch" && break; sleep 0.1; done   # claude (fake) is running: the prompt is already composed
  EVENT_SOURCE=selftest SEAT_EVENT_DRY=1 "$HERE/seat-event.sh" r7 "bell mid-turn" >"$T/obell1" 2>&1
  for i in $(seq 1 100); do [ "$(grep -c '^START' "$o_ch")" = 2 ] && break; sleep 0.1; done   # the chained claude is running
  EVENT_SOURCE=selftest SEAT_EVENT_DRY=1 "$HERE/seat-event.sh" r7 "bell mid-chain" >"$T/obell2" 2>&1
  wait "$pc"; rc=$?
  [ -e "$EVD/r7.wake" ] && [ ! -s "$T/obell1" ] && [ ! -s "$T/obell2" ]; chk "seat-event.sh during a turn: lock held -> .wake touched, no spawn (both bells)" $?
  [ "$(grep -c '^START' "$o_ch")" = 2 ] && [ "$rc" = 0 ]; chk "chain: exactly 2 claude runs in one invocation ($(grep -c '^START' "$o_ch")), exit 0" $?
  grep -Eq "^ARGV: .* EVENT $ts_re seat=r7 events_new=1\$" <(grep '^ARGV' "$o_ch" | sed -n 2p) && grep -q 'chaining one EVENT turn' "$o_ch"; chk "chained run: 'EVENT <time> <date> seat=r7 events_new=1' ($(grep '^ARGV' "$o_ch" | sed -n 2p | grep -o 'EVENT.*' | cut -c1-60))" $?
  [ "$(jseat r7 .chained)" = 1 ] && [ "$(jseat r7 .last_prompt_kind)" = event ] && [ "$(jseat r7 .sends_total)" = "$(( r7s0 + 1 ))" ]; chk "tick.json: chained=1 kind=event, sends_total +1 (the chain is not a tick)" $?
  [ "$(jseat r7 .events_offset)" -lt "$(stat -c %s "$EVD/r7-events.log")" ] && [ -e "$EVD/r7.wake" ]; chk "second bell during the chained turn is NOT chained again (offset < log size, r7.wake left for the next tick)" $?
  FAKE_SLEEP=0 "$SELF" r7 >"$T/och3" 2>&1
  [ "$(jseat r7 .chained)" = 0 ] && grep -q 'mid-chain' "$EVD/prompt.r7.txt" && [ ! -e "$EVD/r7.wake" ] && [ "$(grep -c '^START' "$T/och3")" = 1 ]; chk "next tick: delivers the waiting line, removes r7.wake, chained back to 0, one run" $?
  # a failing turn never chains
  : >"$EVD/rb-events.log"; printf '0' >/dev/null; rm -f "$EVD/rb.wake"; FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  FAKE_EXIT=3 FAKE_SLEEP=2 "$SELF" rb >"$T/ofc" 2>&1 & ST_PIDS="$ST_PIDS $!"; pc=$!
  for i in $(seq 1 100); do grep -q '^START' "$T/ofc" && break; sleep 0.1; done; EVENT_SOURCE=selftest SEAT_EVENT_DRY=1 "$HERE/seat-event.sh" rb "bell during a failing turn" >/dev/null 2>&1
  wait "$pc"; rc=$?
  [ "$rc" = 3 ] && [ "$(grep -c '^START' "$T/ofc")" = 1 ]; chk "claude exit 3 with a bell mid-turn: no chain (1 run, exit 3)" $?
  rm -f "$EVD/rb.wake"; FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1

  # 16. contracts against the REAL table, goal.md and unit files (read-only; no-drift)
  local real="$HOME/.claude/state/seats.tsv" realgoal="$HOME/Notes/wiki/goal.md" bad=""
  local rs rp rn
  while IFS=$'\t' read -r rs _ _ _ _ rp _; do
    rn="$(grep -cE -- "$rp" "$realgoal" 2>/dev/null)"
    [ "${rn:-0}" -ge 1 ] || bad="$bad $rs(goal_pattern '$rp' matches $rn lines)"
    [ "$(grep -E -- "$rp" "$realgoal" | head -1 | cut -c1-6)" = "/goal " ] || bad="$bad $rs(first match is not a /goal line)"
  done < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7}' "$real")
  [ -z "$bad" ]; chk "real table: every goal_pattern matches a /goal line in the real goal.md${bad:+: $bad}" $?
  local max_to tm_ok=1 svc="$UNIT_DIR/seat-tick@.service" tim="$UNIT_DIR/seat-tick@.timer" tm
  max_to="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $5+0>m {m=$5+0} END{print m+0}' "$real")"
  [ -r "$svc" ] && [ "$(sed -n 's/^TimeoutStartSec=//p' "$svc")" -ge "$max_to" ] && grep -q '^ExecStart=%h/.local/bin/seat-tick.sh %i$' "$svc"; chk "unit contract: seat-tick@.service TimeoutStartSec >= max timeout_sec ($max_to), ExecStart seat-tick.sh %i" $?
  grep -q '^OnFailure=seat-tick-failed@%i.service$' "$svc" 2>/dev/null && grep -q '^ExecStart=%h/.local/bin/seat-tick-failed.sh %i$' "$UNIT_DIR/seat-tick-failed@.service" 2>/dev/null; chk "unit contract: seat-tick@.service OnFailure=seat-tick-failed@%i.service and seat-tick-failed@.service exists (ExecStart seat-tick-failed.sh %i)" $?
  out="$(printf '#!/bin/bash\necho "nowake=${SEAT_EVENT_NOWAKE:-} $*"\n' >"$T/fe"; chmod +x "$T/fe"; SEAT_EVENT_BIN="$T/fe" SEAT_FAILED_STATUS=1 SEAT_FAILED_JOURNAL=/dev/null "$HERE/seat-tick-failed.sh" ctl)"
  [[ "$out" == "nowake=1 ctl SEAT-TICK FAILED seat=ctl: "* ]]; chk "unit contract: a failing ctl tick raises its event with SEAT_EVENT_NOWAKE=1 (no wake loop): '${out:0:60}'" $?
  out="$(SEAT_EVENT_BIN="$T/fe" SEAT_FAILED_STATUS=1 SEAT_FAILED_JOURNAL=/dev/null "$HERE/seat-tick-failed.sh" rb)"
  [[ "$out" == "nowake= ctl SEAT-TICK FAILED seat=rb: "* ]]; chk "unit contract: a failing rb tick raises the ctl event WITH a wake" $?
  grep -q '^Environment=PATH=%h/.local/seat-bin:' "$svc" 2>/dev/null; chk "unit contract: seat-tick@.service Environment=PATH starts with %h/.local/seat-bin:" $?
  for tm in $(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $4}' "$real" | sort -u); do grep -q "^OnUnitActiveSec=${tm}min\$" "$tim" 2>/dev/null || tm_ok=0; done
  [ "$tm_ok" = 1 ]; chk "unit contract: seat-tick@.timer OnUnitActiveSec equals every tick_min in the real table" $?

  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

# ---- arguments -----------------------------------------------------------------------------------
SEAT=""; MODE=tick; ASK_TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) MODE=selftest ;;
    --status) MODE=status ;;
    --event) MODE=event ;;
    --guard-check) MODE=guard ;;
    --ask) MODE=ask; [ -n "${2:-}" ] || usage; ASK_TEXT="$2"; shift ;;
    -*) usage ;;
    *) [ -z "$SEAT" ] || usage; SEAT="$1" ;;
  esac
  shift
done
[ "$MODE" = selftest ] && { selftest; exit $?; }
[ -n "$SEAT" ] || usage
load_seat "$SEAT" || { echo "seat-tick: unknown seat '$SEAT' (or malformed row) in $SEATS" >&2; exit 64; }
STATE="$DASH/$SEAT-tick.json"
SFILE=""; [ "$SEAT" = ctl ] && SFILE="$DASH/fleet-status.md"
status() { cat "$STATE" 2>/dev/null || echo '{}'; }
count_approvals() { [ -r "$APPROVALS" ] && grep -cvE '^[[:space:]]*(#|$)' "$APPROVALS" || true; }
case "$MODE" in
  status) status; exit 0 ;;
  guard) why="$(guard)" && { echo "guard: clear"; exit 0; }; echo "guard: REFUSED $why" >&2; exit 4 ;;
esac
KIND="$MODE"   # tick | ask | event

# ---- one turn -------------------------------------------------------------------------------------
mkdir -p "$DASH" || exit 1
now="$(date +%s)"
iso="$(date -Iseconds)"

# state: every field kept across runs; writes are tmp+mv
st="$(status)"
sget() { jq -r "$1" <<<"$st" 2>/dev/null; }
S_last_sent="$(sget '.last_sent // 0')"; S_skipped="$(sget '.ticks_skipped // 0')"; S_sends="$(sget '.sends_total // 0')"
S_reason="$(sget '.last_skip_reason // ""')"; S_seen="$(sget '.approvals_seen // 0')"; S_exit="$(sget '.last_exit // null')"
S_dur="$(sget '.last_duration_s // null')"; S_kind="$(sget '.last_prompt_kind // ""')"; S_gsince="$(sget '.guard_since // 0')"
S_evoff="$(sget '.events_offset // 0')"; S_lastprompt="$(sget '.last_prompt // 0')"; S_evnew="$(sget '.events_new // 0')"; S_chained="${SEAT_TICK_CHAINED:-0}"
PREV_SENT="$S_last_sent"
EVF="$DASH/$SEAT-events.log"; WAKE="$DASH/$SEAT.wake"
T0="${SEAT_TICK_T0:-$now}"   # first start of this unit run: a chained turn must fit in the same TimeoutStartSec
save() {   # reads the S_* variables
  local tmp; tmp="$(mktemp "$DASH/.$SEAT-tick.XXXXXX")" || return 1
  jq -n --arg seat "$SEAT" --arg iso "$iso" --argjson ep "$now" --argjson ls "$S_last_sent" --argjson sk "$S_skipped" --arg why "$S_reason" \
        --argjson sn "$S_sends" --argjson as "$S_seen" --argjson ex "$S_exit" --argjson du "$S_dur" --arg kind "$S_kind" --arg sf "$SFILE" --argjson gs "$S_gsince" \
        --argjson eo "$S_evoff" --argjson lp "$S_lastprompt" --argjson en "$S_evnew" --argjson ch "$S_chained" \
    '{seat:$seat, last_tick:{iso:$iso,epoch:$ep}, last_sent:$ls, ticks_skipped:$sk, last_skip_reason:(if $why=="" then null else $why end),
      sends_total:$sn, last_exit:$ex, last_duration_s:$du, last_prompt_kind:(if $kind=="" then null else $kind end),
      status_file:(if $sf=="" then null else $sf end), approvals_seen:$as,
      guard_since:(if ($why|startswith("guard:")) and $gs>0 then $gs else null end),
      events_offset:$eo, last_prompt:(if $lp>0 then $lp else null end), events_new:$en, chained:$ch}' >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
}

# a. the lock serializes ticks and asks: two processes never share the session. A tick gives up fast; an ask must land.
W="$LOCK_WAIT"; [ "$KIND" = ask ] && W="$ASK_LOCK_WAIT"
exec 9>"$DASH/$SEAT.lock"
if [ "$KIND" = event ]; then   # an EVENT never waits: a running turn will chain one at its end
  if ! flock -n 9; then touch "$WAKE"; echo "seat-tick: $SEAT turn running, EVENT deferred (.wake touched)"; exit 0; fi
elif ! flock -w "$W" 9; then
  echo "seat-tick: $SEAT lock busy after ${W}s, kind=$KIND" >&2
  if [ "$KIND" = tick ]; then
    S_skipped=$((S_skipped + 1)); S_reason="lock-busy"; save
    [ "$S_skipped" -ge "$ALARM_AT" ] && echo "ALARM $SEAT tick skipped $S_skipped ticks (lock busy)" >&2
  fi
  exit 5
fi

# b. guard: the interactive seat still owns the session; never kill, refuse loudly
if why="$(guard)"; then :; else
  echo "ALARM $SEAT guard: interactive seat still running, refusing to resume the session ($why)" >&2
  case "$S_reason" in guard:*) [ "$S_gsince" -gt 0 ] 2>/dev/null || S_gsince="$now" ;; *) S_gsince="$now" ;; esac   # guard_since = first refusal of this run of refusals (dash alarm: > 60 min)
  S_reason="guard:${why:0:100}"; save; exit 4
fi

# b2. (after the guard, right before the prompt is built, so a bell during the guard scan / goal.md pull is still in this prompt) new events since the last delivered byte (read-only here; the offset moves only after an exit-0 turn). Whole lines only, so a half-written line waits.
ev_size=0; [ -r "$EVF" ] && ev_size="$(stat -c %s "$EVF")"
[ "$S_evoff" -gt "$ev_size" ] && S_evoff=0   # log rotated or truncated: read it all
EV_NEW=0; EV_BLOCK=""; NEW_EVOFF="$S_evoff"
if [ "$ev_size" -gt "$S_evoff" ]; then
  evchunk="$(mktemp "$DASH/.$SEAT-evchunk.XXXXXX")"
  tail -c +$((S_evoff + 1)) "$EVF" 2>/dev/null | head -c $((ev_size - S_evoff)) >"$evchunk"
  evpart="$(tail -n1 "$evchunk" | wc -c)"; [ -z "$(tail -c1 "$evchunk")" ] && evpart=0   # bytes after the last newline
  evlen=$(( $(stat -c %s "$evchunk") - evpart ))
  if [ "$evlen" -gt 0 ]; then
    NEW_EVOFF=$(( S_evoff + evlen )); evtxt="$(head -c "$evlen" "$evchunk")"
    EV_NEW="$(printf '%s\n' "$evtxt" | grep -c .)"
    if [ "$S_lastprompt" -gt 0 ] 2>/dev/null; then evsince="$(date -d "@$S_lastprompt" '+%-I:%M %p')"; else evsince="the start"; fi
    EV_BLOCK="EVENTS since $evsince:"$'\n'"$(printf '%s\n' "$evtxt" | grep . | head -n "$EV_MAX")"
    [ "$EV_NEW" -gt "$EV_MAX" ] && EV_BLOCK="$EV_BLOCK"$'\n'"... +$((EV_NEW - EV_MAX)) more (see $EVF)"
  fi
  rm -f "$evchunk"
fi
if [ "$KIND" = event ] && [ "$EV_NEW" = 0 ]; then rm -f "$WAKE"; echo "seat-tick: $SEAT EVENT with no new events (already delivered), nothing to do"; exit 0; fi

rm -f "$WAKE"   # everything appended before this point is in this prompt; a later bell touches it again
# c. prompt
stamp="$(date '+%-I:%M %p %Z') $(date +%Y-%m-%d)"
total=0; new=0
if [ "$SEAT" = ctl ]; then
  total="$(count_approvals)"; total="${total:-0}"
  new=$(( total - S_seen )); [ "$new" -lt 0 ] && new="$total"      # log shrank (rotated): count it all
fi
n=$((S_sends + 1))
if [ "$KIND" = ask ]; then
  if [ "$SEAT" = ctl ]; then PROMPT="ASK $stamp seat=ctl approvals_new=$new events_new=$EV_NEW: $ASK_TEXT"; else PROMPT="ASK $stamp seat=$SEAT events_new=$EV_NEW: $ASK_TEXT"; fi
elif [ "$KIND" = event ] && [ "$SEAT" = ctl ]; then
  PROMPT="EVENT $stamp seat=ctl approvals_new=$new events_new=$EV_NEW"$'\n'"Rules of this shape: $EVENT_RULE; this turn ends when you print the timestamped STATUS block."
elif [ "$SEAT" = ctl ]; then
  if [ -e "$SFILE" ]; then age="$(( (now - $(stat -c %Y "$SFILE")) / 60 ))m"; else age="none"; fi
  if [ "$PREV_SENT" -gt 0 ] 2>/dev/null; then since="$(date -d "@$PREV_SENT" '+%Y-%m-%d %-I:%M %p')"; else since="24 hours ago"; fi
  PROMPT="SWEEP $stamp tick=$n status_age=$age approvals_new=$new events_new=$EV_NEW"$'\n'"First act: read pending wm-decide rows and approval-check.sh --since \"$since\"; end by piping FLEET STATUS into fleet-status-write.sh."
else
  # the seat's /goal line, verbatim from goal.md after a ff-only pull (the /goal stop hook does not run under `claude -p`)
  pull_note=""
  GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$(dirname "$GOAL_FILE")" pull --ff-only -q </dev/null >&2 || pull_note="goal.md pull FAILED, local copy: "
  goal_line="$(grep -m1 -E -- "$GOAL_RE" "$GOAL_FILE" 2>/dev/null)"
  if [ -z "$goal_line" ]; then
    echo "ALARM $SEAT no /goal line matching '$GOAL_RE' in $GOAL_FILE, refusing to tick without the goal" >&2
    S_reason="no-goal-line"; save; exit 6
  fi
  if [ "$KIND" = event ]; then PROMPT="EVENT $stamp seat=$SEAT events_new=$EV_NEW"; else PROMPT="TICK $stamp seat=$SEAT tick=$n events_new=$EV_NEW"; fi
  PROMPT="$PROMPT"$'\n'"${pull_note}${goal_line}"$'\n'"$RULES_LINE"
fi
[ -n "$EV_BLOCK" ] && PROMPT="$PROMPT"$'\n'"$EV_BLOCK"

# d. model row: a missing row refuses (exit 3) before anything is written
MODEL="$(awk -v r="$ROLE" '$1==r{print $2}' "$MRC" 2>/dev/null | head -1)"
if [ -z "$MODEL" ]; then echo "ALARM $SEAT: no '$ROLE' model row in $MRC" >&2; S_reason="no-model"; save; exit 3; fi

# e. ctl tick only: boundary marker. LAST precondition: every exit-3/exit-6 above has passed, so a refusal never leaves `boundary: open`
if [ "$SEAT" = ctl ] && [ "$KIND" = tick ]; then
  FLEET_STATUS_DIR="$DASH" FLEET_STATUS_SESSION="${FLEET_STATUS_SESSION:-seat-tick-ctl}" "$WRITER" --open </dev/null \
    || echo "seat-tick: WARN fleet-status-write.sh --open failed" >&2
fi

# f. auth (token mode, as seat-relaunch.sh) + run, capped at 95 % of timeout_sec so the script records its own exit before systemd's TimeoutStartSec
[ -r "$OAUTH_ENV" ] && { set -a; . "$OAUTH_ENV"; set +a; }
export WM_SEAT="$SEAT" CLAUDE_SESSION_NAME="$SEAT"      # SessionStart hooks (model-role-check.sh, seat-context-start.sh) read the seat from WM_SEAT
CAP=$(( TIMEOUT_SEC * 95 / 100 ))
[ "$S_chained" = 1 ] && { left=$(( TIMEOUT_SEC - ($(date +%s) - T0) - 30 )); [ "$left" -lt "$CAP" ] && CAP="$left"; }   # a chained turn must end before the unit's TimeoutStartSec
[ "$CAP" -ge 1 ] || CAP=1
LOG="$DASH/$SEAT-tick-last.log"; [ "$KIND" = ask ] && LOG="$DASH/$SEAT-ask-last.log"; [ "$KIND" = event ] && LOG="$DASH/$SEAT-event-last.log"
echo "seat-tick: $SEAT $KIND model=$MODEL sid=$SID cap=${CAP}s prompt='${PROMPT//$'\n'/ | }'"
start="$(date +%s)"
LEAN_ARGV=()
case "$ROLE" in   # rb/r7 only; ctl (and any other role) = default settings, full hook set
  rb|r7) for _kv in $LEAN_ENV_VARS; do export "$_kv"; done
         read -ra LEAN_ARGV <<<"${LEAN_FLAGS//\$HOME/$HOME}" ;;
  controller) if [ -r "$CTL_SETTINGS" ]; then LEAN_ARGV=(--settings "$CTL_SETTINGS"); else echo "seat-tick: WARN $CTL_SETTINGS missing, ctl runs without autoCompactEnabled=true" >&2; fi ;;
esac
( cd "$HOME" && exec timeout -k 30 "$CAP" "$CLAUDE_BIN" -p --dangerously-skip-permissions --model "$MODEL" "${LEAN_ARGV[@]}" --resume "$SID" "$PROMPT" ) 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
end="$(date +%s)"
echo "seat-tick: $SEAT $KIND exit=$rc duration=$((end - start))s"

now="$end"; iso="$(date -Iseconds)"
st="$(status)"; S_skipped="$(sget '.ticks_skipped // 0')"; S_sends="$(sget '.sends_total // 0')"   # re-read: nothing else writes under the lock, but be exact
S_exit="$rc"; S_dur=$((end - start)); S_kind="$KIND"
[ "$SEAT" = ctl ] && [ "$KIND" = tick ] && S_kind=sweep
if [ "$KIND" = tick ]; then S_sends=$((S_sends + 1)); S_last_sent="$start"; fi
S_evnew="$EV_NEW"
if [ "$rc" = 0 ]; then S_seen="$total"; S_skipped=0; S_reason=""; S_evoff="$NEW_EVOFF"; S_lastprompt="$start"; fi
save

# g. chain: a bell that arrived while this turn ran (a .wake file, or log bytes past the delivered offset) is handled now, not at the next 20-min tick.
# Exit-0 turns only (a failing claude must not loop), at most one chain per unit run (SEAT_TICK_CHAINED), and only while half the unit's time budget is left.
if [ "$rc" = 0 ] && [ "$S_chained" != 1 ]; then
  ev_size=0; [ -r "$EVF" ] && ev_size="$(stat -c %s "$EVF")"
  if [ -e "$WAKE" ] || [ "$ev_size" -gt "$S_evoff" ]; then
    rm -f "$WAKE"
    if [ $(( ($(date +%s) - T0) * 2 )) -lt "$TIMEOUT_SEC" ]; then
      echo "seat-tick: $SEAT chaining one EVENT turn (events past offset $S_evoff, log $ev_size bytes)"
      exec 9>&-   # release the seat lock: the chained run takes it again (a bell in this gap spawns its own EVENT unit, which defers harmlessly)
      exec env SEAT_TICK_CHAINED=1 SEAT_TICK_T0="$T0" "$SELF" "$SEAT" --event
    fi
  fi
fi
exit "$rc"
