#!/usr/bin/env bash
# ctl-sweep.sh: one fleet-controller turn as a daemon run (like wm-build): `claude -p --resume <controller SID> "<prompt>"`.
#   ctl-sweep.sh                 SWEEP turn (timer tick every 20 min)      prompt: SWEEP <time> <date> tick=<n> status_age=<N|none>m approvals_new=<k>
#   ctl-sweep.sh --ask "<text>"  ASK turn (Joe's fast path, see ctl-ask.sh) prompt: ASK <time> <date> approvals_new=<k>: <text>
#   ctl-sweep.sh --status        print ctl-tick.json
#   ctl-sweep.sh --guard-check   run only the interactive-controller guard (exit 0 clear / 4 refused), changes nothing
#   ctl-sweep.sh --selftest      fake claude only, never the real one
# Order: flock (serializes sweeps and asks; a tick that cannot get it exits 5) -> guard (exit 4 if the interactive controller
# still holds the session; never kills anything) -> compose prompt -> [SWEEP only: fleet-status-write.sh --open] -> claude -p.
# approvals_new = non-comment, non-blank lines in $APPROVALS_FILE beyond approvals_seen in ctl-tick.json (log is read-only here).
# Env overrides: FLEET_DASH_DIR CTL_SID MRC_TABLE APPROVALS_FILE CTL_CLAUDE_BIN CTL_OAUTH_ENV CTL_GUARD_PID CTL_LOCK_WAIT
set -u
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
DASH="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}"
SID="${CTL_SID:-de73e73c-5095-4d39-9703-1fc439e7236d}"
MRC="${MRC_TABLE:-$HOME/.claude/state/controller-model-required}"
APPROVALS="${APPROVALS_FILE:-$HOME/.claude/state/approvals.log}"
CLAUDE_BIN="${CTL_CLAUDE_BIN:-$HOME/.npm-global/bin/claude}"
OAUTH_ENV="${CTL_OAUTH_ENV:-$HOME/.config/environment.d/90-claude-oauth.conf}"
GUARD_PID="${CTL_GUARD_PID:-3845}"
# 1400 s, not the 1500 s of the spec: the unit's TimeoutStartSec is 1500, and a tick must record its exit-5 skip before systemd kills it
LOCK_WAIT="${CTL_LOCK_WAIT:-1400}"
STATE="$DASH/ctl-tick.json"
SFILE="$DASH/fleet-status.md"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
WRITER="$HERE/fleet-status-write.sh"
ALARM_AT=3

status() { cat "$STATE" 2>/dev/null || echo '{}'; }
count_approvals() { [ -r "$APPROVALS" ] && grep -cvE '^[[:space:]]*(#|$)' "$APPROVALS" || true; }

# guard: prints the reason and returns 1 if the interactive controller (or any claude holding this SID) is alive
guard() {
  local p cl
  if [ -n "$GUARD_PID" ] && [ -r "/proc/$GUARD_PID/cmdline" ]; then
    cl="$(tr '\0' ' ' <"/proc/$GUARD_PID/cmdline")"
    case "$cl" in *claude*) echo "pid $GUARD_PID alive: ${cl:0:80}"; return 1 ;; esac
  fi
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    cl="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)" || continue
    case "$cl" in *"$SID"*) ;; *) continue ;; esac
    # only a process whose own command is claude (or node running claude): not a shell that merely mentions the SID
    if [[ "$cl" =~ ^([^\ ]*/)?claude(\ |$) ]] || [[ "$cl" =~ ^([^\ ]*/)?node\ [^\ ]*claude ]]; then
      echo "pid ${p#/proc/} holds session $SID: ${cl:0:80}"; return 1
    fi
  done
  return 0
}

