#!/usr/bin/env bash
# seat-tick.sh: one operator-seat turn as a daemon run (like wm-build): `claude -p --resume <seat SID> "<prompt>"`.
# ctl-sweep.sh generalized: ONE script, one row per seat in ~/.claude/state/seats.tsv (seat role sid tick_min timeout_sec goal_pattern old_pid max_turns).
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
# QUOTA-WAIT (10-22): a turn that exits non-zero AND whose output tail matches `hit your (session|usage|weekly) limit` or carries a reset text the shared parser reads is the plan's usage limit, not a
# failure nobody can act on (10-22 5:58-7:00 PM: six SEAT-TICK FAILED bells, one per 20-min tick). 10-23: the reset text goes through fleet-token-lib.sh ft_parse_la_date (the ONE parser, weekly
# "resets Oct 26, 9pm" and session "resets 7:10pm"; ALWAYS America/Los_Angeles, a tz in parens is ignored; seat-tick has no reset regex of its own, tests/seat-tick-weekly-quota.test.sh pins that)
# into quota_wait_until (epoch; no cap on its length, a weekly wait is days), quota_kind (weekly | session | unknown; the "hit your <kind> limit" word, else a wait <= 24 h = session, further out = weekly),
# and sets last_skip_reason=quota-wait:<iso|unknown>, does NOT count a skip, prints
# `seat-tick: <seat> quota-wait until <time> (session limit) kind=session` and exits 0 (the unit does not fail, no bell). While now < quota_wait_until every tick/event/ask exits 0 right after the
# lock ("quota-wait in effect until <time>"), claude not launched, events_offset and the unread events untouched (the first turn after the wait delivers them; an ASK is QUEUED, see ASK-QUEUE).
# COVERED STAMP (10-22): a lock-covered tick (below) leaves last_exit/last_duration_s at the last real turn's values (the running turn is not over), so it also stamps last_covered_at (ISO local, like last_tick.iso) and last_covered_by (`<kind>:<pid>`); null until the first covered tick.
# The first exit-0 turn clears quota_wait_until and the reason. A real exit 1 with no limit line stays a failure.
# QUOTA-ACCOUNT (10-23, fleet-token rotation): when it records quota_wait_until it also records quota_account = the `account` in $FLEET_DASH_DIR/token.json (null when that file is absent).
# A wait recorded under another account is not the current account's wait: whenever token.json exists with an account != quota_account (null counts as different), the wait is IGNORED
# (treated as expired; the turn runs and the keys clear: quota_wait_until, quota_kind, quota_account, quota_parse_*). A missing or unreadable token.json ignores nothing. fleet-token-429-watch.sh reads
# quota_wait_until + quota_account and blocks THAT account. After a rotation fleet-token-rotate.sh starts the seat units; seat-tick is a Type=oneshot unit, so the next tick is a fresh process that sources
# $OAUTH_ENV (the placed token) before every claude launch: no restart is needed for the next tick (a turn already running keeps the old token until it ends; stop it by unit name, never pkill).
# QUOTA-PARSE-FAILED (10-23): limit text present but ft_parse_la_date gives no date -> the old fallback stays (quota_wait_until null, reason quota-wait:unknown, the next tick retries) AND
# quota_parse_failed=true + quota_parse_text (the limit line, first 120 chars) are written, plus one `ALARM fleet-token:` line in ctl-events.log (ft_alarm). Both clear at the next exit-0 turn or a rotation.
# MAX-TURNS (10-23; 10-22 12:00 AM -> 10-23 11:20 AM the rb/r7 seats' own Opus turns were 121M weighted tokens + 141M in-session subagents vs 22M for the PRD coders; a tick turn had no bound:
# median 19-21 assistant messages, p90 71-136, max 1857): seats.tsv column 8 `max_turns` (integer >= 1, or `-` = no cap; a 7-column row = no cap) appends `--max-turns <N>` to the claude argv of EVERY
# turn kind (TICK/SWEEP/EVENT/ASK), after `--model <m>` and before the lean/--settings block. MEASURED (claude 2.1.293, `claude -p --max-turns 1`): a capped turn prints `Error: Reached max turns (<N>)` on stdout
# (no trailing newline, stderr empty) and exits 1 (`--output-format json`: subtype=error_max_turns, terminal_reason=max_turns, is_error=true). That is a NORMAL turn end here: when rc != 0 and the LAST non-empty
# line of the turn log is exactly that marker, the turn is recorded as exit 0 (events_offset advances, no SEAT-TICK FAILED bell, last_skip_reason untouched, queued asks stay consumed, the exit-0 EVENT chain still runs),
# max_turns_hits (count, kept across runs) increments in <seat>-tick.json, and stderr says `seat-tick: <seat> max-turns <N> reached`. Any other non-zero exit is unchanged.
# State keys: max_turns_hits last_covered_at last_covered_by stop_hook_bounces stop_hook_lines_before asks_pending (count at the save) seat last_tick last_sent ticks_skipped last_skip_reason sends_total last_exit last_duration_s last_prompt_kind status_file approvals_seen guard_since events_offset last_prompt events_new chained quota_wait_until quota_account quota_kind quota_parse_failed quota_parse_text.
# Order: flock (serializes ticks and asks per seat) -> guard (exit 4 if the interactive seat still holds the session; never kills
# anything) -> compose prompt -> model row (exit 3) -> [ctl tick only: fleet-status-write.sh --open, after every precondition] -> claude -p under `timeout` (95 % of timeout_sec).
# LOCK: a tick that cannot lock within 60 s exits 5 and counts a skip (3 in a row = ALARM line); an ASK waits up to 20 s instead (was 1800 s until 10-24), then is QUEUED (exit 0), never dropped;
# the running turn gets the queue at its next tool call or at its Stop (.claude/hooks/seat-ask-inject.sh, five-whys 10-24: rb waited on a CONFIRM queued behind its own turn).
# ASK-QUEUE (10-22 8:40 PM; rb's tick held the lock past 1800 s and four rulings died "lock busy after 1800s, kind=ask" exit 5): an ASK that cannot take the lock within its wait, or that
# arrives during quota-wait, is appended as one JSON record {ts, from (EVENT_SOURCE else "ask"), text} to <seat>-asks.pending (0600, under <seat>-asks.lock), an
# `ASK-QUEUED <seat> <ts>: <first 120 chars>` line goes into <seat>-events.log (source ask-queue; written directly, seat-event.sh is not called), <seat>.wake is touched (the running turn
# chains one EVENT turn at its end), stderr says `seat-tick: <seat> ask queued (lock busy <N>s | quota-wait until <time>): <first 80 chars>`, and the ask exits 0 (= accepted-or-queued).
# EVERY prompt build (TICK/SWEEP/EVENT/ASK) drains the queue: a non-empty file adds an `ASKS (queued while busy):` block (`- <ts> (from <src>): <text>`, oldest first) after the EVENTS block; the
# live ask text of a kind=ask turn stays in the first prompt line. The bytes shown are moved to <seat>-asks.pending.consumed-<epoch> only after the pre-turn state save succeeded and the claude
# binary resolves (asks queued since the snapshot stay); a turn that then exits non-zero (or aborts) puts the consumed records back at the head of the queue. An EVENT turn with no new
# events but queued asks still runs. `--status` shows asks_pending (live count; the state file carries the count of its last save).
# Not queued: an ASK refused by the guard (exit 4) or the goal-line check (exit 6) still fails loudly for the caller. When the running turn is itself the chained EVENT turn it does not chain again:
# the queue then waits for the next timer tick.
# LOCK-COVERED (10-22): whoever holds the lock writes `<kind> <pid> <epoch>` to <seat>.lock.holder. A timer tick that times out while that holder is a live
# EVENT or ASK turn of the SAME seat (pid alive, cmdline `seat-tick.sh <seat> --event|--ask`) is covered: last_skip_reason=lock-covered:<kind>:<pid>,
# ticks_skipped NOT incremented, <seat>.wake touched (the running turn chains one EVENT turn), exit 0. Any other holder (tick, foreign, stale, dead) = exit 5 + a skip.
# GUARD (10-22): refuses only an interactive holder: old_pid alive with `claude` in its cmdline and NOT print-mode (-p/--print), or a claude/node process holding
# the SID that is not a print-mode turn of a seat-tick@/seat-event-/seat-ask- unit (its cgroup). A dead old_pid is a clear (the note says so). The reason names the pid found.
# STATE (10-22): the reason + guard_since of an earlier refusal are cleared at the PRE-turn save (every kind): the guard passed, so a long turn must not show a stale refusal.
# A /goal registered in the session persists across --resume and its stop-hook judge bounces -p turns; the per-turn `stop_hook_bounces` counter below detects it (fix = `/goal clear` in that session under the seat lock).
# STOP-HOOK COUNTER (10-22; rb's session JSONL held 253 `Stop hook` lines and one tick ran 8720 s): the pre-turn save records stop_hook_lines_before = `grep -cE '"(text|content)":"Stop hook feedback:'` of ~/.claude/projects/-home-jsy/<sid>.jsonl (0 when absent), the end-of-turn save writes stop_hook_bounces = after - before
# STRICT (10-24): only a user message whose text/content STARTS with `Stop hook feedback:` is a bounce. The loose `grep -c 'Stop hook'` counted any line that merely mentioned Stop hooks (assistant text, tool results): false positive 10-24 6:50 PM, ctl bounces=4 with no goal set (`/goal clear` -> "No goal set");
# measured on live sessions strict/loose: rb 106/255, r7 43/189, ctl 0/40.
# (integer; null until the first measurement; stop_hook_lines_before beside it). > 0 prints `ALARM <seat> stop-hook bounces=<n> (...)` on stderr and appends it to <seat>-events.log (source stop-hook, no wake); exit code, turn and retries untouched, only the exit-0 EVENT chain is skipped (a chained turn would bounce again; the line waits for the next tick).
# approvals_new / status_age exist for ctl only (log is read-only here; approvals_seen in ctl-tick.json is the high-water mark).
# LEAN (10-22): seats whose ROLE is rb or r7 run the same lean overlay seat-relaunch.sh gives their interactive launch (env LEAN_ENV_VARS +
# flags LEAN_FLAGS from seat-lean.sh, flags placed before --resume). ctl stays on the default settings with the full hook set, by design;
# its only flag is --settings ~/.config/claude-seat/ctl-settings.json ({env: CLAUDE_CODE_AUTO_COMPACT_WINDOW 360000 + CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 50, autoCompactEnabled: true, autoCompactWindow: auto} = seats compact at 180K; ~/.claude/settings.local.json runs the aide at 1000000×50 % = 500K for $HOME and the --settings layer beats it; rb/r7 get the same pin from claude-seat/settings.json).
# Env overrides: SEAT_TICK_SELFTEST+SEAT_GUARD_CGROUP_OVERRIDE (selftest only: fake cgroup text for the guard) SEAT_TICK_SELFTEST+SEAT_GUARD_TTY_OVERRIDE=<pid>:<0|1>[,...] (selftest only: fake 'has a tty' per pid) SEATS_TABLE_REAL (selftest invariant: the real table, read-only) SEAT_TICK_SELFTEST+SEAT_NOW_EPOCH (selftest only: fake clock for the quota-wait) SEAT_TICK_SELFTEST+SEAT_JSONL_DIR (selftest only: fake session JSONL dir, default $HOME/.claude/projects/-home-jsy) SEAT_TICK_CHAINED SEAT_TICK_T0 (chain plumbing, set by this script) FLEET_DASH_DIR SEATS_TABLE MRC_TABLE GOAL_MD APPROVALS_FILE SEAT_CLAUDE_BIN SEAT_OAUTH_ENV SEAT_LOCK_WAIT SEAT_ASK_LOCK_WAIT SEAT_UNIT_DIR EVENT_SOURCE (the `from` of a queued ask)
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
ASK_LOCK_WAIT="${SEAT_ASK_LOCK_WAIT:-20}"
UNIT_DIR="${SEAT_UNIT_DIR:-$HOME/.config/systemd/user}"
CTL_SETTINGS="${SEAT_CTL_SETTINGS:-$HOME/.config/claude-seat/ctl-settings.json}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
WRITER="$HERE/fleet-status-write.sh"
. "$HERE/seat-lean.sh"   # LEAN_ENV_VARS + LEAN_FLAGS: ONE source with seat-relaunch.sh (10-22)
. "$HERE/../lib/fleet-token-lib.sh"   # ft_parse_la_date + ft_limit_line/ft_limit_word + ft_alarm: the ONE limit-text parser (10-23); seat-tick keeps no reset regex of its own
ft_paths
ALARM_AT=3
JSONL_DIR="$HOME/.claude/projects/-home-jsy"   # session JSONLs of the seats (cwd $HOME); the override is honoured only in selftest mode
[ "${SEAT_TICK_SELFTEST:-}" = 1 ] && [ -n "${SEAT_JSONL_DIR:-}" ] && JSONL_DIR="$SEAT_JSONL_DIR"
EVENT_RULE='every EVENT line gets a read and, if real, a mitigation this turn; log a DECISION row for each action'
RULES_LINE='Rules of this shape: one sweep toward the goal per tick; every DECISION is a wm-decide ledger row the same turn; wake the controller with ctl-ask.sh "<text>"; any background process you need outlives this turn only as a systemd-run --user unit with premise + expiry; '"$EVENT_RULE"'; this turn ends when you print the timestamped STATUS block.'
EV_MAX=40   # event lines shown in one prompt

# EXIT trap, armed right after the pre-turn state save: any exit before the tail's own save (an unset variable, a signal, a failed command) still
# records last_exit and keeps the already-incremented tick count (10-22 4:00 PM: a crash in the tail lost the count and the next tick restarted at 1).
on_exit() {
  local c=$?
  [ "${TURN_DONE:-1}" = 1 ] && return 0
  trap - EXIT
  S_exit="$c"; [ "$c" = 0 ] && S_exit="${TURN_RC:-1}"; [ "$S_exit" = 0 ] && S_exit=1   # a signal exit reaches the trap with $?=0
  now="$(date +%s)"; iso="$(date -Iseconds)"; S_dur=$(( now - ${start:-$now} )); S_evnew="${EV_NEW:-0}"
  [ "${TURN_RC:-}" = 0 ] || asks_restore 2>/dev/null   # an aborted turn never answered the queued asks it carried
  save 2>/dev/null
  echo "seat-tick: ${SEAT:-?} ${KIND:-?} ABORTED before the end-of-turn save (exit=$S_exit); state recorded" >&2
}

usage() { echo 'usage: seat-tick.sh <seat> [--ask "<text>" | --event | --status | --guard-check]   |   seat-tick.sh --selftest' >&2; exit 64; }

# seat row from the table; sets ROLE SID TICK_MIN TIMEOUT_SEC GOAL_RE OLD_PID MAX_TURNS (numeric, or empty = no cap: `-`, absent 8th column, or junk with a WARN) or returns 1
load_seat() {
  local row
  row="$(awk -F'\t' -v s="$1" '!/^[[:space:]]*(#|$)/ && $1==s {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8; exit}' "$SEATS" 2>/dev/null)"
  [ -n "$row" ] || return 1
  MAX_TURNS=""
  IFS=$'\t' read -r ROLE SID TICK_MIN TIMEOUT_SEC GOAL_RE OLD_PID MAX_TURNS <<<"$row"
  case "${MAX_TURNS:-}" in
    ""|-) MAX_TURNS="" ;;
    *[!0-9]*|0*) echo "seat-tick: WARN $1 max_turns '$MAX_TURNS' is not an integer >= 1 (or -): no cap" >&2; MAX_TURNS="" ;;
  esac
  [ -n "$SID" ] && [ -n "${OLD_PID:-}" ]
}

# max_turns_hit <log>: 0 if the LAST non-empty line of a failed turn's output is claude's max-turns marker `Error: Reached max turns (<N>)`; prints N (measured: claude -p prints only that line, exit 1)
max_turns_hit() { local l; l="$(tail -c 2048 "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n1 | tr -d '\r')"; [[ "$l" =~ ^Error:\ Reached\ max\ turns\ \(([0-9]+)\)$ ]] && echo "${BASH_REMATCH[1]}"; }

# print-mode claude (`claude -p ...` / --print) is a headless turn, never the interactive seat
is_print_mode() { case " $1 " in *" -p "*|*" --print "*) return 0 ;; esac; return 1; }