# ---- selftest -------------------------------------------------------------------------------------
ST_T=""; ST_PIDS=""
st_cleanup() { local p; for p in $ST_PIDS; do kill "$p" 2>/dev/null; done; [ -n "$ST_T" ] && rm -rf "$ST_T"; }
selftest() {
  local T fail=0 rc ts_re='[0-9]{1,2}:[0-9]{2} (AM|PM) [A-Za-z0-9+-]+ [0-9]{4}-[0-9]{2}-[0-9]{2}'
  T="$(mktemp -d)"; ST_T="$T"; trap st_cleanup EXIT
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  local SELFSID=selftest-sid-0000-1111
  export FLEET_DASH_DIR="$T/dash" CTL_SID="$SELFSID" MRC_TABLE="$T/mrc" APPROVALS_FILE="$T/approvals.log" \
         CTL_CLAUDE_BIN="$T/claude" CTL_OAUTH_ENV="$T/oauth.conf" CTL_GUARD_PID=999999999 CTL_LOCK_WAIT=1
  mkdir -p "$T/dash"
  printf 'controller test-model-1\nrb claude-opus-5-5\n' >"$MRC_TABLE"
  echo 'CLAUDE_CODE_OAUTH_TOKEN=fake-not-a-token' >"$CTL_OAUTH_ENV"
  printf '# c1\n# c2\n\nl1\nl2\nl3\n' >"$APPROVALS_FILE"
  cat >"$CTL_CLAUDE_BIN" <<'FAKE'
#!/bin/bash
echo "START $(date +%s.%N)"
echo "ARGV: $*"
echo "token_set=${CLAUDE_CODE_OAUTH_TOKEN:+yes} cwd=$PWD"
echo "seat_env=WM_SEAT=${WM_SEAT:-} CLAUDE_SESSION_NAME=${CLAUDE_SESSION_NAME:-}"
echo "status_line2=$(sed -n 2p "$FLEET_DASH_DIR/fleet-status.md" 2>/dev/null)"
sleep "${FAKE_SLEEP:-2}"
echo "END $(date +%s.%N)"
exit "${FAKE_EXIT:-0}"
FAKE
  chmod +x "$CTL_CLAUDE_BIN"
  j() { jq -r "$1" "$T/dash/ctl-tick.json"; }

  # 1. SWEEP #1: no status file yet, 3 approvals pending
  "$SELF" >"$T/o1" 2>"$T/e1"; rc=$?
  [ "$rc" = 0 ]; chk "sweep 1: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-1 --resume $SELFSID SWEEP $ts_re tick=1 status_age=none approvals_new=3\$" "$T/o1"; chk "sweep 1: argv/prompt '$(grep -m1 ^ARGV "$T/o1" | cut -c1-200)'" $?
  grep -q "model test-model-1" "$T/o1"; chk "model comes from MRC_TABLE controller row" $?
  grep -q "token_set=yes cwd=$HOME\$" "$T/o1"; chk "oauth env sourced (token present, value not shown), cwd=\$HOME" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl$' "$T/o1"; chk "SWEEP: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
  grep -q '^status_line2=boundary: open$' "$T/o1"; chk "SWEEP wrote 'boundary: open' before claude ran" $?
  grep -q '^ARGV:' "$T/dash/ctl-sweep-last.log"; chk "ctl-sweep-last.log holds the run output" $?
  [ "$(j .sends_total)" = 1 ] && [ "$(j .last_exit)" = 0 ] && [ "$(j .last_prompt_kind)" = sweep ] && [ "$(j .ticks_skipped)" = 0 ] && [ "$(j .approvals_seen)" = 3 ] && [ "$(j .last_duration_s)" -ge 2 ] && [ "$(j .last_sent)" -gt 0 ]; chk "state: sends_total=1 last_exit=0 kind=sweep approvals_seen=3 duration=$(j .last_duration_s)s" $?

  # 2. SWEEP #2: status file 7 min old, 2 new approvals
  touch -d '7 minutes ago' "$T/dash/fleet-status.md"
  printf 'l4\nl5\n# comment\n' >>"$APPROVALS_FILE"
  "$SELF" >"$T/o2" 2>"$T/e2"
  grep -Eq "SWEEP $ts_re tick=2 status_age=7m approvals_new=2\$" "$T/o2"; chk "sweep 2: status_age + approvals_new in prompt: '$(grep -o 'SWEEP.*' "$T/o2" | head -1)'" $?
  [ "$(j .sends_total)" = 2 ] && [ "$(j .approvals_seen)" = 5 ]; chk "sweep 2: sends_total=2 approvals_seen=5" $?

  # 3. ASK: no --open, model table re-read, ask log, sends_total unchanged
  rm -f "$T/dash/fleet-status.md"; printf 'controller test-model-2\n' >"$MRC_TABLE"
  "$SELF" --ask "what is rb doing?" >"$T/o3" 2>"$T/e3"; rc=$?
  [ "$rc" = 0 ]; chk "ask: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-2 --resume $SELFSID ASK $ts_re approvals_new=0: what is rb doing\?\$" "$T/o3"; chk "ask: prompt '$(grep -m1 ^ARGV "$T/o3" | cut -c1-200)'" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl$' "$T/o3"; chk "ASK: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
  [ ! -e "$T/dash/fleet-status.md" ]; chk "ASK did not write the boundary marker (SWEEP only)" $?
  [ -s "$T/dash/ctl-ask-last.log" ]; chk "ctl-ask-last.log written" $?
  [ "$(j .last_prompt_kind)" = ask ] && [ "$(j .sends_total)" = 2 ] && [ "$(j .last_exit)" = 0 ]; chk "ask: kind=ask, sends_total stays 2" $?

  # 4. exit code recorded
  FAKE_SLEEP=0 FAKE_EXIT=7 "$SELF" >"$T/o4" 2>"$T/e4"; rc=$?
  [ "$rc" = 7 ] && [ "$(j .last_exit)" = 7 ] && [ "$(j .approvals_seen)" = 5 ]; chk "claude exit 7: script exits 7, last_exit=7, approvals_seen not advanced" $?

  # 5. lock serialization: A (sweep, 2 s) running, B (ask) must wait for A's END
  CTL_LOCK_WAIT=30 "$SELF" >"$T/oA" 2>&1 & ST_PIDS="$ST_PIDS $!"; local pa=$!
  sleep 0.7
  CTL_LOCK_WAIT=30 "$SELF" --ask second >"$T/oB" 2>&1 & ST_PIDS="$ST_PIDS $!"; local pb=$!
  wait "$pa" "$pb"
  local aend bstart
  aend="$(awk '/^END/{print $2}' "$T/oA")"; bstart="$(awk '/^START/{print $2}' "$T/oB")"
  awk -v e="$aend" -v s="$bstart" 'BEGIN{exit !(s+0 >= e+0 && e != "" && s != "")}'; chk "lock: second run started ($bstart) after first ended ($aend)" $?

  # 6. lock timeout: a held lock -> exit 5, ticks_skipped counts, ALARM at 3, success resets
  ( exec 8>"$T/dash/ctl.lock"; flock 8; sleep 8 ) & ST_PIDS="$ST_PIDS $!"; local ph=$!
  sleep 0.4
  local i
  for i in 1 2 3; do "$SELF" >"$T/o6$i" 2>"$T/e6$i"; rc=$?; [ "$rc" = 5 ] || break; done
  [ "$rc" = 5 ] && [ "$(j .ticks_skipped)" = 3 ] && [ "$(j .last_skip_reason)" = lock-busy ]; chk "lock busy x3: exit 5, ticks_skipped=3, reason=$(j .last_skip_reason)" $?
  ! grep -q ALARM "$T/e61" "$T/e62"; chk "no ALARM before the 3rd skip" $?
  grep -q 'ALARM ctl sweep skipped 3 ticks' "$T/e63"; chk "ALARM on stderr at ticks_skipped>=3: '$(grep ALARM "$T/e63")'" $?
  "$SELF" --ask while-locked >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(j .ticks_skipped)" = 3 ]; chk "ask that cannot lock: exit 5, ticks_skipped unchanged" $?
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(j .ticks_skipped)" = 0 ]; chk "next successful run resets ticks_skipped to 0" $?

  # 7. guard: a process shaped like the interactive controller holding the SID
  local runs_before; runs_before="$(j .sends_total)"
  bash -c "exec -a 'claude --resume $SELFSID' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pg=$!
  sleep 0.4
  "$SELF" >"$T/o7" 2>"$T/e7"; rc=$?
  [ "$rc" = 4 ] && grep -q 'ALARM ctl guard' "$T/e7" && [ "$(j .sends_total)" = "$runs_before" ] && ! grep -q '^ARGV' "$T/o7"; chk "guard: process 'claude --resume <SID>' -> exit 4, ALARM, claude not run ('$(grep ALARM "$T/e7" | cut -c1-140)')" $?
  [[ "$(j .last_skip_reason)" == guard:* ]]; chk "guard: last_skip_reason=$(j .last_skip_reason | cut -c1-60)" $?
  "$SELF" --guard-check >/dev/null 2>&1; [ $? = 4 ]; chk "--guard-check: exit 4 while it is alive" $?
  kill "$pg"; wait "$pg" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" >/dev/null 2>&1; [ $? = 0 ]; chk "guard clear after the fake exits: runs" $?
  bash -c "exec -a claude python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pq=$!
  sleep 0.4
  CTL_GUARD_PID=$pq "$SELF" >/dev/null 2>"$T/e7b"; rc=$?
  [ "$rc" = 4 ] && grep -q "pid $pq alive" "$T/e7b"; chk "guard: CTL_GUARD_PID alive with 'claude' in cmdline -> exit 4" $?
  kill "$pq"; wait "$pq" 2>/dev/null
  CTL_GUARD_PID=$$ FAKE_SLEEP=0 "$SELF" >/dev/null 2>&1; [ $? = 0 ]; chk "guard: CTL_GUARD_PID alive but cmdline without 'claude' -> not refused" $?
  bash -c "sleep 20; : $SELFSID claude" & ST_PIDS="$ST_PIDS $!"; local pm=$!
  sleep 0.3
  FAKE_SLEEP=0 "$SELF" >/dev/null 2>&1; [ $? = 0 ]; chk "guard: a shell that merely mentions the SID is not a holder" $?
  kill "$pm" 2>/dev/null

  # 8. wiring
  grep -q 'de73e73c-5095-4d39-9703-1fc439e7236d' "$SELF" && grep -q 'GUARD_PID="${CTL_GUARD_PID:-3845}"' "$SELF"; chk "defaults: SID de73e73c-..., guard pid 3845" $?
  out="$(CTL_ASK_DRY=1 "$HERE/ctl-ask.sh" "hello there" 2>&1)"
  [[ "$out" == *"systemd-run --user --collect --unit ctl-ask-"*"ctl-sweep.sh --ask hello there"* ]]; chk "ctl-ask.sh (dry): '${out:0:150}'" $?
  "$SELF" --status | jq -e 'has("last_tick") and has("last_sent") and has("ticks_skipped") and has("last_skip_reason") and has("sends_total") and has("last_exit") and has("last_duration_s") and has("last_prompt_kind") and has("status_file") and has("approvals_seen")' >/dev/null; chk "--status prints state JSON with all keys" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --selftest) selftest; exit $? ;;
  --guard-check) why="$(guard)" && { echo "guard: clear"; exit 0; }; echo "guard: REFUSED $why" >&2; exit 4 ;;
  --ask) [ -n "${2:-}" ] || { echo "usage: ctl-sweep.sh --ask \"<text>\"" >&2; exit 64; }; KIND=ask; ASK_TEXT="$2" ;;
  "") KIND=sweep; ASK_TEXT="" ;;
  *) echo "usage: ctl-sweep.sh [--ask \"<text>\"|--status|--guard-check|--selftest]" >&2; exit 64 ;;