# a cgroup naming a seat unit (seat-tick@<seat>.service, seat-event-<seat>-*, seat-ask-<seat>-*): the legitimate holder of the SID is that unit's own turn
in_seat_unit() {   # in_seat_unit <pid>
  local cg
  if [ "${SEAT_TICK_SELFTEST:-}" = 1 ] && [ -n "${SEAT_GUARD_CGROUP_OVERRIDE:-}" ]; then cg="$SEAT_GUARD_CGROUP_OVERRIDE"; else cg="$(cat "/proc/$1/cgroup" 2>/dev/null)"; fi
  case "$cg" in *seat-tick@*|*seat-event-*|*seat-ask-*) return 0 ;; esac
  return 1
}

# field <n> of a /proc/<pid>/stat line counted AFTER the comm (2=ppid 3=pgrp 4=session 5=tty_nr, i.e. stat fields 4,5,6,7; the state letter at 1 is not numeric). The comm may hold spaces and
# parentheses, so cut at the LAST ') ' and never split the front. Prints nothing and returns 1 on a malformed line.
stat_after_comm() {   # stat_after_comm <line> <n>
  local rest="${1##*) }" f
  [ "$rest" != "$1" ] || return 1
  read -ra f <<<"$rest"
  [[ "${f[$(( $2 - 1 ))]:-}" =~ ^-?[0-9]+$ ]] || return 1
  echo "${f[$(( $2 - 1 ))]}"
}

# an INTERACTIVE seat lives in a tmux pane (a pty, so a controlling tty) or has a tmux ancestor; a claude with neither (a decoy from a plain user-session
# cgroup, 10-22 night) is not one. Selftest hook: SEAT_GUARD_TTY_OVERRIDE=<pid>:<0|1>[,<pid>:<0|1>...] decides for the listed pids, honoured only under SEAT_TICK_SELFTEST=1.
has_tty_or_tmux() {   # has_tty_or_tmux <pid>: 0 = tty (tty_nr != 0) or tmux ancestor, 1 = neither (or the process is gone)
  local pid="$1" o ov st tty cur pp n=0
  if [ "${SEAT_TICK_SELFTEST:-}" = 1 ] && [ -n "${SEAT_GUARD_TTY_OVERRIDE:-}" ]; then
    IFS=, read -ra ov <<<"$SEAT_GUARD_TTY_OVERRIDE"
    for o in "${ov[@]}"; do [ "${o%%:*}" = "$pid" ] && { [ "${o#*:}" = 1 ]; return; }; done
  fi
  st="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  tty="$(stat_after_comm "$st" 5)" || return 1
  [ "$tty" != 0 ] && return 0
  cur="$pid"
  while [ "$n" -lt 64 ]; do
    n=$(( n + 1 ))
    st="$(cat "/proc/$cur/stat" 2>/dev/null)" || return 1
    pp="$(stat_after_comm "$st" 2)" || return 1
    [ "$pp" -gt 1 ] 2>/dev/null || return 1
    case "$(cat "/proc/$pp/comm" 2>/dev/null)" in tmux|tmux:*) return 0 ;; esac
    cur="$pp"
  done
  return 1
}

# guard: returns 1 and prints the reason (with the pid it actually found) if the INTERACTIVE seat is alive; returns 0 and prints a note otherwise.
# Interactive = claude (not print-mode) WITH a controlling tty or a tmux ancestor. A non-print claude holding the SID with neither is noted and ignored.
guard() {
  local p pid cl comm notes="" old_noted=""
  if [ "$OLD_PID" != "-" ]; then
    if [ -r "/proc/$OLD_PID/cmdline" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      cl="$(tr '\0' ' ' <"/proc/$OLD_PID/cmdline")"
      case "$cl" in
        *claude*) if is_print_mode "$cl"; then notes="old_pid $OLD_PID is a print-mode claude (not the interactive seat)"
                  elif has_tty_or_tmux "$OLD_PID"; then echo "pid $OLD_PID alive: ${cl:0:80}"; return 1
                  else notes="old_pid $OLD_PID alive without a tty: not an interactive seat, ignored"; old_noted=1; fi ;;
        *) notes="old_pid $OLD_PID alive but not claude" ;;
      esac
    else notes="old_pid $OLD_PID not alive"; fi
  fi
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    cl="$(tr '\0' ' ' 2>/dev/null <"$p/cmdline")" || continue
    case "$cl" in *"$SID"*) ;; *) continue ;; esac
    comm="$(cat "$p/comm" 2>/dev/null)"
    # only a process whose own command is claude (or node running claude): not a shell that merely mentions the SID
    if [ "$comm" = claude ] || [ "$comm" = node ] || [[ "$cl" =~ ^([^\ ]*/)?claude(\ |$) ]] || [[ "$cl" =~ ^([^\ ]*/)?node\ [^\ ]*claude ]]; then
      # a print-mode turn of a seat unit (this very tick's unit, or an event/ask/chained turn) holds the SID legitimately: not the interactive seat
      pid="${p#/proc/}"
      if is_print_mode "$cl" && in_seat_unit "$pid"; then notes="${notes:+$notes; }pid $pid is a seat-unit print-mode turn (ignored)"; continue; fi
      # a non-print claude is the interactive seat only with a tty / tmux ancestor; a print-mode holder outside a seat unit (a hand-run turn) still refuses
      if ! is_print_mode "$cl"; then
        [ -e "$p/stat" ] || continue   # exited since the cmdline read
        if ! has_tty_or_tmux "$pid"; then
          [ -n "$old_noted" ] && [ "$pid" = "$OLD_PID" ] || notes="${notes:+$notes; }pid $pid holds the SID without a tty: not an interactive seat, ignored"
          continue
        fi
      fi
      echo "pid $pid holds session $SID: ${cl:0:80}"; return 1
    fi
  done
  echo "${notes:-no holder}"
  return 0
}

# the lock holder's identity, written under the lock (atomic): kind pid epoch
note_holder() { printf '%s %s %s\n' "$KIND" "$$" "$(date +%s)" >"$HOLDER.$$" && mv -f "$HOLDER.$$" "$HOLDER"; }
# holder_covers: 0 (and prints "<kind>:<pid>") if the recorded holder is a LIVE event or ask turn of this seat
holder_covers() {
  local hk hp cl
  read -r hk hp _ 2>/dev/null <"$HOLDER" || return 1
  case "$hk" in event|ask) ;; *) return 1 ;; esac
  [[ "$hp" =~ ^[0-9]+$ ]] && kill -0 "$hp" 2>/dev/null || return 1
  cl="$(tr '\0' ' ' 2>/dev/null <"/proc/$hp/cmdline")" || return 1
  [[ "$cl" == *"seat-tick.sh $SEAT --$hk"* ]] || return 1
  echo "$hk:$hp"
}

# quota-wait helpers (see the QUOTA-WAIT header). The clock is overridable in selftest mode only.
qw_now() { if [ "${SEAT_TICK_SELFTEST:-}" = 1 ] && [[ "${SEAT_NOW_EPOCH:-}" =~ ^[0-9]+$ ]]; then echo "$SEAT_NOW_EPOCH"; else date +%s; fi; }
# stop_hook_lines <sid>: number of JSONL lines whose text/content starts with `Stop hook feedback:` (a real bounce; lines that merely mention Stop hooks do not count) in the seat's session file (0 when the file is absent or unreadable)
stop_hook_lines() { local n; n="$(grep -cE '"(text|content)":"Stop hook feedback:' "$JSONL_DIR/$1.jsonl" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }
# stop_hook_alarm <n>: the ALARM line on stderr + one line in <seat>-events.log (same lock and `ts | source | text` shape as queue_ask; no wake, no counters)
stop_hook_alarm() {
  local ts evl; ts="$(date -Iseconds)"
  evl="ALARM $SEAT stop-hook bounces=$1 (a Stop hook blocked the turn $1 times (a /goal judge or a blocking Stop hook); check: /goal clear under the seat lock if a goal is set; session $SID)"
  echo "$evl" >&2
  {
    flock 7
    [ -e "$EVF" ] || ( umask 077; : >"$EVF" )
    chmod 600 "$EVF"
    printf '%s | stop-hook | %s\n' "$ts" "$evl" >>"$EVF"
  } 7>>"$DASH/$SEAT-events.lock"
}
# quota_hit <log> <now_epoch>: 0 if the tail of a failed turn's output is a plan-limit line: the "hit your ... limit" phrase, or a line ft_parse_la_date reads as a date
# (claude -p prints only its final message, so 2 KB is the whole line)
quota_hit() { [ -n "$(ft_limit_word "$1")" ] && return 0; local l; l="$(ft_limit_line "$1")"; [ -n "$l" ] && ft_parse_la_date "$l" "$2" >/dev/null 2>&1; }
# quota_word <log>: session | usage | weekly (the word in "hit your <word> limit"; session when the phrase is absent), the label on stderr
quota_word() { local k; k="$(ft_limit_word "$1")"; echo "${k:-session}"; }
# quota_reset <log> <now_epoch>: prints the reset epoch of the limit text through the shared ft_parse_la_date (weekly "resets Oct 26, 9pm", session "resets 7:10pm"; ALWAYS
# America/Los_Angeles, the tz in parens is ignored by the lib); returns 1 when the text has no date
quota_reset() { local l; l="$(ft_limit_line "$1")"; [ -n "$l" ] && ft_parse_la_date "$l" "$2"; }
# quota_kind <log> <reset_epoch|""> <now_epoch>: weekly | session | unknown. The phrase decides ("hit your weekly limit"); "usage" or no phrase falls back to the wait
# (a parsed reset <= 24 h away is a session window, further out is weekly); no phrase and no reset = unknown
quota_kind() {
  local w; w="$(ft_limit_word "$1")"
  case "$w" in weekly|session) echo "$w"; return ;; esac
  [[ "$2" =~ ^[0-9]+$ ]] || { echo unknown; return; }
  if [ $(( $2 - $3 )) -le 86400 ]; then echo session; else echo weekly; fi
}

# ---- pending-ask queue (see ASK-QUEUE in the header). Globals set in main: ASKQ ASKLOCK EVJ EVF WAKE DASH SEAT ASK_TEXT ASK_ONE (the ask text on one line) ----
asks_count() { local n; n="$(grep -c . "$ASKQ" 2>/dev/null)"; echo "${n:-0}"; }
# queue_ask: record + ASK-QUEUED event + .wake. Returns 1 when the record could not be written (nothing else is done then).
queue_ask() {
  local ts rec evl tmp prog
  ts="$(date -Iseconds)"
  rec="$(jq -nc --arg ts "$ts" --arg from "${EVENT_SOURCE:-ask}" --arg text "$ASK_TEXT" '{ts:$ts,from:$from,text:$text}')" || return 1
  { flock 6; ( umask 077; printf '%s\n' "$rec" >>"$ASKQ" ) && chmod 600 "$ASKQ"; } 6>>"$ASKLOCK" || return 1
  evl="ASK-QUEUED $SEAT $ts: ${ASK_ONE:0:120}"
  {
    flock 7
    [ -e "$EVF" ] || ( umask 077; : >"$EVF" )
    chmod 600 "$EVF"
    printf '%s | ask-queue | %s\n' "$ts" "$evl" >>"$EVF"
    # the same counters seat-event.sh keeps (appended, last_event, woke_deferred, last_wake)
    prog='({appended:0,dropped_dup:0,woke_tick:0,woke_deferred:0,last_event:null,last_wake:null} + (. // {})) | .appended += 1 | .woke_deferred += 1 | .last_event=$iso | .last_wake=$iso'
    if tmp="$(mktemp "$DASH/.$SEAT-events.XXXXXX")"; then
      { jq --arg iso "$ts" "$prog" "$EVJ" 2>/dev/null || echo '{}' | jq --arg iso "$ts" "$prog"; } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$EVJ" || rm -f "$tmp"
    fi
  } 7>>"$DASH/$SEAT-events.lock"
  touch "$WAKE"
  return 0
}
# asks_consume: move the first ASK_BYTES bytes of the queue (what the prompt shows) to <queue>.consumed-<epoch>; sets ASK_CONSUMED (empty if nothing moved)
asks_consume() {
  local sz c n=0
  ASK_CONSUMED=""
  c="$ASKQ.consumed-$(date +%s)"; while [ -e "$c" ]; do n=$((n + 1)); c="$ASKQ.consumed-$(date +%s)-$n"; done
  {
    flock 6
    sz="$(stat -c %s "$ASKQ" 2>/dev/null || echo 0)"
    if [ "$sz" -le 0 ]; then :
    elif [ "$sz" -le "$ASK_BYTES" ]; then mv -f "$ASKQ" "$c" && ASK_CONSUMED="$c"
    else head -c "$ASK_BYTES" "$ASKQ" >"$c" && tail -c +$((ASK_BYTES + 1)) "$ASKQ" >"$ASKQ.rest" && mv -f "$ASKQ.rest" "$ASKQ" && ASK_CONSUMED="$c"
    fi
  } 6>>"$ASKLOCK"
}
# asks_restore: put the consumed records back at the head of the queue (the turn that carried them failed)
asks_restore() {
  [ -n "${ASK_CONSUMED:-}" ] && [ -e "$ASK_CONSUMED" ] || return 0
  { flock 6; { cat -- "$ASK_CONSUMED"; cat -- "$ASKQ" 2>/dev/null; true; } >"$ASKQ.rest" && mv -f "$ASKQ.rest" "$ASKQ" && rm -f "$ASK_CONSUMED"; } 6>>"$ASKLOCK"
  echo "seat-tick: ${SEAT:-?} the turn did not complete: queued ask(s) restored to ${ASKQ##*/}" >&2
  ASK_CONSUMED=""
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
  # tt <pid> <cmd...>: run <cmd> with the guard told that <pid> has a tty (a fake interactive seat; the decoys here are bash children with no pty of their own)
  tt() { env SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$1:1" "${@:2}"; }
  # the fake SIDs carry this run's pid: the guard scans every /proc cmdline for the SID, so two selftests running at once (or a seat's own session) must never share one
  local CS=selftest-ctl-sid-$$-0001 RS=selftest-rb-sid-$$-0002 SS=selftest-r7-sid-$$-0003 TS=selftest-tmo-sid-$$-0004
  export FLEET_DASH_DIR="$T/dash" SEATS_TABLE="$T/seats.tsv" MRC_TABLE="$T/mrc" GOAL_MD="$T/notes/wiki/goal.md" APPROVALS_FILE="$T/approvals.log" \
         SEAT_CLAUDE_BIN="$T/claude" SEAT_OAUTH_ENV="$T/oauth.conf" SEAT_LOCK_WAIT=1 SEAT_ASK_LOCK_WAIT=1
  mkdir -p "$T/dash"
  # col 8 = max_turns (ctl 60, rb 80, r7 80, tmo 80); the 'nt' row added later is a 7-column row (old table) and must run uncapped
  printf '# test table\nctl\tcontroller\t%s\t20\t14400\t^/goal SWARM-CONTROL\t999999999\t60\nrb\trb\t%s\t20\t14400\t^/goal CLEARWATER:\t-\t80\nr7\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\t80\ntmo\trb\t%s\t20\t4\t^/goal CLEARWATER:\t-\t80\n' \
    "$CS" "$RS" "$SS" "$TS" >"$SEATS_TABLE"
  printf 'controller test-model-1\nrb test-model-rb\nr7 test-model-r7\n' >"$MRC_TABLE"
  # INVARIANT (10-22 night): no fixture SID, decoy argv string or fake seats row carries a SID of the REAL table (read-only); a decoy with the live rb SID
  # made a live unit's first tick guard-fail. Every fixture SID is selftest- or 00000000- prefixed. UUID-shaped literals in this selftest must not equal a real SID.
  local realt="${SEATS_TABLE_REAL:-$HOME/.claude/state/seats.tsv}" rsid nreal=0 leak="" fx selsec uu
  selsec="$(sed -n '/^selftest() {$/,/^}$/p' "$SELF")"
  for fx in "$CS" "$RS" "$SS" "$TS" "selftest-other-sid-$$" $(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $3}' "$SEATS_TABLE"); do
    [[ "$fx" == selftest-* || "$fx" == 00000000-* ]] || leak="$leak bad-prefix:$fx"
  done
  if [ -r "$realt" ]; then
    while IFS= read -r rsid; do
      nreal=$(( nreal + 1 ))
      for fx in "$CS" "$RS" "$SS" "$TS" "selftest-other-sid-$$"; do case "$fx" in *"$rsid"*) leak="$leak fixture:${rsid:0:8}" ;; esac; done
      grep -qF -- "$rsid" "$SEATS_TABLE" && leak="$leak seats-row:${rsid:0:8}"
      grep -qF -- "$rsid" <<<"$selsec" && leak="$leak selftest-source:${rsid:0:8}"
      while IFS= read -r uu; do [ "$uu" = "$rsid" ] && leak="$leak uuid-literal:${rsid:0:8}"; done < <(grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' <<<"$selsec")
    done < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ && length($3) >= 8 {print $3}' "$realt")
    [ -z "$leak" ]; chk "fixtures carry no real seat SID (checked $nreal real SIDs)${leak:+ LEAK:$leak}" $?
  else
    [ -z "$leak" ]; chk "fixtures carry no real seat SID (no real table)${leak:+ LEAK:$leak}" $?
  fi
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
echo "seat_env=WM_SEAT=${WM_SEAT:-} CLAUDE_SESSION_NAME=${CLAUDE_SESSION_NAME:-} WM_DECIDE_AGENT=${WM_DECIDE_AGENT:-}"
echo "lean_env=SEAT_LEAN=${SEAT_LEAN:-} CLAUDE_LEAN_START=${CLAUDE_LEAN_START:-}"
echo "status_line2=$(sed -n 2p "$FLEET_DASH_DIR/fleet-status.md" 2>/dev/null)"
printf '%s' "${@: -1}" >"$FLEET_DASH_DIR/prompt.${WM_SEAT:-x}.txt"
if [ -n "${FAKE_CLOBBER:-}" ]; then   # rewrite the running script IN PLACE (same inode), longer than before: the incident of 10-22 4:00 PM
  { yes 'echo CLOBBERED' | head -400; cat "$FAKE_CLOBBER"; } >"$FAKE_CLOBBER.new" && cat "$FAKE_CLOBBER.new" >"$FAKE_CLOBBER"
fi
[ -n "${FAKE_BELL:-}" ] && { echo "$(date -Iseconds) | selftest | mid-turn bell" >>"$FAKE_BELL-events.log"; touch "$FAKE_BELL.wake"; }   # a bell arriving mid-turn
if [ -n "${FAKE_STOPHOOK_FILE:-}" ]; then   # a live /goal judge bouncing the turn: `Stop hook` lines appended to the session JSONL
  for _i in $(seq 1 "${FAKE_STOPHOOK_N:-0}"); do echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\ngoal not met"}]}}' >>"$FAKE_STOPHOOK_FILE"; done
fi
if [ -n "${FAKE_MENTION_FILE:-}" ]; then   # turn text that merely mentions Stop hooks: must NOT count as a bounce
  for _i in $(seq 1 "${FAKE_MENTION_N:-0}"); do
    if [ "$_i" = 2 ]; then echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"grep: the Stop hook alarm fired"}]}}' >>"$FAKE_MENTION_FILE"
    else echo '{"type":"assistant","message":{"content":[{"type":"text","text":"the Stop hook alarm ..."}]}}' >>"$FAKE_MENTION_FILE"; fi
  done