esac

# ---- one turn -------------------------------------------------------------------------------------
mkdir -p "$DASH" || exit 1
now="$(date +%s)"
iso="$(date -Iseconds)"

# state: every field kept across runs; writes are tmp+mv
st="$(status)"
sget() { jq -r "$1" <<<"$st" 2>/dev/null; }
S_last_sent="$(sget '.last_sent // 0')"; S_skipped="$(sget '.ticks_skipped // 0')"; S_sends="$(sget '.sends_total // 0')"
S_reason="$(sget '.last_skip_reason // ""')"; S_seen="$(sget '.approvals_seen // 0')"; S_exit="$(sget '.last_exit // null')"
S_dur="$(sget '.last_duration_s // null')"; S_kind="$(sget '.last_prompt_kind // ""')"
save() {   # reads the S_* variables
  local tmp; tmp="$(mktemp "$DASH/.ctl-tick.XXXXXX")" || return 1
  jq -n --arg iso "$iso" --argjson ep "$now" --argjson ls "$S_last_sent" --argjson sk "$S_skipped" --arg why "$S_reason" \
        --argjson sn "$S_sends" --argjson as "$S_seen" --argjson ex "$S_exit" --argjson du "$S_dur" --arg kind "$S_kind" --arg sf "$SFILE" \
    '{last_tick:{iso:$iso,epoch:$ep}, last_sent:$ls, ticks_skipped:$sk, last_skip_reason:(if $why=="" then null else $why end),
      sends_total:$sn, last_exit:$ex, last_duration_s:$du, last_prompt_kind:(if $kind=="" then null else $kind end),
      status_file:$sf, approvals_seen:$as}' >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
}