fi
sleep "${FAKE_SLEEP:-2}"
echo "END $(date +%s.%N)"
[ -n "${FAKE_MAXTURNS:-}" ] && { printf 'Error: Reached max turns (%s)' "$FAKE_MAXTURNS"; exit 1; }   # MEASURED (claude 2.1.293, --max-turns 1): this line, no newline, stderr empty, exit 1
[ -n "${FAKE_LIMIT:-}" ] && echo "$FAKE_LIMIT"
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
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-1 --max-turns 60 $CA --resume $CS SWEEP $ts_re tick=1 status_age=none approvals_new=3 events_new=0\$" "$T/o1"; chk "sweep 1: argv/prompt '$(grep -m1 ^ARGV "$T/o1" | cut -c1-200)'" $?
  grep -q "model test-model-1" "$T/o1"; chk "model comes from MRC_TABLE controller row" $?
  grep -q "token_set=yes cwd=$HOME\$" "$T/o1"; chk "oauth env sourced (token present, value not shown), cwd=\$HOME" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl WM_DECIDE_AGENT=ctl$' "$T/o1"; chk "SWEEP: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
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
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-2 --max-turns 60 $CA --resume $CS ASK $ts_re seat=ctl approvals_new=0 events_new=0: what is rb doing\?\$" "$T/o3"; chk "ask: prompt '$(grep -m1 ^ARGV "$T/o3" | cut -c1-200)'" $?
  grep -q '^seat_env=WM_SEAT=ctl CLAUDE_SESSION_NAME=ctl WM_DECIDE_AGENT=ctl$' "$T/o3"; chk "ASK: fake claude saw WM_SEAT=ctl and CLAUDE_SESSION_NAME=ctl" $?
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
  [ "$rc" = 0 ] && [ "$(j .ticks_skipped)" = 3 ] && [ "$(wc -l <"$T/dash/ctl-asks.pending")" = 1 ]; chk "ask that cannot lock: queued, exit 0 (was 5, 10-22 8:40 PM), ticks_skipped unchanged" $?
  rm -f "$T/dash/ctl-asks.pending" "$T/dash/ctl-events.log" "$T/dash/ctl.wake"   # the queued ask and its ASK-QUEUED event belong to this test only
  kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(j .ticks_skipped)" = 0 ]; chk "next successful run resets ticks_skipped to 0" $?

  # 7. guard, ctl: a process shaped like the interactive controller holding the SID
  local runs_before; runs_before="$(j .sends_total)"
  bash -c "exec -a 'claude --resume $CS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pg=$!
  sleep 0.4
  tt "$pg" "$SELF" ctl >"$T/o7" 2>"$T/e7"; rc=$?
  [ "$rc" = 4 ] && grep -q 'ALARM ctl guard' "$T/e7" && [ "$(j .sends_total)" = "$runs_before" ] && ! grep -q '^ARGV' "$T/o7"; chk "guard: process 'claude --resume <SID>' -> exit 4, ALARM, claude not run ('$(grep ALARM "$T/e7" | cut -c1-140)')" $?
  [[ "$(j .last_skip_reason)" == guard:* ]]; chk "guard: last_skip_reason=$(j .last_skip_reason | cut -c1-60)" $?
  tt "$pg" "$SELF" ctl --guard-check >/dev/null 2>&1; [ $? = 4 ]; chk "--guard-check: exit 4 while it is alive" $?
  kill "$pg"; wait "$pg" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1; [ $? = 0 ]; chk "guard clear after the fake exits: runs" $?
  bash -c "exec -a claude python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pq=$!
  sleep 0.4
  setpid ctl "$pq"
  tt "$pq" "$SELF" ctl >/dev/null 2>"$T/e7b"; rc=$?
  [ "$rc" = 4 ] && grep -q "pid $pq alive" "$T/e7b"; chk "guard: old_pid from seats.tsv alive with 'claude' in cmdline (+ tty) -> exit 4" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$pq:0" FAKE_SLEEP=0 "$SELF" ctl >"$T/e7c" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q "guard clear (old_pid $pq alive without a tty: not an interactive seat, ignored)" "$T/e7c" && grep -q '^ARGV' "$T/e7c"; chk "guard: old_pid alive + claude + NO tty -> not refused, tick runs, log says 'old_pid $pq alive without a tty: not an interactive seat, ignored'" $?
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
  [[ "$real_row" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\|[0-9]+$ ]]; chk "defaults: real seats.tsv ctl row = '<uuid SID>|<old pid>' (shape only: the selftest source never embeds a real SID)" $?
  out="$(CTL_ASK_DRY=1 "$HERE/ctl-ask.sh" "hello there" 2>&1)"
  [[ "$out" == *"systemd-run --user --collect --unit seat-ask-ctl-"*"seat-tick.sh ctl --ask "*"hello there"* ]]; chk "ctl-ask.sh wrapper (dry): '${out:0:170}'" $?
  "$SELF" ctl --status | jq -e 'has("last_tick") and has("last_sent") and has("ticks_skipped") and has("last_skip_reason") and has("sends_total") and has("last_exit") and has("last_duration_s") and has("last_prompt_kind") and has("status_file") and has("approvals_seen") and has("quota_wait_until")' >/dev/null; chk "--status prints state JSON with all keys (quota_wait_until included)" $?
  [ "$("$HERE/ctl-sweep.sh" --status | jq -c .)" = "$("$SELF" ctl --status | jq -c .)" ]; chk "ctl-sweep.sh wrapper --status == seat-tick.sh ctl --status" $?

  # ---- the generalization: rb and r7 (33 ctl assertions above) ---------------------------------------
  # 9. rb TICK
  rm -f "$T/dash/fleet-status.md"
  "$SELF" rb >"$T/orb" 2>"$T/erb"; rc=$?
  [ "$rc" = 0 ]; chk "rb tick: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-rb --max-turns 80 $LA --resume $RS TICK $ts_re seat=rb tick=1 events_new=0\$" "$T/orb"; chk "rb: argv has model from row rb + SID from seats.tsv + TICK line 1 '$(grep -m1 ^ARGV "$T/orb" | cut -c1-170)'" $?
  [ "$(pl rb 2 | head -1)" = "$goal_rb" ] && [ "$goal_rb" != "" ]; chk "rb: prompt line 2 = the /goal CLEARWATER: line verbatim ('$(pl rb 2 | cut -c1-70)...')" $?
  [ "$(pl rb 3)" = 'Rules of this shape: one sweep toward the goal per tick; every DECISION is a wm-decide ledger row the same turn; wake the controller with ctl-ask.sh "<text>"; any background process you need outlives this turn only as a systemd-run --user unit with premise + expiry; every EVENT line gets a read and, if real, a mitigation this turn; log a DECISION row for each action; this turn ends when you print the timestamped STATUS block.' ] && [ "$(wc -l <"$T/dash/prompt.rb.txt")" = 2 ]; chk "rb: prompt line 3 = the rules line verbatim, exactly 3 lines" $?
  ! grep -q 'approvals_new\|status_age' "$T/dash/prompt.rb.txt"; chk "rb: no approvals_new / status_age in the prompt" $?
  grep -q '^seat_env=WM_SEAT=rb CLAUDE_SESSION_NAME=rb WM_DECIDE_AGENT=rb$' "$T/orb"; chk "rb: fake claude saw WM_SEAT=rb CLAUDE_SESSION_NAME=rb" $?
  grep -q -- ' --strict-mcp-config ' <(grep -m1 '^ARGV' "$T/orb") && grep -q '^lean_env=SEAT_LEAN=1 CLAUDE_LEAN_START=1$' "$T/orb"; chk "rb LEAN: fake claude got --strict-mcp-config and env SEAT_LEAN=1 CLAUDE_LEAN_START=1" $?
  ! grep -q -- 'strict-mcp-config' <(grep -m1 '^ARGV' "$T/o1") && ! grep -q -- '--mcp-config' <(grep -m1 '^ARGV' "$T/o1") && grep -q '^lean_env=SEAT_LEAN= CLAUDE_LEAN_START=$' "$T/o1"; chk "ctl NOT lean: sweep 1 has no --strict-mcp-config / --mcp-config and no SEAT_LEAN/CLAUDE_LEAN_START env" $?
  grep -m1 '^ARGV' "$T/o1" | grep -q -- " $CA --resume "; chk "ctl argv carries --settings ctl-settings.json (autoCompactEnabled) and nothing else lean" $?
  [ "$(jq -c . "$HOME/.config/claude-seat/ctl-settings.json")" = '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"360000","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"},"autoCompactEnabled":true,"autoCompactWindow":"auto"}' ]; chk "real ctl-settings.json is exactly {env: 360000/50 compact pin, autoCompactEnabled: true, autoCompactWindow: auto} (no hooks/plugins keys)" $?
  [ "$(jq -r '[.autoCompactEnabled, .autoCompactWindow, .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE] | join(" ")' "$HOME/.config/claude-seat/settings.json")" = "true auto 360000 50" ]; chk "rb/r7 lean settings.json carries autoCompactEnabled=true autoCompactWindow=auto + env pin 360000/50 (seats compact at 180K while \$HOME runs 500K)" $?
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
  [ "$rc" = 0 ] && grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-rb --max-turns 80 $LA --resume $RS ASK $ts_re seat=rb events_new=0: status of 1025\?\$" "$T/orba" && [ -s "$T/dash/rb-ask-last.log" ] && [ "$(jseat rb .last_prompt_kind)" = ask ] && [ "$(jseat rb .sends_total)" = 3 ]; chk "rb ASK: 'ASK <time> <date> seat=rb: <text>', rb-ask-last.log, sends_total unchanged" $?

  # 10. r7 TICK
  "$SELF" r7 >"$T/or7" 2>"$T/er7"; rc=$?
  [ "$rc" = 0 ]; chk "r7 tick: exit 0" $?
  grep -Eq "^ARGV: -p --dangerously-skip-permissions --model test-model-r7 --max-turns 80 $LA --resume $SS TICK $ts_re seat=r7 tick=1 events_new=0\$" "$T/or7"; chk "r7: argv has model from row r7 + SID from seats.tsv + TICK line 1" $?
  [ "$(pl r7 2)" = "$goal_r7" ] && [ "$(pl r7 3 | cut -c1-23)" = "Rules of this shape: on" ] && [ "$(wc -l <"$T/dash/prompt.r7.txt")" = 2 ]; chk "r7: line 2 = the /goal CLEARWATER-R7 line verbatim (not the rb line), line 3 = rules, 3 lines" $?
  grep -q '^seat_env=WM_SEAT=r7 CLAUDE_SESSION_NAME=r7 WM_DECIDE_AGENT=r7$' "$T/or7" && [ -e "$T/dash/r7.lock" ] && [ -s "$T/dash/r7-tick-last.log" ] && [ ! -e "$T/dash/fleet-status.md" ] && ! grep -q 'approvals_new' "$T/dash/prompt.r7.txt"; chk "r7: WM_SEAT=r7, r7.lock, r7-tick-last.log, no --open, no approvals_new" $?
  [ "$(jseat r7 .sends_total)" = 1 ] && [ "$(jseat r7 .last_prompt_kind)" = tick ]; chk "r7: state r7-tick.json sends_total=1 kind=tick" $?

  # 11. guard per seat: a fake 'claude --resume <sid>' blocks only its own seat
  local s sid
  for s in rb r7 ctl; do
    case "$s" in rb) sid="$RS" ;; r7) sid="$SS" ;; ctl) sid="$CS" ;; esac
    bash -c "exec -a 'claude --resume $sid' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pz=$!
    sleep 0.4
    rm -f "$T/dash/prompt.$s.txt"
    tt "$pz" "$SELF" "$s" >"$T/og$s" 2>"$T/eg$s"; rc=$?
    [ "$rc" = 4 ] && grep -q "ALARM $s guard" "$T/eg$s" && ! grep -q '^ARGV' "$T/og$s" && [ ! -e "$T/dash/prompt.$s.txt" ] && [[ "$(jseat "$s" .last_skip_reason)" == guard:* ]]; chk "guard $s: fake 'claude --resume $sid' -> exit 4, ALARM, claude not run" $?
    tt "$pz" "$SELF" "$s" --guard-check >/dev/null 2>&1; [ $? = 4 ]; chk "guard $s: --guard-check exit 4" $?
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
  tt "$pk" "$SELF" r7 >/dev/null 2>&1; local gs1; gs1="$(jseat r7 .guard_since)"
  sleep 1.2; tt "$pk" "$SELF" r7 >/dev/null 2>&1
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
  grep -q 'LOCK_WAIT="${SEAT_LOCK_WAIT:-60}"' "$SELF" && grep -q 'ASK_LOCK_WAIT="${SEAT_ASK_LOCK_WAIT:-20}"' "$SELF"; chk "defaults: tick lock wait 60 s, ask lock wait 20 s" $?

  # 13. timeout_sec column is the per-turn ceiling (95 %): row tmo has 4 s -> cap 3 s
  local t0; t0=$(date +%s)
  FAKE_SLEEP=20 "$SELF" tmo >"$T/otmo" 2>&1; rc=$?
  [ "$rc" = 124 ] && [ $(( $(date +%s) - t0 )) -lt 15 ] && [ "$(jseat tmo .last_exit)" = 124 ]; chk "timeout_sec=4: a 20 s claude is stopped at 3 s, exit 124 recorded ($(( $(date +%s) - t0 ))s wall)" $?

  # 14. unknown seat / usage
  "$SELF" nosuchseat >/dev/null 2>&1; [ $? = 64 ]; chk "unknown seat: exit 64" $?
  "$SELF" rb --ask >/dev/null 2>&1; [ $? = 64 ]; chk "--ask without text: exit 64" $?

  # 15. seat-ask.sh
  out="$(SEAT_ASK_DRY=1 "$HERE/seat-ask.sh" r7 "hello there" 2>&1)"
  [[ "$out" == *"systemd-run --user --collect --unit seat-ask-r7-"*"seat-tick.sh r7 --ask "*"hello there"* ]]; chk "seat-ask.sh r7 (dry): '${out:0:170}'" $?
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

  # 15e. WM_DECIDE_AGENT (10-22, row b7cb): every prompt kind carries the seat identity, and it overrides an inherited value
  grep -q '^seat_env=.* WM_DECIDE_AGENT=ctl$' "$T/o1" && grep -q '^seat_env=.* WM_DECIDE_AGENT=ctl$' "$T/o3" && grep -q '^seat_env=.* WM_DECIDE_AGENT=rb$' "$T/orb" && grep -q '^seat_env=.* WM_DECIDE_AGENT=r7$' "$T/or7" \
    && grep -q '^seat_env=.* WM_DECIDE_AGENT=rb$' "$T/oe3" && grep -q '^seat_env=.* WM_DECIDE_AGENT=rb$' "$T/orba" && grep -q '^seat_env=.* WM_DECIDE_AGENT=ctl$' "$T/oe8"; chk "WM_DECIDE_AGENT=<seat> reaches claude on ctl sweep/ask/event, rb tick/ask/event, r7 tick" $?
  WM_DECIDE_AGENT=aide FAKE_SLEEP=0 "$SELF" rb >"$T/owda" 2>&1
  grep -q '^seat_env=.* WM_DECIDE_AGENT=rb$' "$T/owda"; chk "an inherited WM_DECIDE_AGENT=aide is overridden by the seat" $?

  # 15f. LOCK-COVERED (10-22): a timer tick that times out on a LIVE same-seat EVENT/ASK turn is covered (exit 0, no skip, .wake), anything else stays exit 5 + a skip
  local hp sk1 fp
  : >"$EVD/rb-events.log"; rm -f "$EVD/rb.wake"; FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1   # drain
  ev rb "covered-by-event"
  FAKE_SLEEP=5 "$SELF" rb --event >"$T/ocv1" 2>&1 & ST_PIDS="$ST_PIDS $!"; hp=$!
  for i in $(seq 1 100); do grep -q '^START' "$T/ocv1" && break; sleep 0.1; done
  rm -f "$EVD/rb.wake"; sk1="$(jseat rb .ticks_skipped)"
  local le0 ld0; le0="$(jseat rb .last_exit)"; ld0="$(jseat rb .last_duration_s)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >"$T/ocv2" 2>"$T/ecv2"; rc=$?
  [[ "$(jseat rb .last_covered_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+$ ]] && [ "$(jseat rb .last_covered_by)" = "event:$hp" ] && [ "$(jseat rb .last_exit)" = "$le0" ] && [ "$(jseat rb .last_duration_s)" = "$ld0" ] && "$SELF" rb --status | jq -e 'has("last_covered_at") and has("last_covered_by")' >/dev/null; chk "covered tick stamps last_covered_at ($(jseat rb .last_covered_at)) + last_covered_by=event:$hp, last_exit ($le0) and last_duration_s ($ld0) unchanged, --status has both" $?
  [ "$rc" = 0 ] && [ "$(jseat rb .last_skip_reason)" = "lock-covered:event:$hp" ] && [ "$(jseat rb .ticks_skipped)" = "$sk1" ] && [ -e "$EVD/rb.wake" ] && ! grep -q '^ARGV' "$T/ocv2" && ! grep -q ALARM "$T/ecv2" "$T/ocv2"; chk "tick vs a running EVENT turn (pid $hp): exit $rc, reason=$(jseat rb .last_skip_reason), ticks_skipped unchanged ($sk1), rb.wake touched, no ALARM, claude not run" $?
  wait "$hp"
  grep -q 'chaining one EVENT turn' "$T/ocv1" && grep -q 'no new events' "$T/ocv1" && [ "$(grep -c '^START' "$T/ocv1")" = 1 ] && [ ! -e "$EVD/rb.wake" ] && [ "$(jseat rb .last_skip_reason)" = null ]; chk "the covered EVENT turn chains from the .wake (no new events: ends quietly), reason cleared at its exit-0 end" $?
  FAKE_SLEEP=4 "$SELF" rb --ask "long ask" >"$T/ocv3" 2>&1 & ST_PIDS="$ST_PIDS $!"; hp=$!
  for i in $(seq 1 100); do grep -q '^START' "$T/ocv3" && break; sleep 0.1; done
  sk1="$(jseat rb .ticks_skipped)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >"$T/ocv4" 2>"$T/ecv4"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat rb .last_skip_reason)" = "lock-covered:ask:$hp" ] && [ "$(jseat rb .ticks_skipped)" = "$sk1" ] && [ -e "$EVD/rb.wake" ]; chk "tick vs a running ASK turn (pid $hp): exit 0, reason=$(jseat rb .last_skip_reason), ticks_skipped unchanged" $?
  wait "$hp"; rm -f "$EVD/rb.wake"
  FAKE_SLEEP=4 "$SELF" rb >"$T/ocv5" 2>&1 & ST_PIDS="$ST_PIDS $!"; hp=$!
  for i in $(seq 1 100); do grep -q '^START' "$T/ocv5" && break; sleep 0.1; done
  sk1="$(jseat rb .ticks_skipped)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(jseat rb .last_skip_reason)" = lock-busy ] && [ "$(jseat rb .ticks_skipped)" = "$(( sk1 + 1 ))" ] && [ ! -e "$EVD/rb.wake" ]; chk "tick vs a running TICK turn: still exit 5, lock-busy, ticks_skipped +1, no .wake" $?
  wait "$hp"
  ( exec 8>>"$EVD/rb.lock"; flock 8; sleep 8 ) & ST_PIDS="$ST_PIDS $!"; fp=$!
  sleep 0.4
  printf 'event %s %s\n' "$fp" "$(date +%s)" >"$EVD/rb.lock.holder"   # live pid, forged record: its cmdline is not 'seat-tick.sh rb --event'
  sk1="$(jseat rb .ticks_skipped)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(jseat rb .last_skip_reason)" = lock-busy ] && [ "$(jseat rb .ticks_skipped)" = "$(( sk1 + 1 ))" ]; chk "foreign live holder with a forged 'event <pid>' record: exit 5, lock-busy, ticks_skipped +1" $?
  printf 'event 999999999 %s\n' "$(date +%s)" >"$EVD/rb.lock.holder"; sk1="$(jseat rb .ticks_skipped)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(jseat rb .ticks_skipped)" = "$(( sk1 + 1 ))" ]; chk "foreign holder with a dead pid in the record: exit 5, ticks_skipped +1" $?
  rm -f "$EVD/rb.lock.holder"; sk1="$(jseat rb .ticks_skipped)"
  SEAT_LOCK_WAIT=1 FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1; rc=$?
  [ "$rc" = 5 ] && [ "$(jseat rb .ticks_skipped)" = "$(( sk1 + 1 ))" ]; chk "foreign holder with no record at all: exit 5, ticks_skipped +1" $?
  kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; sleep 0.3
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1
  [ "$(jseat rb .ticks_skipped)" = 0 ] && [ "$(awk '{print $1}' "$EVD/rb.lock.holder")" = tick ] && [ "$(awk '{print $2}' "$EVD/rb.lock.holder")" -gt 0 ]; chk "the holder record is '<kind> <pid> <epoch>' (last holder: $(cat "$EVD/rb.lock.holder")); a clean tick resets ticks_skipped" $?

  # 15g. GUARD (10-22): only an INTERACTIVE holder refuses; a print-mode turn of a seat unit, a dead / non-claude / print-mode old_pid do not
  local UCG='0::/user.slice/user-1000.slice/user@1000.service/app.slice/seat-event-r7-1792709860-4242.service' TCG='0::/user.slice/user-1000.slice/user@1000.service/app.slice/system-seat\x2dtick.slice/seat-tick@r7.service' XCG='0::/user.slice/user-1000.slice/user@1000.service/app.slice/tmux-spawn-1.scope'
  bash -c "exec -a 'claude -p --resume $SS' python3 -c 'import time; time.sleep(40)'" & ST_PIDS="$ST_PIDS $!"; local pu=$!
  sleep 0.4
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_CGROUP_OVERRIDE="$UCG" FAKE_SLEEP=0 "$SELF" r7 >"$T/ogu1" 2>"$T/egu1"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/ogu1" && grep -q "pid $pu is a seat-unit print-mode turn (ignored)" "$T/ogu1" && ! grep -q ALARM "$T/egu1"; chk "SID held by 'claude -p' in a seat-event- cgroup (pid $pu): not refused, runs, note names the pid" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_CGROUP_OVERRIDE="$TCG" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ]; chk "...same for a seat-tick@ cgroup" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_CGROUP_OVERRIDE="$UCG" "$SELF" r7 --guard-check >"$T/ogu2" 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(wc -l <"$T/ogu2")" = 1 ] && grep -q "^guard: clear (.*pid $pu" "$T/ogu2"; chk "--guard-check: exit 0, one clean line (no /proc race noise) saying why ('$(head -c 110 "$T/ogu2")')" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_CGROUP_OVERRIDE="$XCG" FAKE_SLEEP=0 "$SELF" r7 >"$T/ogu3" 2>"$T/egu3"; rc=$?
  [ "$rc" = 4 ] && grep -q "ALARM r7 guard.*pid $pu holds session $SS" "$T/egu3" && ! grep -q '^ARGV' "$T/ogu3"; chk "same 'claude -p' holder in a non-seat cgroup (a hand-run turn): refused, exit 4, reason names pid $pu" $?
  local want=4; case "$(cat /proc/$$/cgroup 2>/dev/null)" in *seat-tick@*|*seat-event-*|*seat-ask-*) want=0 ;; esac   # a selftest run by a seat unit's own turn lives in a seat cgroup
  SEAT_GUARD_CGROUP_OVERRIDE="$UCG" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = "$want" ]; chk "the cgroup override is ignored outside selftest mode (no SEAT_TICK_SELFTEST=1): the real /proc/<pid>/cgroup decides (exit $rc, expected $want)" $?
  kill "$pu"; wait "$pu" 2>/dev/null; sleep 0.3
  bash -c "exec -a 'claude --resume $SS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; pu=$!
  sleep 0.4
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$pu:1" SEAT_GUARD_CGROUP_OVERRIDE="$UCG" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>"$T/egu4"; rc=$?
  [ "$rc" = 4 ] && grep -q "pid $pu holds session" "$T/egu4"; chk "an interactive claude (no -p) is refused even with a seat-unit cgroup, reason names pid $pu" $?
  kill "$pu"; wait "$pu" 2>/dev/null; sleep 0.3
  setpid ctl 999999999
  "$SELF" ctl --guard-check >"$T/ogd1" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q 'old_pid 999999999 not alive' "$T/ogd1"; chk "old_pid dead: not refused, --guard-check says so ('$(head -c 90 "$T/ogd1")')" $?
  FAKE_SLEEP=0 "$SELF" ctl >"$T/ogd2" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q 'guard clear (old_pid 999999999 not alive)' "$T/ogd2" && grep -q '^ARGV' "$T/ogd2"; chk "old_pid dead: the tick runs and its log line says 'guard clear (old_pid 999999999 not alive)'" $?
  bash -c "exec -a 'claude -p --resume selftest-other-sid-$$' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local po=$!
  sleep 0.4
  setpid ctl "$po"
  "$SELF" ctl --guard-check >"$T/ogd3" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q "old_pid $po is a print-mode claude" "$T/ogd3"; chk "old_pid alive but a print-mode claude: not the interactive seat, not refused" $?
  kill "$po"; wait "$po" 2>/dev/null; setpid ctl 999999999
  # guard_since / last_skip_reason clear when the turn STARTS (all kinds), not only at an exit-0 end
  gs_check() {   # gs_check <label> <args...>: one refusal behind a live interactive holder, release, a slow turn: state is already clean while it still runs
    local lbl="$1" rc1 gs ph2 pt w; shift
    bash -c "exec -a 'claude --resume $SS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; ph2=$!
    sleep 0.4
    tt "$ph2" "$SELF" r7 "$@" >/dev/null 2>&1; rc1=$?; gs="$(jseat r7 .guard_since)"
    kill "$ph2"; wait "$ph2" 2>/dev/null; sleep 0.3
    FAKE_SLEEP=3 "$SELF" r7 "$@" >"$T/ogs" 2>&1 & ST_PIDS="$ST_PIDS $!"; pt=$!
    for w in $(seq 1 100); do grep -q '^START' "$T/ogs" && break; sleep 0.1; done
    [ "$rc1" = 4 ] && [ "$gs" != null ] && [ "$(jseat r7 .guard_since)" = null ] && [ "$(jseat r7 .last_skip_reason)" = null ]; chk "guard_since ($gs) and the guard reason clear when a $lbl turn STARTS (turn still running)" $?
    wait "$pt"
  }
  gs_check tick
  ev r7 "gs-event"; gs_check event --event
  gs_check ask --ask "gs ask"
  bash -c "exec -a 'claude --resume $SS' python3 -c 'import time; time.sleep(30)'" & ST_PIDS="$ST_PIDS $!"; local pn=$!
  sleep 0.4
  tt "$pn" "$SELF" r7 --event >/dev/null 2>&1; rc=$?
  [ "$rc" = 4 ] && [ "$(jseat r7 .guard_since)" != null ]; chk "EVENT behind a live holder (no new events): guard recorded, exit 4" $?
  kill "$pn"; wait "$pn" 2>/dev/null; sleep 0.3
  "$SELF" r7 --event >"$T/ogn" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q 'no new events' "$T/ogn" && [ "$(jseat r7 .guard_since)" = null ] && [ "$(jseat r7 .last_skip_reason)" = null ]; chk "EVENT with nothing new, guard now clear: exit 0 and the stale guard reason / guard_since are cleared" $?

  # 15h. TTY GATE (10-22 night): a fake `exec -a 'claude --resume <SID>' sleep` with no tty / tmux in a plain user-session cgroup was taken as the interactive seat.
  # Interactive = non-print claude AND (controlling tty OR tmux ancestor). All SIDs here are fakes (see the invariant above).
  local FAKESID=00000000-0000-4000-8000-00000000fa4e NTC='0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-u123.service'
  cp "$SEATS_TABLE" "$T/seats.pre-nt"
  printf 'nt\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\n' "$FAKESID" >>"$SEATS_TABLE"
  bash -c "exec -a 'claude --resume $FAKESID' sleep 60" & ST_PIDS="$ST_PIDS $!"; local pt1=$!
  sleep 0.4
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$pt1:0" SEAT_GUARD_CGROUP_OVERRIDE="$NTC" FAKE_SLEEP=0 "$SELF" nt >"$T/ot1" 2>"$T/et1"; rc=$?
  [ "$rc" = 0 ] && grep -q "guard clear (pid $pt1 holds the SID without a tty: not an interactive seat, ignored)" "$T/ot1" && grep -q '^ARGV' "$T/ot1" && ! grep -q ALARM "$T/et1"; chk "TTY GATE: non-print 'claude --resume <fake SID>' (pid $pt1), NO tty, plain cgroup -> not refused, tick runs, log: 'guard clear (pid $pt1 holds the SID without a tty: not an interactive seat, ignored)'" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$pt1:0" "$SELF" nt --guard-check >"$T/ot2" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q "^guard: clear (pid $pt1 holds the SID without a tty" "$T/ot2"; chk "TTY GATE: --guard-check exit 0 and says why ('$(head -c 100 "$T/ot2")')" $?
  SEAT_TICK_SELFTEST=1 SEAT_GUARD_TTY_OVERRIDE="$pt1:1" SEAT_GUARD_CGROUP_OVERRIDE="$NTC" FAKE_SLEEP=0 "$SELF" nt >"$T/ot3" 2>"$T/et3"; rc=$?
  [ "$rc" = 4 ] && grep -q "ALARM nt guard.*pid $pt1 holds session $FAKESID" "$T/et3" && ! grep -q '^ARGV' "$T/ot3"; chk "TTY GATE: the same holder with tty override 1 -> refused, exit 4, reason names pid $pt1" $?
  SEAT_GUARD_TTY_OVERRIDE="$pt1:1" "$SELF" nt --guard-check >/dev/null 2>&1; rc=$?
  has_tty_or_tmux "$pt1"; local want_real=$(( $? == 0 ? 4 : 0 ))   # no SEAT_TICK_SELFTEST: the override must be ignored, the real tty / tmux ancestry decides
  [ "$rc" = "$want_real" ]; chk "TTY GATE: SEAT_GUARD_TTY_OVERRIDE is ignored outside selftest mode (exit $rc, real ancestry says $want_real)" $?
  kill "$pt1"; wait "$pt1" 2>/dev/null; sleep 0.3
  # a decoy under a process whose comm is 'tmux' (a copy of bash named tmux) counts as tmux-hosted even with tty 0
  mkdir -p "$T/fakebin"; cp "$(command -v bash)" "$T/fakebin/tmux"
  printf '#!/bin/bash\necho $$ >"%s/tmuxkid.pid"\nexec -a "claude --resume %s" sleep 60\n' "$T" "$FAKESID" >"$T/tmuxkid.sh"; chmod +x "$T/tmuxkid.sh"
  "$T/fakebin/tmux" -c "$T/tmuxkid.sh; :" & ST_PIDS="$ST_PIDS $!"; local ptm=$!
  sleep 0.5
  local ptk; ptk="$(cat "$T/tmuxkid.pid" 2>/dev/null)"
  [ "$(cat "/proc/$ptm/comm" 2>/dev/null)" = tmux ] && FAKE_SLEEP=0 "$SELF" nt >/dev/null 2>"$T/et4"; rc=$?
  [ -n "$ptk" ] && [ "$rc" = 4 ] && grep -q "pid $ptk holds session $FAKESID" "$T/et4"; chk "TTY GATE: no tty but an ancestor with comm 'tmux' -> still the interactive seat: refused, names pid ${ptk:-?}" $?
  kill "$ptm" "$ptk" 2>/dev/null; wait "$ptm" 2>/dev/null; sleep 0.3
  # a REAL pty (python pty.fork: setsid + controlling tty), no override at all: still refused end-to-end
  python3 -I -c '
import os, sys, time
import pty
pid, fd = pty.fork()
if pid == 0:
    os.execv("/usr/bin/sleep", ["claude --resume " + sys.argv[1], "60"])
open(sys.argv[2], "w").write(str(pid)); time.sleep(60)' "$FAKESID" "$T/ptykid.pid" & ST_PIDS="$ST_PIDS $!"; local ppy=$!
  sleep 0.6
  local ppk; ppk="$(cat "$T/ptykid.pid" 2>/dev/null)"
  if [ -n "$ppk" ] && [ -r "/proc/$ppk/stat" ] && [ "$(stat_after_comm "$(cat /proc/$ppk/stat)" 5)" != 0 ]; then
    FAKE_SLEEP=0 "$SELF" nt >/dev/null 2>"$T/et5"; rc=$?
    [ "$rc" = 4 ] && grep -q "pid $ppk holds session $FAKESID" "$T/et5"; chk "TTY GATE: a REAL pty-backed 'claude --resume <fake SID>' (pid $ppk, tty_nr $(stat_after_comm "$(cat /proc/$ppk/stat)" 5)), no override -> refused, exit 4" $?
  else echo "PASS TTY GATE: real-pty case skipped (no pty available here)"; fi
  kill "$ppk" "$ppy" 2>/dev/null; wait "$ppy" 2>/dev/null; sleep 0.3
  # tty_nr parse: comm with spaces and parentheses (fake /proc stat lines)
  local ST1='4242 (tmux: server) S 1 4242 4242 34816 4242 4194560 1 0 0 0 0 0 0 0 20 0 1 0 55 1 2 3'
  local ST2='4243 (we ird) (na me) S 4242 4243 4243 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 1 0 56 1 2 3'
  local ST3='4244 (a) b) c) R 4243 4244 4244 34817 4244 4194304 1 0 0 0'
  [ "$(stat_after_comm "$ST1" 5)" = 34816 ] && [ "$(stat_after_comm "$ST2" 5)" = 0 ] && [ "$(stat_after_comm "$ST3" 5)" = 34817 ] && [ "$(stat_after_comm "$ST2" 2)" = 4242 ]; chk "tty_nr parse: field 7 after the LAST ')' ('tmux: server' -> 34816, '(we ird) (na me)' -> 0, 'a) b) c' -> 34817, ppid 4242)" $?
  ! stat_after_comm 'garbage with no paren' 5 >/dev/null; chk "tty_nr parse: a line without ')' is rejected" $?
  cp "$T/seats.pre-nt" "$SEATS_TABLE"   # drop the fake 'nt' row again

  # 17. (10-22 7:00 PM) quota-wait: the plan's usage limit is a wait, not a failure
  local QN1 QR1 QSK QEV QOUT
  QN1="$(TZ=America/Los_Angeles date -d '2026-10-22 18:00' +%s)"; QR1="$(TZ=America/Los_Angeles date -d '2026-10-22 19:10' +%s)"
  QSK="$(jseat r7 .ticks_skipped)"
  rm -f "$T/dash/r7-events.log"; FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1   # normalize: no events, offset 0
  printf 'EV one\nEV two\n' >"$T/dash/r7-events.log"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >"$T/oq1" 2>"$T/eq1"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .last_skip_reason)" = "quota-wait:$(date -d "@$QR1" -Iseconds)" ] && [ "$(jseat r7 .quota_wait_until)" = "$QR1" ] && [ "$(jseat r7 .ticks_skipped)" = "$QSK" ] \
    && grep -qF "seat-tick: r7 quota-wait until $(date -d "@$QR1" '+%-I:%M %p %Z') (session limit)" "$T/eq1"; chk "quota-wait (a): limit line + exit 1 -> exit 0, reason quota-wait:<iso>, quota_wait_until=$QR1, ticks_skipped unchanged ($QSK), stderr line: '$(grep -m1 quota-wait "$T/eq1")'" $?
  [ "$(jseat r7 .last_exit)" = 1 ] && [ "$(jseat r7 .events_offset)" = 0 ]; chk "quota-wait (a): last_exit=1 recorded truthfully, events_offset not advanced (events stay unread)" $?
  QEV="$(jseat r7 .events_new)"
  for qk in tick event ask; do
    rm -f "$T/dash/prompt.r7.txt"
    case "$qk" in tick) qa="" ;; event) qa="--event" ;; ask) qa="--ask hold-this" ;; esac
    # shellcheck disable=SC2086
    SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 $qa >"$T/oq2$qk" 2>"$T/eq2$qk"; rc=$?
    [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oq2$qk" && [ ! -e "$T/dash/prompt.r7.txt" ] && grep -qF "seat-tick: r7 quota-wait in effect until $(date -d "@$QR1" '+%-I:%M %p %Z')" "$T/eq2$qk" \
      && [ "$(jseat r7 .last_skip_reason)" = "quota-wait:$(date -d "@$QR1" -Iseconds)" ] && [ "$(jseat r7 .quota_wait_until)" = "$QR1" ] && [ "$(jseat r7 .events_offset)" = 0 ] && [ "$(jseat r7 .events_new)" = "$QEV" ] && [ "$(jseat r7 .ticks_skipped)" = "$QSK" ]; chk "quota-wait (b): $qk inside the wait -> exit 0, claude not launched, reason/quota_wait_until unchanged, events_offset 0 and events_new $QEV unchanged" $?
  done
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QR1 + 5))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oq3" 2>"$T/eq3"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/oq3" && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .last_skip_reason)" = null ] && [ "$(jseat r7 .last_exit)" = 0 ] && grep -q 'EV one' "$T/dash/prompt.r7.txt"; chk "quota-wait (c): first tick after the wait -> claude runs, quota_wait_until and the reason cleared, the unread events (EV one) delivered" $?
  FAKE_SLEEP=0 FAKE_EXIT=1 "$SELF" r7 >"$T/oq4" 2>"$T/eq4"; rc=$?
  [ "$rc" = 1 ] && [ "$(jseat r7 .last_exit)" = 1 ] && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .last_skip_reason)" = null ] && ! grep -q 'quota-wait' "$T/eq4"; chk "quota-wait (d): exit 1 WITHOUT a limit line -> still exit 1, last_exit=1, no quota-wait" $?
  FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="all your base: resets are fine, nothing at 5 is limited" "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ]; chk "quota-wait (d2): exit 1 with a non-matching 'resets' prose line -> still exit 1" $?
  local QN5 QR5
  QN5="$(TZ=America/Los_Angeles date -d '2026-10-22 23:30' +%s)"; QR5="$(TZ=America/Los_Angeles date -d '2026-10-23 00:05' +%s)"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN5" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 12:05am (America/Los_Angeles)" "$SELF" r7 >"$T/oq5" 2>"$T/eq5"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .quota_wait_until)" = "$QR5" ]; chk "quota-wait (e): 'resets 12:05am' at 11:30 PM -> tomorrow 12:05 AM ($QR5), got $(jseat r7 .quota_wait_until)" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QR5" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1   # clear the wait (now == reset: the wait is over)
  local QN6 QR6
  QN6="$(TZ=America/Los_Angeles date -d '2026-10-22 23:30' +%s)"; QR6="$(TZ=America/Los_Angeles date -d '2026-10-22 23:50' +%s)"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN6" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your usage limit · resets 11:50 PM" "$SELF" r7 >"$T/oq6" 2>"$T/eq6"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .quota_wait_until)" = "$QR6" ] && grep -q '(usage limit)' "$T/eq6"; chk "quota-wait (e2): 'resets 11:50 PM' with no tz and not yet past -> today ($QR6), kind 'usage' named" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QR6" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · try again later" "$SELF" r7 >"$T/oq7" 2>"$T/eq7"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .last_skip_reason)" = "quota-wait:unknown" ] && grep -qF 'seat-tick: r7 quota-wait until unknown (session limit)' "$T/eq7"; chk "quota-wait (f): no reset time -> exit 0, quota_wait_until null, reason quota-wait:unknown" $?
  FAKE_SLEEP=0 "$SELF" r7 >"$T/oq8" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/oq8" && [ "$(jseat r7 .last_skip_reason)" = null ]; chk "quota-wait (f2): the next scheduled tick after an unknown reset simply tries again (claude runs)" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 25:99pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>"$T/eq9"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .last_skip_reason)" = "quota-wait:unknown" ]; chk "quota-wait (f3): out-of-range reset time (25:99pm) -> quota_wait_until null, quota-wait:unknown" $?
  FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>&1
  QOUT="$("$SELF" r7 --status)"
  [ "$(jq -r .quota_wait_until <<<"$QOUT")" = "$QR1" ] && jq -e 'has("quota_wait_until")' <<<"$QOUT" >/dev/null; chk "quota-wait (g): --status shows quota_wait_until=$QR1" $?
  [ "$("$SELF" ctl --status | jq 'has("quota_wait_until")')" = true ]; chk "quota-wait (g2): ctl --status also carries the key" $?
  SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 "$SELF" r7 >"$T/oq10" 2>"$T/eq10"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/oq10"; chk "quota-wait (h): SEAT_NOW_EPOCH is ignored outside selftest mode (the real clock is past the wait, claude runs)" $?
  rm -f "$T/dash/r7-events.log"

  # 17a. (10-23) fleet-token: the wait is recorded WITH the account in use and is ignored once token.json names another account
  rm -f "$T/dash/token.json" "$T/dash/r7-events.log"; FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1   # normalize: clears any wait, no token.json
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>&1
  [ "$(jseat r7 .quota_wait_until)" = "$QR1" ] && [ "$(jseat r7 .quota_account)" = null ] && "$SELF" r7 --status | jq -e 'has("quota_account")' >/dev/null; chk "quota_account (a): no token.json -> quota_account null (key present), quota_wait_until recorded" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oqa1" 2>"$T/eqa1"; rc=$?
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oqa1" && [ "$(jseat r7 .quota_wait_until)" = "$QR1" ]; chk "quota_account (b): wait recorded with no token.json stays in effect while no token.json exists" $?
  printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' >"$T/dash/token.json"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oqa2" 2>"$T/eqa2"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/oqa2" && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .quota_account)" = null ]; chk "quota_account (c): token.json now names acctA but the wait has no account (null != acctA) -> ignored, claude runs, keys clear" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>&1
  [ "$(jseat r7 .quota_wait_until)" = "$QR1" ] && [ "$(jseat r7 .quota_account)" = acctA ]; chk "quota_account (d): limit hit with token.json acctA -> quota_wait_until=$QR1, quota_account=acctA" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oqa3" 2>"$T/eqa3"; rc=$?
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oqa3" && grep -qF "seat-tick: r7 quota-wait in effect until" "$T/eqa3" && [ "$(jseat r7 .quota_account)" = acctA ]; chk "quota_account (e): same account still named -> the wait holds, claude not launched" $?
  printf '{"account":"acctB","placed_at":null,"by":"aide","trigger":"429"}\n' >"$T/dash/token.json"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oqa4" 2>"$T/eqa4"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/oqa4" && [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .quota_account)" = null ] && ! grep -q 'quota-wait in effect' "$T/eqa4"; chk "quota_account (f): token.json rotated to acctB -> the acctA wait is IGNORED, claude runs, quota_wait_until and quota_account clear" $?
  printf '{"account":"acctA"}\n' >"$T/dash/token.json"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QN1" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>&1
  printf 'not json {' >"$T/dash/token.json"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QN1 + 600))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oqa5" 2>"$T/eqa5"; rc=$?
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oqa5" && [ "$(jseat r7 .quota_account)" = acctA ]; chk "quota_account (g): an unreadable token.json ignores nothing (unknown account = the wait holds)" $?
  rm -f "$T/dash/token.json"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QR1 + 5))" FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1   # past the wait: clears it for the blocks below
  [ "$(jseat r7 .quota_wait_until)" = null ] && [ "$(jseat r7 .quota_account)" = null ]; chk "quota_account (h): after the wait both keys are null again" $?
  rm -f "$T/dash/r7-events.log"

  # 17b. (10-22 8:40 PM) ASK QUEUE: an ask that cannot take the lock (or arrives during quota-wait) is queued, never dropped; every prompt drains the queue
  local AKQ="$T/dash/rb-asks.pending" aks0 akp akq_t1 akq_t2 akq_ev akq_n akq_c
  askq_busy() {   # askq_busy <ask text> [env...]: a fake same-seat tick holds the rb lock for 3 s while the ask (SEAT_ASK_LOCK_WAIT=1) runs
    ( exec 8>>"$EVD/rb.lock"; flock 8; sleep 3 ) & ST_PIDS="$ST_PIDS $!"; akp=$!
    sleep 0.4
    env "${@:2}" SEAT_ASK_LOCK_WAIT=1 "$SELF" rb --ask "$1" >"$T/oak" 2>"$T/eak"; rc=$?
    wait "$akp" 2>/dev/null
  }
  rm -f "$AKQ" "$AKQ".consumed-* "$EVD/rb.wake"; : >"$EVD/rb-events.log"
  FAKE_SLEEP=0 "$SELF" rb >/dev/null 2>&1   # normalize: events delivered, no wake, no queue
  aks0="$(jseat rb .sends_total)"
  akq_t1="ruling one: cordon 1025 | \"quoted\" \$dollar"
  akq_t2="ruling two: $(printf 'x%.0s' $(seq 1 200))"
  askq_busy "$akq_t1" EVENT_SOURCE=ctl-test
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oak" && grep -qF "seat-tick: rb ask queued (lock busy 1s): ${akq_t1:0:80}" "$T/eak"; chk "ASK queue: lock held past the ask's wait -> exit 0 (not 5), claude not run, stderr 'ask queued (lock busy 1s): <first 80>'" $?
  [ "$(wc -l <"$AKQ")" = 1 ] && [ "$(jq -r .text "$AKQ")" = "$akq_t1" ] && [ "$(jq -r .from "$AKQ")" = ctl-test ] && [ -n "$(jq -r '.ts // empty' "$AKQ")" ] && [ "$(stat -c %a "$AKQ")" = 600 ]; chk "ASK queue: 1 JSONL record {ts, from=EVENT_SOURCE, text verbatim}, mode 0600" $?
  akq_ev="$(tail -n1 "$EVD/rb-events.log")"
  [[ "$akq_ev" =~ ^[0-9T:+-]+\ \|\ ask-queue\ \|\ ASK-QUEUED\ rb\ [0-9T:+-]+:\ ruling\ one:\ cordon\ 1025 ]]; chk "ASK queue: events log gets '<iso> | ask-queue | ASK-QUEUED rb <ts>: <text>' ($(printf '%s' "$akq_ev" | cut -c1-110))" $?
  [ -e "$EVD/rb.wake" ] && [ "$(jseat rb .sends_total)" = "$aks0" ] && [ "$(jq -r .appended "$EVD/rb-events.json")" -ge 1 ]; chk "ASK queue: .wake touched, sends_total unchanged ($aks0), events.json appended counted" $?
  askq_busy "$akq_t2"
  [ "$rc" = 0 ] && [ "$(wc -l <"$AKQ")" = 2 ] && [ "$(jq -sr '.[1].text' "$AKQ")" = "$akq_t2" ] && [ "$(jq -sr '.[1].from' "$AKQ")" = ask ] && [ "$(jq -sr '.[0].text' "$AKQ")" = "$akq_t1" ]; chk "ASK queue: a second queued ask appends (2 records, order kept, from defaults to 'ask')" $?
  akq_ev="$(tail -n1 "$EVD/rb-events.log")"; akq_ev="${akq_ev#*ASK-QUEUED rb * }"
  [ "${#akq_ev}" = 120 ] && [ "$akq_ev" = "${akq_t2:0:120}" ] && grep -qF "ask queued (lock busy 1s): ${akq_t2:0:80}" "$T/eak" && ! grep -qF "${akq_t2:0:81}" "$T/eak"; chk "ASK queue: event line carries the first 120 chars, stderr the first 80" $?
  [ "$("$SELF" rb --status | jq -r .asks_pending)" = 2 ] && [ "$("$SELF" ctl --status | jq -r .asks_pending)" = 0 ]; chk "ASK queue: --status asks_pending=2 for rb, 0 for ctl" $?
  FAKE_SLEEP=0 "$SELF" rb >"$T/oak3" 2>&1; rc=$?
  akq_n="$(grep -n '^ASKS (queued while busy):$' "$EVD/prompt.rb.txt" | cut -d: -f1)"
  [ "$rc" = 0 ] && [ -n "$akq_n" ] && sed -n "$((akq_n + 1))p" "$EVD/prompt.rb.txt" | grep -qF -- "(from ctl-test): $akq_t1" && sed -n "$((akq_n + 2))p" "$EVD/prompt.rb.txt" | grep -qF -- "(from ask): $akq_t2" \
    && [ "$(grep -n '^EVENTS since ' "$EVD/prompt.rb.txt" | cut -d: -f1)" -lt "$akq_n" ]; chk "ASK queue: next tick prompt = EVENTS block, then 'ASKS (queued while busy):' with both texts in queue order" $?
  akq_c="$(ls "$AKQ".consumed-* 2>/dev/null | wc -l)"
  [ ! -s "$AKQ" ] && [ "$akq_c" = 1 ] && [ "$(wc -l <"$AKQ".consumed-*)" = 2 ] && [ "$("$SELF" rb --status | jq -r .asks_pending)" = 0 ] && grep -q 'queued ask(s) carried in this prompt' "$T/oak3"; chk "ASK queue: queue renamed to .consumed-<epoch> (2 records), asks_pending=0" $?
  FAKE_SLEEP=0 "$SELF" rb >"$T/oak4" 2>&1
  ! grep -q '^ASKS (queued' "$EVD/prompt.rb.txt"; chk "ASK queue: delivered once (the following tick has no ASKS block)" $?
  # a claude that cannot launch leaves the queue alone; a turn that fails after launch puts the asks back
  askq_busy "launch-fail ruling"
  SEAT_CLAUDE_BIN="$T/no-such-claude" FAKE_SLEEP=0 "$SELF" rb >"$T/oak5" 2>&1; rc=$?
  [ "$rc" != 0 ] && [ "$(wc -l <"$AKQ")" = 1 ] && [ "$(ls "$AKQ".consumed-* | wc -l)" = "$akq_c" ] && grep -q 'queued ask(s) stay queued' "$T/oak5"; chk "ASK queue: a tick whose claude cannot launch (exit $rc) leaves the queue intact (1 record, no new .consumed)" $?
  FAKE_EXIT=1 FAKE_SLEEP=0 "$SELF" rb >"$T/oak6" 2>&1; rc=$?
  grep -qF -- "launch-fail ruling" "$EVD/prompt.rb.txt" && [ "$rc" = 1 ] && [ "$(wc -l <"$AKQ")" = 1 ] && [ "$(ls "$AKQ".consumed-* | wc -l)" = "$akq_c" ] && grep -q 'restored to rb-asks.pending' "$T/oak6"; chk "ASK queue: a turn that carried the ask but exits 1 restores it to the queue (no loss; consumed copy removed)" $?
  FAKE_SLEEP=0 "$SELF" rb >"$T/oak7" 2>&1
  [ ! -s "$AKQ" ] && grep -qF -- "launch-fail ruling" "$EVD/prompt.rb.txt" && [ "$(ls "$AKQ".consumed-* | wc -l)" = "$((akq_c + 1))" ]; chk "ASK queue: the next good tick delivers and consumes the restored ask" $?
  # an EVENT turn with no new events still runs for queued asks; an ask that arrives mid-turn (after the snapshot) is kept for the next prompt
  FAKE_SLEEP=0 "$SELF" rb --event >/dev/null 2>&1   # deliver the pending ASK-QUEUED lines first: no new events from here
  printf '{"ts":"2026-10-22T20:30:00-04:00","from":"hand","text":"event-carried ruling"}\n' >"$AKQ"
  FAKE_SLEEP=0 "$SELF" rb --event >"$T/oak8" 2>&1; rc=$?
  grep -q '^ARGV:.* EVENT .*seat=rb' "$T/oak8" && grep -qF -- "event-carried ruling" "$EVD/prompt.rb.txt" && [ ! -s "$AKQ" ]; chk "ASK queue: --event with queued asks runs (even with the events already delivered) and carries the ASKS block" $?
  # quota-wait + ask: queued, not dropped, delivered by the first prompt after the wait
  local QAN QAR QAS
  QAN="$(TZ=America/Los_Angeles date -d '2026-10-22 18:00' +%s)"; QAR="$(TZ=America/Los_Angeles date -d '2026-10-22 19:10' +%s)"
  rm -f "$T/dash/r7-asks.pending"*; : >"$T/dash/r7-events.log"; FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QAN" FAKE_SLEEP=0 FAKE_EXIT=1 FAKE_LIMIT="You've hit your session limit · resets 7:10pm (America/Los_Angeles)" "$SELF" r7 >/dev/null 2>&1
  QAS="$(jseat r7 .sends_total)"
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$QAN" FAKE_SLEEP=0 "$SELF" r7 --ask "quota-time ruling" >"$T/oak9" 2>"$T/eak9"; rc=$?
  [ "$rc" = 0 ] && ! grep -q '^ARGV' "$T/oak9" && grep -qF "seat-tick: r7 ask queued (quota-wait until $(date -d "@$QAR" '+%-I:%M %p %Z')): quota-time ruling" "$T/eak9" && [ "$(wc -l <"$T/dash/r7-asks.pending")" = 1 ] \
    && tail -n1 "$T/dash/r7-events.log" | grep -q 'ask-queue | ASK-QUEUED r7 .*: quota-time ruling' && [ "$(jseat r7 .quota_wait_until)" = "$QAR" ] && [ "$(jseat r7 .sends_total)" = "$QAS" ] && [ -e "$T/dash/r7.wake" ]; chk "ASK queue: ask during quota-wait -> exit 0, queued + ASK-QUEUED event + .wake, claude not run, quota_wait_until kept" $?
  SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$((QAR + 60))" FAKE_SLEEP=0 "$SELF" r7 >"$T/oak10" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^ASKS (queued while busy):$' "$T/dash/prompt.r7.txt" && grep -qF -- "quota-time ruling" "$T/dash/prompt.r7.txt" && [ ! -s "$T/dash/r7-asks.pending" ] && [ "$(jseat r7 .quota_wait_until)" = null ]; chk "ASK queue: the first prompt after the wait carries the quota-time ask, queue consumed, quota_wait_until cleared" $?
  # seat-ask.sh: exit 0 from seat-tick = accepted-or-queued; the queued case is told apart on stderr
  grep -q 'ask queued' "$HERE/seat-ask.sh" && grep -q 'systemd-run --user --collect --unit "\$unit"' "$HERE/seat-ask.sh"; chk "seat-ask.sh: distinguishes a queued ask on stderr, still spawns the same transient unit" $?
  rm -f "$T/dash/r7-events.log" "$T/dash/rb-asks.pending"*

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

  # 10. (10-22 4:00 PM incident) main() wrap, set -u-safe tail, tick count survives a failed tick
  [ "$(grep -c '^main "\$@"$' "$SELF")" = 1 ] && [ "$(grep -c '^main() {$' "$SELF")" = 1 ] && [ "$(tail -n1 "$SELF")" = 'main "$@"' ]; chk "main() wrap: exactly one 'main \"\$@\"' call and it is the last line of the file" $?
  ! sed -n '/^# f\. auth/,$p' "$SELF" | grep -Eq '\$!|\$\{!'; chk "post-turn tail never reads \$! (unbound under set -u when no background job exists)" $?
  mkdir -p "$T/bin" && cp "$HERE/seat-tick.sh" "$HERE/seat-lean.sh" "$HERE/fleet-status-write.sh" "$T/bin/"
  FAKE_CLOBBER="$T/bin/seat-tick.sh" FAKE_SLEEP=1 SEAT_TICK_CHAINED=1 "$T/bin/seat-tick.sh" ctl >"$T/oc1" 2>"$T/ec1"; rc=$?
  [ "$(head -n1 "$T/bin/seat-tick.sh")" = 'echo CLOBBERED' ] && [ "$rc" = 0 ] && ! grep -q CLOBBERED "$T/oc1" "$T/ec1" && grep -q 'ctl tick exit=0 duration' "$T/oc1"; chk "script rewritten in place (400 lines longer) while the turn runs: the running tick still ends cleanly (rc=$rc)" $?
  local cs0 w cpid; cs0="$(j .sends_total)"
  FAKE_SLEEP=2 "$SELF" ctl >"$T/oc2" 2>"$T/ec2" & cpid=$!; ST_PIDS="$ST_PIDS $cpid"
  for w in 1 2 3 4 5 6 7 8 9 10; do grep -q '^START' "$T/oc2" 2>/dev/null && break; sleep 0.5; done
  kill -TERM "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null; sleep 2.5   # the orphaned fake claude holds the seat lock until it ends
  [ "$(j .sends_total)" = "$((cs0 + 1))" ] && [ "$(j .last_exit)" != 0 ] && [ "$(j .last_exit)" != null ] && grep -q 'ABORTED before the end-of-turn save' "$T/ec2"; chk "tick killed mid-turn: sends_total +1 kept (was $cs0, now $(j .sends_total)) and last_exit=$(j .last_exit) recorded by the EXIT trap" $?
  FAKE_SLEEP=0 "$SELF" ctl >/dev/null 2>&1
  [ "$(j .sends_total)" = "$((cs0 + 2))" ] && pl ctl 1 | grep -Eq "tick=$((cs0 + 2)) "; chk "the next tick continues the count (tick=$((cs0 + 2)) in the prompt, not 1)" $?

  # 11. stop-hook bounce counter (10-22): a /goal judge in the resumed session appends `Stop hook` lines to the session JSONL during a -p turn. Fake SID, fixture dir, r7 seat.
  local SJ="$T/jsonl" SHE="$T/dash/r7-events.log" shn
  mkdir -p "$SJ"; rm -f "$T/dash/r7-tick.json" "$T/dash/r7.wake" "$T/dash/r7-asks.pending"*; : >"$SHE"
  shn() { jseat r7 .stop_hook_bounces; }
  shfb() { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\\n%s"}]}}\n' "$1"; }   # a real bounce line
  { shfb 1; echo '{"type":"assistant","message":{"content":[{"type":"text","text":"plain line"}]}}'; shfb 2; shfb 3; } >"$SJ/$SS.jsonl"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_STOPHOOK_FILE="$SJ/$SS.jsonl" FAKE_STOPHOOK_N=2 FAKE_SLEEP=0 "$SELF" r7 >"$T/osh1" 2>"$T/esh1"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 2 ] && [ "$(jseat r7 .stop_hook_lines_before)" = 3 ] && [ "$(jseat r7 .last_exit)" = 0 ]; chk "stop-hook: 3 lines before + 2 appended during the turn -> stop_hook_bounces=2 (before=3), exit 0 unchanged (got '$(shn)' rc=$rc)" $?
  [ "$(grep -c '^ALARM r7 stop-hook bounces=2 (a Stop hook blocked the turn 2 times (a /goal judge or a blocking Stop hook); check: /goal clear under the seat lock if a goal is set; session '"$SS"')$' "$T/esh1")" = 1 ]; chk "stop-hook: ALARM line on stderr, exact text ('$(grep ALARM "$T/esh1" | cut -c1-150)')" $?
  [ "$(grep -c ' | stop-hook | ALARM r7 stop-hook bounces=2 (a Stop hook blocked the turn 2 times (a /goal judge or a blocking Stop hook); check: /goal clear under the seat lock if a goal is set; session '"$SS"')$' "$SHE")" = 1 ] && [ ! -e "$T/dash/r7.wake" ]; chk "stop-hook: the same line appended to r7-events.log (ts | stop-hook | ...), no wake" $?
  "$SELF" r7 --status | jq -e '.stop_hook_bounces == 2 and has("stop_hook_lines_before")' >/dev/null; chk "stop-hook: --status carries stop_hook_bounces (and lines_before)" $?
  # the ALARM event is delivered by the next turn like any event; no new lines -> 0, no ALARM, no new event line
  local shev0; shev0="$(grep -c . "$SHE")"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_SLEEP=0 "$SELF" r7 >"$T/osh2" 2>"$T/esh2"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 0 ] && [ "$(jseat r7 .stop_hook_lines_before)" = 5 ] && ! grep -q 'ALARM' "$T/esh2" && [ "$(grep -c . "$SHE")" = "$shev0" ]; chk "stop-hook: no new lines -> stop_hook_bounces=0, no ALARM, no event appended (got '$(shn)')" $?
  grep -q 'ALARM r7 stop-hook bounces=2' "$T/dash/prompt.r7.txt" && grep -q '^EVENTS since' "$T/dash/prompt.r7.txt"; chk "stop-hook: the alarm event reached the next prompt through the EVENTS block" $?
  # a failing turn keeps its exit code
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_STOPHOOK_FILE="$SJ/$SS.jsonl" FAKE_STOPHOOK_N=4 FAKE_EXIT=7 FAKE_SLEEP=0 "$SELF" r7 >"$T/osh3" 2>"$T/esh3"; rc=$?
  [ "$rc" = 7 ] && [ "$(shn)" = 4 ] && [ "$(jseat r7 .last_exit)" = 7 ] && grep -q '^ALARM r7 stop-hook bounces=4 ' "$T/esh3"; chk "stop-hook: bounces on a failing turn (claude exit 7): alarm, bounces=4, script still exits 7" $?
  # bounces > 0: no EVENT chain (a chained turn would bounce again); the bell that arrived mid-turn stays for the next tick. Control: the same bell with 0 bounces chains.
  : >"$SHE"; rm -f "$T/dash/r7.wake"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_BELL="$T/dash/r7" FAKE_SLEEP=0 "$SELF" r7 >"$T/osh4c" 2>"$T/esh4c"; rc=$?
  [ "$rc" = 0 ] && [ "$(grep -c '^START' "$T/osh4c")" = 2 ] && grep -q 'chaining one EVENT turn' "$T/osh4c"; chk "stop-hook control: a mid-turn bell with 0 bounces still chains one EVENT turn (2 claude runs)" $?
  rm -f "$T/dash/r7.wake"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_BELL="$T/dash/r7" FAKE_STOPHOOK_FILE="$SJ/$SS.jsonl" FAKE_STOPHOOK_N=1 FAKE_SLEEP=0 "$SELF" r7 >"$T/osh4" 2>"$T/esh4"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 1 ] && [ "$(grep -c '^START' "$T/osh4")" = 1 ] && [ -e "$T/dash/r7.wake" ] && ! grep -q 'chaining one EVENT turn' "$T/osh4"; chk "stop-hook: bounces>0 -> no chained EVENT turn (1 claude run, r7.wake left for the next tick)" $?
  rm -f "$T/dash/r7.wake"
  # false positive 10-24 6:50 PM (ctl bounces=4, no goal): a turn that only MENTIONS Stop hooks (assistant text, tool_result) is not a bounce
  : >"$SHE"; rm -f "$T/dash/r7.wake"
  shfb 1 >"$SJ/$SS.jsonl"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_STOPHOOK_FILE="$SJ/$SS.jsonl" FAKE_STOPHOOK_N=0 FAKE_SLEEP=0 FAKE_MENTION_N=3 FAKE_MENTION_FILE="$SJ/$SS.jsonl" "$SELF" r7 >"$T/osh7" 2>"$T/esh7"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 0 ] && [ "$(grep -c 'Stop hook' "$SJ/$SS.jsonl")" = 4 ] && ! grep -q 'ALARM' "$T/esh7" && [ "$(grep -c . "$SHE")" = 0 ]; chk "stop-hook: 3 lines merely mentioning 'Stop hook' (assistant text / tool_result) + 0 feedback lines -> stop_hook_bounces=0, no ALARM (got '$(shn)')" $?
  # missing JSONL -> 0, no error text
  rm -f "$SJ/$SS.jsonl"; : >"$SHE"
  SEAT_TICK_SELFTEST=1 SEAT_JSONL_DIR="$SJ" FAKE_SLEEP=0 "$SELF" r7 >"$T/osh5" 2>"$T/esh5"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 0 ] && [ "$(jseat r7 .stop_hook_lines_before)" = 0 ] && ! grep -qi 'ALARM\|No such file\|error' "$T/esh5"; chk "stop-hook: session JSONL missing -> bounces=0, lines_before=0, no error, no ALARM" $?
  # the dir override is selftest-only: without SEAT_TICK_SELFTEST=1 the real dir is read (the fake SID has no file there), the fixture is ignored
  shfb 1 >"$SJ/$SS.jsonl"
  SEAT_JSONL_DIR="$SJ" FAKE_STOPHOOK_FILE="$SJ/$SS.jsonl" FAKE_STOPHOOK_N=2 FAKE_SLEEP=0 "$SELF" r7 >"$T/osh6" 2>"$T/esh6"; rc=$?
  [ "$rc" = 0 ] && [ "$(shn)" = 0 ] && ! grep -q ALARM "$T/esh6"; chk "stop-hook: SEAT_JSONL_DIR is ignored outside SEAT_TICK_SELFTEST=1 (bounces=0 although the fixture grew by 2)" $?
  grep -q '^JSONL_DIR="\$HOME/.claude/projects/-home-jsy"' "$SELF" && grep -q 'SEAT_TICK_SELFTEST:-}" = 1 \] && \[ -n "${SEAT_JSONL_DIR:-}" \] && JSONL_DIR=' "$SELF"; chk "stop-hook: default JSONL dir is \$HOME/.claude/projects/-home-jsy, override gated on SEAT_TICK_SELFTEST=1" $?
  ! grep -q 'is disab''led in `claude -p`' "$SELF"; chk "the false premise ('goal loop disabled in claude -p') is gone from the header" $?
  rm -f "$T/dash/r7-events.log" "$T/dash/r7.wake"

  # 12. (10-23) max_turns: seats.tsv column 8 -> `--max-turns <N>` after --model; a max-turns end is a NORMAL end (measured: stdout `Error: Reached max turns (<N>)`, exit 1)
  local MT_SID=selftest-mt-sid-$$-0005 MT_SID7=selftest-mt7-sid-$$-0006 MT_SIDJ=selftest-mtj-sid-$$-0007
  cp "$SEATS_TABLE" "$T/seats.pre-mt"
  printf 'mtd\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\t-\nmt7\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\nmtj\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\tabc\n' "$MT_SID" "$MT_SID7" "$MT_SIDJ" >>"$SEATS_TABLE"
  FAKE_SLEEP=0 "$SELF" mtd >"$T/omt1" 2>"$T/emt1"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/omt1" && ! grep -q -- '--max-turns' "$T/omt1" && grep -q -- "--model test-model-r7 $LA --resume $MT_SID " "$T/omt1"; chk "max_turns (a): a row with '-' in column 8 runs with no --max-turns" $?
  FAKE_SLEEP=0 "$SELF" mt7 >"$T/omt2" 2>"$T/emt2"; rc=$?
  [ "$rc" = 0 ] && grep -q '^ARGV' "$T/omt2" && ! grep -q -- '--max-turns' "$T/omt2"; chk "max_turns (b): a 7-column row (old table) runs with no --max-turns" $?
  FAKE_SLEEP=0 "$SELF" mtj >"$T/omt3" 2>"$T/emt3"; rc=$?
  [ "$rc" = 0 ] && ! grep -q -- '--max-turns' "$T/omt3" && grep -q "WARN mtj max_turns 'abc'" "$T/emt3"; chk "max_turns (c): junk in column 8 -> WARN on stderr and no cap (never a bad argv)" $?
  for mtk in "" --event "--ask mt-ask"; do
    rm -f "$T/dash/r7-events.log"; [ "$mtk" = --event ] && printf '%s | selftest | mt event\n' "$(date -Iseconds)" >"$T/dash/r7-events.log"
    # shellcheck disable=SC2086
    FAKE_SLEEP=0 "$SELF" r7 $mtk >"$T/omt4" 2>/dev/null
    grep -Eq -- "^ARGV: -p --dangerously-skip-permissions --model test-model-r7 --max-turns 80 $LA --resume $SS " "$T/omt4"; chk "max_turns (d): r7 ${mtk:-tick} turn: '--max-turns 80' sits between --model and --settings" $?
  done
  rm -f "$T/dash/r7-events.log"
  # the measured max-turns end: exit 0, offset advances, no failure path, counter + stderr line
  FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1   # normalize
  printf '%s | selftest | mt1\n%s | selftest | mt2\n' "$(date -Iseconds)" "$(date -Iseconds)" >"$T/dash/r7-events.log"
  local mtsk; mtsk="$(jseat r7 .ticks_skipped)"
  FAKE_SLEEP=0 FAKE_MAXTURNS=80 "$SELF" r7 >"$T/omt5" 2>"$T/emt5"; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .last_exit)" = 0 ] && [ "$(jseat r7 .max_turns_hits)" = 1 ] && [ "$(jseat r7 .last_skip_reason)" = null ] && [ "$(jseat r7 .ticks_skipped)" = "$mtsk" ] \
    && [ "$(jseat r7 .events_offset)" = "$(stat -c %s "$T/dash/r7-events.log")" ] && grep -qF 'seat-tick: r7 max-turns 80 reached' "$T/emt5" && grep -q -- '--max-turns 80' "$T/omt5" && ! grep -q 'ABORTED\|FAILED' "$T/emt5" "$T/omt5"
  chk "max_turns (e): fake claude prints the measured marker + exits 1 -> unit exit 0, last_exit 0, max_turns_hits=1, events_offset advanced, last_skip_reason null, stderr '$(grep -m1 'max-turns' "$T/emt5")'" $?
  FAKE_SLEEP=0 FAKE_MAXTURNS=80 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .max_turns_hits)" = 2 ]; chk "max_turns (f): a second capped turn -> max_turns_hits=2" $?
  FAKE_SLEEP=0 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(jseat r7 .max_turns_hits)" = 2 ]; chk "max_turns (g): the counter survives a normal turn (still 2)" $?
  "$SELF" r7 --status | jq -e 'has("max_turns_hits")' >/dev/null; chk "max_turns (h): --status carries max_turns_hits" $?
  # not the marker -> still a failure
  FAKE_SLEEP=0 FAKE_EXIT=1 "$SELF" r7 >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && [ "$(jseat r7 .last_exit)" = 1 ] && [ "$(jseat r7 .max_turns_hits)" = 2 ]; chk "max_turns (i): any other exit 1 stays a failure (exit 1, hits unchanged)" $?
  FAKE_SLEEP=0 FAKE_MAXTURNS=80 "$SELF" mtd >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && [ "$(jseat mtd .max_turns_hits)" = 0 ]; chk "max_turns (j): the marker on an UNCAPPED row is not special-cased (exit 1, hits 0)" $?
  cp "$T/seats.pre-mt" "$SEATS_TABLE"; rm -f "$T/dash/r7-events.log"
  local mtbad=""
  mtbad="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF >= 8 && $8 !~ /^(-|[1-9][0-9]*)$/ {print $1 "(" $8 ")"}' "$HOME/.claude/state/seats.tsv" 2>/dev/null)"
  [ -z "$mtbad" ]; chk "real table: column 8 max_turns is absent, '-' or an integer >= 1${mtbad:+: $mtbad}" $?

  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