# a. the lock serializes sweeps and asks: two processes never share the session
exec 9>"$DASH/ctl.lock"
if ! flock -w "$LOCK_WAIT" 9; then
  echo "ctl-sweep: lock busy after ${LOCK_WAIT}s, kind=$KIND" >&2
  if [ "$KIND" = sweep ]; then
    S_skipped=$((S_skipped + 1)); S_reason="lock-busy"; save
    [ "$S_skipped" -ge "$ALARM_AT" ] && echo "ALARM ctl sweep skipped $S_skipped ticks (lock busy)" >&2
  fi
  exit 5
fi

# b. guard: the interactive controller still owns the session; never kill, refuse loudly
if why="$(guard)"; then :; else
  echo "ALARM ctl guard: interactive controller still running, refusing to resume the session ($why)" >&2
  S_reason="guard:${why:0:100}"; save; exit 4
fi

# c. prompt
total="$(count_approvals)"; total="${total:-0}"
new=$(( total - S_seen )); [ "$new" -lt 0 ] && new="$total"      # log shrank (rotated): count it all
stamp="$(date '+%-I:%M %p %Z') $(date +%Y-%m-%d)"
if [ "$KIND" = ask ]; then
  PROMPT="ASK $stamp approvals_new=$new: $ASK_TEXT"