# ---- run ------------------------------------------------------------------------------------------
# Everything from here to the last line is ONE function, so bash parses the whole body before running any of it: a coder editing this file while a
# tick is running (10-22 3:35-4:00 PM, three commits) can no longer make the running process execute the new file at the old byte offsets. The body is
# deliberately not re-indented (git diff -w shows the change). The last line of the file is the call.
main() {
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
ASKQ="$DASH/$SEAT-asks.pending"; ASKLOCK="$DASH/$SEAT-asks.lock"; EVJ="$DASH/$SEAT-events.json"
ASK_ONE="$(printf '%s' "$ASK_TEXT" | tr '\r\n\t' '   ')"; ASK_CONSUMED=""
SFILE=""; [ "$SEAT" = ctl ] && SFILE="$DASH/fleet-status.md"
status() { cat "$STATE" 2>/dev/null || echo '{}'; }
count_approvals() { [ -r "$APPROVALS" ] && grep -cvE '^[[:space:]]*(#|$)' "$APPROVALS" || true; }
case "$MODE" in
  status) st="$(status)"; jq --argjson n "$(asks_count)" '.asks_pending = $n' <<<"$st" 2>/dev/null || echo "$st"; exit 0 ;;
  guard) why="$(guard)" && { echo "guard: clear ($why)"; exit 0; }; echo "guard: REFUSED $why" >&2; exit 4 ;;
esac
KIND="$MODE"   # tick | ask | event

# ---- one turn -------------------------------------------------------------------------------------
mkdir -p "$DASH" || exit 1
now="$(date +%s)"
iso="$(date -Iseconds)"

# state: every field kept across runs; writes are tmp+mv
sget() { jq -r "$1" <<<"$st" 2>/dev/null; }
# fleet-token (10-23): token.json names the account in use; a quota wait recorded under another account is stale (the rotation changed who is limited)
tok_account() { [ -r "$DASH/token.json" ] && jq -r '.account // empty' "$DASH/token.json" 2>/dev/null || true; }
# (10-23) a rotation clears the whole limit record (wait, kind, account, parse failure) at the NEXT tick: the oneshot unit re-reads the placed token from $OAUTH_ENV every turn (below), so that tick runs on the new account
# load_state: the saved-state read. Called once before the lock (the lock-busy exits save from it) and AGAIN right after `flock 9` is taken: a tick that waited on the lock
# must not carry the pre-wait events_offset / last_exit / cap_kills of the turn it waited behind (five-whys 2026-10-24 r7-cap-killed-turn-minutes, mechanism 2).
load_state() {
st="$(status)"
S_last_sent="$(sget '.last_sent // 0')"; S_skipped="$(sget '.ticks_skipped // 0')"; S_sends="$(sget '.sends_total // 0')"
S_reason="$(sget '.last_skip_reason // ""')"; S_seen="$(sget '.approvals_seen // 0')"; S_exit="$(sget '.last_exit // null')"
S_dur="$(sget '.last_duration_s // null')"; S_kind="$(sget '.last_prompt_kind // ""')"; S_gsince="$(sget '.guard_since // 0')"
S_qw="$(sget '.quota_wait_until // empty')"; [[ "$S_qw" =~ ^[0-9]+$ ]] || S_qw=""
S_qa="$(sget '.quota_account // empty')"
S_qk="$(sget '.quota_kind // empty')"; S_qpf="$(sget '.quota_parse_failed // false')"; [ "$S_qpf" = true ] || S_qpf=false; S_qpt="$(sget '.quota_parse_text // empty')"
S_mth="$(sget '.max_turns_hits // 0')"; [[ "$S_mth" =~ ^[0-9]+$ ]] || S_mth=0
S_ck="$(sget '.cap_kills // 0')"; [[ "$S_ck" =~ ^[0-9]+$ ]] || S_ck=0; S_cs="$(sget '.cap_s // null')"; [[ "$S_cs" =~ ^[0-9]+$ ]] || S_cs=null; S_lck="$(sget '.last_cap_kill // empty')"
if [ -n "$S_qw$S_qk" ] || [ "$S_qpf" = true ]; then _cur_acct="$(tok_account)"; if [ -n "$_cur_acct" ] && [ "$_cur_acct" != "$S_qa" ]; then S_qw=""; S_qa=""; S_qk=""; S_qpf=false; S_qpt=""; fi; fi
S_bounces="$(sget '.stop_hook_bounces // null')"; [[ "$S_bounces" =~ ^[0-9]+$ ]] || S_bounces=null; S_shbefore="$(sget '.stop_hook_lines_before // null')"; [[ "$S_shbefore" =~ ^[0-9]+$ ]] || S_shbefore=null
S_covat="$(sget '.last_covered_at // empty')"; S_covby="$(sget '.last_covered_by // empty')"
S_evoff="$(sget '.events_offset // 0')"; S_lastprompt="$(sget '.last_prompt // 0')"; S_evnew="$(sget '.events_new // 0')"; S_chained="${SEAT_TICK_CHAINED:-0}"
PREV_SENT="$S_last_sent"
}
load_state
EVF="$DASH/$SEAT-events.log"; WAKE="$DASH/$SEAT.wake"; HOLDER="$DASH/$SEAT.lock.holder"
T0="${SEAT_TICK_T0:-$now}"   # first start of this unit run: a chained turn must fit in the same TimeoutStartSec
save() {   # reads the S_* variables
  local tmp; tmp="$(mktemp "$DASH/.$SEAT-tick.XXXXXX")" || return 1
  jq -n --arg seat "$SEAT" --arg iso "$iso" --argjson ep "$now" --argjson ls "$S_last_sent" --argjson sk "$S_skipped" --arg why "$S_reason" \
        --argjson sn "$S_sends" --argjson as "$S_seen" --argjson ex "$S_exit" --argjson du "$S_dur" --arg kind "$S_kind" --arg sf "$SFILE" --argjson gs "$S_gsince" \
        --argjson eo "$S_evoff" --argjson lp "$S_lastprompt" --argjson en "$S_evnew" --argjson ch "$S_chained" --argjson qw "${S_qw:-null}" --arg qa "$S_qa" --arg qk "$S_qk" --argjson qpf "$S_qpf" --arg qpt "$S_qpt" --argjson ap "$(asks_count)" --argjson shb "$S_bounces" --argjson shl "$S_shbefore" --arg cva "$S_covat" --arg cvb "$S_covby" --argjson mth "$S_mth" --argjson ck "$S_ck" --argjson cs "$S_cs" --arg lck "$S_lck" \
    '{seat:$seat, asks_pending:$ap, max_turns_hits:$mth, cap_kills:$ck, cap_s:$cs, last_cap_kill:(if $lck=="" then null else $lck end), stop_hook_bounces:$shb, stop_hook_lines_before:$shl, last_covered_at:(if $cva=="" then null else $cva end), last_covered_by:(if $cvb=="" then null else $cvb end), last_tick:{iso:$iso,epoch:$ep}, last_sent:$ls, ticks_skipped:$sk, last_skip_reason:(if $why=="" then null else $why end),
      sends_total:$sn, last_exit:$ex, last_duration_s:$du, last_prompt_kind:(if $kind=="" then null else $kind end),
      status_file:(if $sf=="" then null else $sf end), approvals_seen:$as,
      guard_since:(if ($why|startswith("guard:")) and $gs>0 then $gs else null end),
      events_offset:$eo, last_prompt:(if $lp>0 then $lp else null end), events_new:$en, chained:$ch, quota_wait_until:$qw, quota_account:(if $qa=="" then null else $qa end), quota_kind:(if $qk=="" then null else $qk end), quota_parse_failed:$qpf, quota_parse_text:(if $qpt=="" then null else $qpt end)}' >"$tmp" && mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
}