else
  n=$((S_sends + 1))
  if [ -e "$SFILE" ]; then age="$(( (now - $(stat -c %Y "$SFILE")) / 60 ))m"; else age="none"; fi
  PROMPT="SWEEP $stamp tick=$n status_age=$age approvals_new=$new"
fi

# d. SWEEP only: boundary marker
if [ "$KIND" = sweep ]; then
  FLEET_STATUS_DIR="$DASH" FLEET_STATUS_SESSION="${FLEET_STATUS_SESSION:-ctl-sweep}" "$WRITER" --open </dev/null \
    || echo "ctl-sweep: WARN fleet-status-write.sh --open failed" >&2
fi

# e. auth (token mode, as seat-relaunch.sh) + run
MODEL="$(awk '$1=="controller"{print $2}' "$MRC" 2>/dev/null | head -1)"
if [ -z "$MODEL" ]; then echo "ALARM ctl: no controller model in $MRC" >&2; S_reason="no-model"; save; exit 3; fi
[ -r "$OAUTH_ENV" ] && { set -a; . "$OAUTH_ENV"; set +a; }
export WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl      # SessionStart hooks (model-role-check.sh, seat-context-start.sh) read the seat from WM_SEAT
LOG="$DASH/ctl-sweep-last.log"; [ "$KIND" = ask ] && LOG="$DASH/ctl-ask-last.log"
echo "ctl-sweep: $KIND model=$MODEL sid=$SID prompt='$PROMPT'"
start="$(date +%s)"
( cd "$HOME" && exec "$CLAUDE_BIN" -p --dangerously-skip-permissions --model "$MODEL" --resume "$SID" "$PROMPT" ) 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
end="$(date +%s)"
echo "ctl-sweep: $KIND exit=$rc duration=$((end - start))s"

now="$end"; iso="$(date -Iseconds)"
st="$(status)"; S_skipped="$(sget '.ticks_skipped // 0')"; S_sends="$(sget '.sends_total // 0')"   # re-read: nothing else writes under the lock, but be exact
S_exit="$rc"; S_dur=$((end - start)); S_kind="$KIND"
if [ "$KIND" = sweep ]; then S_sends=$((S_sends + 1)); S_last_sent="$start"; fi
if [ "$rc" = 0 ]; then S_seen="$total"; S_skipped=0; S_reason=""; fi
save
exit "$rc"