# a. the lock serializes ticks and asks: two processes never share the session. A tick gives up fast; an ask must land.
W="$LOCK_WAIT"; [ "$KIND" = ask ] && W="$ASK_LOCK_WAIT"
exec 9>>"$DASH/$SEAT.lock"   # append-open: never truncates (the holder's own file); the holder's identity lives in $HOLDER
if [ "$KIND" = event ]; then   # an EVENT never waits: a running turn will chain one at its end
  if ! flock -n 9; then touch "$WAKE"; echo "seat-tick: $SEAT turn running, EVENT deferred (.wake touched)"; exit 0; fi
elif ! flock -w "$W" 9; then
  echo "seat-tick: $SEAT lock busy after ${W}s, kind=$KIND" >&2
  if [ "$KIND" = ask ]; then   # an ask is never dropped: queue it, the running turn chains an EVENT turn that carries it (or the next prompt does)
    if queue_ask; then echo "seat-tick: $SEAT ask queued (lock busy ${W}s): ${ASK_ONE:0:80}" >&2; exit 0; fi
    echo "seat-tick: $SEAT ask could NOT be queued (cannot write $ASKQ): ${ASK_ONE:0:80}" >&2; exit 1
  fi
  if [ "$KIND" = tick ]; then
    # covered: the holder is a live EVENT/ASK turn of this seat, which is itself a full turn for the seat; the .wake makes it chain one more EVENT turn at its end
    if cov="$(holder_covers)"; then
      touch "$WAKE"; load_state   # fresh read: this save must not write back the pre-wait events_offset / last_exit
      if holder_covers >/dev/null; then   # still alive after the touch: a holder that ended in between left the wake for the next turn, the tick is a plain skip
        S_reason="lock-covered:$cov"; S_covat="$(date -Iseconds)"; S_covby="$cov"; save   # last_exit / last_duration_s stay the last real turn's
        echo "seat-tick: $SEAT tick covered by the running ${cov%%:*} turn (pid ${cov#*:}), .wake touched, no skip counted"
        exit 0
      fi
    fi
    load_state; S_skipped=$((S_skipped + 1)); S_reason="lock-busy"; save
    [ "$S_skipped" -ge "$ALARM_AT" ] && echo "ALARM $SEAT tick skipped $S_skipped ticks (lock busy)" >&2
  fi
  exit 5
fi
note_holder
load_state   # (mechanism 2) the lock is ours: re-read the saved state NOW, never the copy read before a wait behind another turn

# a2. quota-wait in effect: the plan's usage limit has not reset yet, so claude cannot answer. Exit 0 (no unit failure, no bell) BEFORE the guard scan, the events read, the
# prompt and the claude launch: events_offset, the unread events and the .wake file stay exactly as they are for the first turn after the wait.
if [ -n "$S_qw" ] && [ "$(qw_now)" -lt "$S_qw" ]; then
  if [ "$KIND" = ask ]; then   # the ask text is kept for the first prompt after the wait
    if queue_ask; then echo "seat-tick: $SEAT ask queued (quota-wait until $(date -d "@$S_qw" '+%-I:%M %p %Z')): ${ASK_ONE:0:80}" >&2
    else echo "seat-tick: $SEAT ask could NOT be queued (cannot write $ASKQ): ${ASK_ONE:0:80}" >&2; save; exit 1; fi
  fi
  save   # last_tick moves, every other field (reason quota-wait:..., quota_wait_until, ticks_skipped, events_offset) is unchanged
  echo "seat-tick: $SEAT quota-wait in effect until $(date -d "@$S_qw" '+%-I:%M %p %Z')" >&2
  exit 0
fi

# b. guard: the interactive seat still owns the session; never kill, refuse loudly
if why="$(guard)"; then [ "$why" = "no holder" ] || echo "seat-tick: $SEAT guard clear ($why)"; else
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
# b3. queued asks (the same snapshot is shown and later consumed: ASK_BYTES is what the prompt carries; asks queued after this point stay for the next prompt)
ASK_NEW=0; ASK_BLOCK=""; ASK_BYTES=0
if [ -s "$ASKQ" ]; then
  askchunk="$(mktemp "$DASH/.$SEAT-askchunk.XXXXXX")"
  { flock 6; cp -- "$ASKQ" "$askchunk"; } 6>>"$ASKLOCK"
  ASK_BYTES="$(stat -c %s "$askchunk")"
  ASK_NEW="$(grep -c . "$askchunk")"
  if [ "$ASK_NEW" -gt 0 ]; then
    ASK_BLOCK="ASKS (queued while busy):"$'\n'"$(jq -rR '(try fromjson catch null) as $o | (if ($o|type)=="object" then $o else {text:.} end) | "- \(.ts // "?") (from \(.from // "?")): \(.text // "")"' "$askchunk")"
  fi
  rm -f "$askchunk"
fi
if [ "$KIND" = event ] && [ "$EV_NEW" = 0 ] && [ "$ASK_NEW" = 0 ]; then
  rm -f "$WAKE"
  case "$S_reason" in guard:*|lock-covered:*) S_reason=""; S_gsince=0; save ;; esac   # the guard just passed: an earlier refusal is over
  echo "seat-tick: $SEAT EVENT with no new events (already delivered), nothing to do"; exit 0; fi

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
[ -n "$ASK_BLOCK" ] && PROMPT="$PROMPT"$'\n'"$ASK_BLOCK"

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
export WM_SEAT="$SEAT" CLAUDE_SESSION_NAME="$SEAT" WM_DECIDE_AGENT="$SEAT"      # SessionStart hooks (model-role-check.sh, seat-context-start.sh) read the seat from WM_SEAT; WM_DECIDE_AGENT = the seat identity for wm-decide and the gh shim in unit turns (row b7cb)
CAP=$(( TIMEOUT_SEC * 95 / 100 ))
[ "$S_chained" = 1 ] && { left=$(( TIMEOUT_SEC - ($(date +%s) - T0) - 30 )); [ "$left" -lt "$CAP" ] && CAP="$left"; }   # a chained turn must end before the unit's TimeoutStartSec
[ "$CAP" -ge 1 ] || CAP=1
LOG="$DASH/$SEAT-tick-last.log"; [ "$KIND" = ask ] && LOG="$DASH/$SEAT-ask-last.log"; [ "$KIND" = event ] && LOG="$DASH/$SEAT-event-last.log"
echo "seat-tick: $SEAT $KIND model=$MODEL sid=$SID cap=${CAP}s prompt='${PROMPT//$'\n'/ | }'"
start="$(date +%s)"
export SEAT_TURN_DEADLINE=$(( start + CAP - 900 ))   # seat-turn-budget.sh (PreToolUse, claude-seat/settings.json) stops the turn 900 s before the cap kill: ends exit 0, not 124
# the count moves BEFORE the turn (sends_total, last_sent); last_exit / last_duration_s move at its end, or in on_exit if the tail never gets there
S_kind="$KIND"; [ "$SEAT" = ctl ] && [ "$KIND" = tick ] && S_kind=sweep
if [ "$KIND" = tick ]; then S_sends=$((S_sends + 1)); S_last_sent="$start"; fi
now="$start"; iso="$(date -Iseconds)"; S_evnew="$EV_NEW"
TURN_DONE=0; TURN_RC=""
# every precondition passed (lock, guard, goal line, model row): an earlier refusal / cover is over NOW, not when the turn ends (a turn runs for hours; 10-22 r7 showed a
# stale "guard:pid ..." + guard_since for the whole of a turn that had started clean). ticks_skipped still resets only at an exit-0 end.
case "$S_reason" in guard:*|no-goal-line|no-model|lock-covered:*|quota-wait:*) S_reason=""; S_gsince=0 ;; esac   # quota-wait: the wait is over (a2 let this turn through); quota_wait_until itself clears at an exit-0 end
S_shbefore="$(stop_hook_lines "$SID")"   # before the turn: a /goal judge bounce adds `Stop hook` lines to the session file
rm -f "$DASH/$SEAT-inject-stop.$SID" 2>/dev/null   # new turn: seat-ask-inject.sh Stop-block count starts at 0 (Fable 10-24: another Stop hook blocking first would leave a stale count)
pre_ok=1; save || { pre_ok=0; echo "seat-tick: WARN pre-turn state save failed" >&2; }
trap on_exit EXIT
LEAN_ARGV=(); MT_ARGV=()
[ -n "$MAX_TURNS" ] && MT_ARGV=(--max-turns "$MAX_TURNS")   # seats.tsv col 8; empty = no cap
case "$ROLE" in   # rb/r7 only; ctl (and any other role) = default settings, full hook set
  rb|r7) for _kv in $LEAN_ENV_VARS; do export "$_kv"; done
         read -ra LEAN_ARGV <<<"${LEAN_FLAGS//\$HOME/$HOME}" ;;
  controller) if [ -r "$CTL_SETTINGS" ]; then LEAN_ARGV=(--settings "$CTL_SETTINGS"); else echo "seat-tick: WARN $CTL_SETTINGS missing, ctl runs without autoCompactEnabled=true" >&2; fi ;;
esac
# queued asks leave the queue only now: every precondition passed, the pre-turn state is saved and the claude binary resolves (a launch that cannot start leaves the queue as it was)
if [ "$ASK_NEW" -gt 0 ]; then
  if [ "$pre_ok" = 1 ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    asks_consume && [ -n "$ASK_CONSUMED" ] && echo "seat-tick: $SEAT $ASK_NEW queued ask(s) carried in this prompt, queue -> ${ASK_CONSUMED##*/}"
  else echo "seat-tick: $SEAT WARN claude not launchable (or pre-turn save failed): $ASK_NEW queued ask(s) stay queued" >&2; fi
fi
( cd "$HOME" && exec timeout -k 30 "$CAP" "$CLAUDE_BIN" -p --dangerously-skip-permissions --model "$MODEL" "${MT_ARGV[@]}" "${LEAN_ARGV[@]}" --resume "$SID" "$PROMPT" ) 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]:-1}"
# a capped turn ends `Error: Reached max turns (<N>)` with exit 1 (see MAX-TURNS in the header): the seat did its bounded sweep, a normal end
MT_N=""; [ "$rc" != 0 ] && [ -n "$MAX_TURNS" ] && MT_N="$(max_turns_hit "$LOG")"
if [ -n "$MT_N" ]; then S_mth=$(( S_mth + 1 )); echo "seat-tick: $SEAT max-turns $MT_N reached" >&2; echo "seat-tick: $SEAT claude exit=$rc is the max-turns marker: recorded as a normal end (exit 0)"; rc=0; fi
TURN_RC="$rc"
# exit 124 = the cap kill: the turn read the whole prompt (asks + events) for the full cap, so its asks are NOT restored and the events cursor advances below (a restore + kept cursor
# re-delivered the same pile every hour: asks 6 -> 40, events 4 -> 397, five-whys 2026-10-24 r7-cap-killed-turn-minutes). Counted in cap_kills / cap_s for fleet-dash.
CAPKILL=0; [ "$rc" = 124 ] && CAPKILL=1
[ "$rc" = 0 ] || [ "$CAPKILL" = 1 ] || asks_restore   # a failed (or quota-limited) turn never answered the queued asks it carried
end="$(date +%s)"
echo "seat-tick: $SEAT $KIND exit=$rc duration=$((end - start))s"

now="$end"; iso="$(date -Iseconds)"
st="$(status)"; S_skipped="$(sget '.ticks_skipped // 0')"   # re-read: nothing else writes under the lock, but be exact (sends_total / last_sent were written before the turn)
S_exit="$rc"; S_dur=$((end - start))
sh_after="$(stop_hook_lines "$SID")"
if [[ "$S_shbefore" =~ ^[0-9]+$ ]]; then S_bounces=$(( sh_after - S_shbefore )); [ "$S_bounces" -ge 0 ] || S_bounces=0; else S_bounces=0; fi   # a rewritten/compacted file can shrink the count: never negative
[ "$S_bounces" -gt 0 ] && stop_hook_alarm "$S_bounces"
if [ "$CAPKILL" = 1 ]; then
  S_ck=$(( S_ck + 1 )); S_cs="$CAP"; S_lck="$iso"; S_evoff="$NEW_EVOFF"
  echo "seat-tick: $SEAT CAP-KILL #$S_ck: $KIND turn killed at cap=${CAP}s (exit 124); asks not restored, events cursor advanced to $S_evoff" >&2
elif [ "$rc" = 0 ]; then S_ck=0; fi   # cap_kills counts consecutive 124s; an exit-0 end zeroes it
if [ "$rc" = 0 ]; then S_seen="$total"; S_skipped=0; S_reason=""; S_evoff="$NEW_EVOFF"; S_lastprompt="$start"; S_qw=""; S_qa=""; S_qk=""; S_qpf=false; S_qpt=""; fi
# quota-wait: a failed turn whose output is the usage-limit line is not a failure anyone can act on. Not a skip (ticks_skipped untouched), events/approvals/lastprompt
# not advanced, exit 0 so the unit does not fail (no OnFailure bell); a2 then holds the next ticks until the reset. An unparseable reset leaves quota_wait_until null.
if [ "$rc" != 0 ] && quota_hit "$LOG" "$(qw_now)"; then
  qw_now_ep="$(qw_now)"; S_qw=""; S_qa="$(tok_account)"; S_qk=""; S_qpf=false; S_qpt=""; qw_iso="unknown"; qw_txt="unknown"
  if qw_ep="$(quota_reset "$LOG" "$qw_now_ep")"; then
    S_qw="$qw_ep"; qw_iso="$(date -d "@$qw_ep" -Iseconds)"; qw_txt="$(date -d "@$qw_ep" '+%-I:%M %p %Z')"
  else   # limit text without a date the shared parser reads: keep the old fallback (no wait, the next tick tries again), flag it, ALARM (ctl-events.log, the fleet-token ALARM channel)
    S_qpf=true; S_qpt="$(ft_limit_line "$LOG" | tr '\r\n\t' '   ' | LC_ALL=C.UTF-8 sed -E 's/[[:space:]]+$//; s/^(.{0,120}).*/\1/')"   # 120 CHARACTERS (cut -c counts bytes; the "·" is 2)
    ft_alarm "seat $SEAT limit text did not parse (quota_parse_failed, no wait recorded, the next tick retries): ${S_qpt}"
  fi
  S_qk="$(quota_kind "$LOG" "$S_qw" "$qw_now_ep")"
  S_reason="quota-wait:$qw_iso"
  save && TURN_DONE=1
  echo "seat-tick: $SEAT quota-wait until $qw_txt ($(quota_word "$LOG") limit) kind=$S_qk" >&2
  exit 0
fi
save && TURN_DONE=1

# g. chain: a bell that arrived while this turn ran (a .wake file, or log bytes past the delivered offset) is handled now, not at the next 20-min tick.
# Exit-0 turns only (a failing claude must not loop), at most one chain per unit run (SEAT_TICK_CHAINED), and only while half the unit's time budget is left.
if [ "$rc" = 0 ] && [ "$S_chained" != 1 ] && [ "$S_bounces" -le 0 ]; then   # bounces > 0: a chained turn would bounce again
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
}
main "$@"
