#!/usr/bin/env bash
# tests/seat-tick-weekly-quota.test.sh -- seat-tick parses WEEKLY limit text through the ONE parser (fleet-token-lib.sh ft_parse_la_date) and a rotation clears the wait.
#
# Trigger (10-23 2:39 PM): the seats hit "You've hit your weekly limit · resets Oct 26, 9pm" on jyen.tech; seat-tick's private parser matched only `resets H:MMam|pm`,
# so quota_wait_until stayed null and the 429 watcher never saw a limit.
#
# TIMEZONE: ft_parse_la_date HARDCODES America/Los_Angeles (FT_LA_TZ in the lib). It never reads the "(America/...)" paren and never the host TZ. Every expected epoch
# below is an America/Los_Angeles wall-clock time (PDT = UTC-7 until 2026-11-01, PST = UTC-8 after); each is annotated where it appears.
#
# ISOLATION: everything runs under a mktemp -d below ~/.cache/tmp with HOME, XDG_STATE_HOME, XDG_CACHE_HOME, XDG_CONFIG_HOME, FLEET_DASH_DIR and FLEET_TOKEN_STATE_DIR
# pointed into it; the "claude" is a fake that records only a sha8 of the token. No systemctl, no real token store, no real fleet-dash. Fake tokens, never printed.
# Run: bash tests/seat-tick-weekly-quota.test.sh      (~1 min)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/.local/bin"; lib="$root/.local/lib/fleet-token-lib.sh"; SELF="$bin/seat-tick.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
# NOTE: the status is captured into _s BEFORE chk is called: a $(...) inside the message would otherwise reset $? to 0 and turn every failing case into a PASS
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

REAL_HOME="$HOME"; mkdir -p "$REAL_HOME/.cache/tmp"
T="$(mktemp -d "$REAL_HOME/.cache/tmp/seat-tick-weekly.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/home/.local/state" XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" \
       FLEET_TOKEN_STATE_DIR="$T/home/.local/state/fleet-token" FLEET_DASH_DIR="$T/dash"
mkdir -p "$HOME/.config/claude-seat" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$FLEET_TOKEN_STATE_DIR" "$T/dash"
for f in ctl-settings.json settings.json mcp.json; do echo '{}' >"$HOME/.config/claude-seat/$f"; done
unset FLEET_TOKEN_NOW_EPOCH FLEET_TOKEN_SELFTEST SEAT_NOW_EPOCH SEAT_LEAN CLAUDE_LEAN_START CLAUDE_CODE_OAUTH_TOKEN

# --- the same fixture as seat-tick's own selftest, cut down to the r7 seat ---
SID="selftest-r7-sid-$$-0003"
export SEATS_TABLE="$T/seats.tsv" MRC_TABLE="$T/mrc" GOAL_MD="$T/notes/wiki/goal.md" APPROVALS_FILE="$T/approvals.log" \
       SEAT_CLAUDE_BIN="$T/claude" SEAT_OAUTH_ENV="$T/oauth.conf" SEAT_LOCK_WAIT=1 SEAT_ASK_LOCK_WAIT=1
printf '# test table\nr7\tr7\t%s\t20\t14400\t^/goal CLEARWATER-R7\t-\t80\n' "$SID" >"$SEATS_TABLE"
printf 'r7 test-model-r7\n' >"$MRC_TABLE"
printf '# c1\n\nl1\n' >"$APPROVALS_FILE"
G="git -c user.name=t -c user.email=t@t.invalid"
git init -q --bare -b main "$T/remote.git" && git clone -q "$T/remote.git" "$T/notes" 2>/dev/null && mkdir -p "$T/notes/wiki"
printf '# goal.md (test)\n/goal CLEARWATER-R7 (carbon seat, ryzen7 only) v1\n' >"$GOAL_MD"
( cd "$T/notes" && $G add -A && $G commit -qm v1 && $G push -q -u origin HEAD:main ) >/dev/null 2>&1
cat >"$SEAT_CLAUDE_BIN" <<'FAKE'
#!/bin/bash
# records sha8 of the token this turn ran with (never the token), prints FAKE_LIMIT, exits FAKE_EXIT
printf 'run sha8=%s\n' "$(printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | sha256sum | cut -c1-8)" >>"$FLEET_DASH_DIR/fake-claude.log"
[ -n "${FAKE_LIMIT:-}" ] && printf '%s\n' "$FAKE_LIMIT"
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$SEAT_CLAUDE_BIN"
sha8() { printf '%s' "$1" | sha256sum | cut -c1-8; }
setoauth() { printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$1" >"$SEAT_OAUTH_ENV"; }
settoken() { printf '{"account":"%s","placed_at":null,"by":"test","trigger":"seed"}\n' "$1" >"$T/dash/token.json"; }   # shaped like fleet-token-rotate.sh's token.json
setoauth faketokA
jseat() { jq -r "$1" "$T/dash/r7-tick.json"; }
runs() { grep -c '^run ' "$T/dash/fake-claude.log" 2>/dev/null || echo 0; }
# tick <now-epoch> [env...]: one r7 tick on the fake clock; FAKE_EXIT/FAKE_LIMIT come in as env
tick() { local now="$1"; shift; env SEAT_TICK_SELFTEST=1 SEAT_NOW_EPOCH="$now" FAKE_SLEEP=0 "$@" "$SELF" r7 >"$T/o" 2>"$T/e"; }
# a tick inside a recorded wait is parked (a2 gate) and never re-reads the limit text: every `limit` first runs a clean exit-0 turn 200 days out, which clears any wait/kind/account/parse-failure
limit() { local now="$1" txt="$2"; tick "$((now + 200 * 86400))"; tick "$now" FAKE_EXIT=1 FAKE_LIMIT="$txt"; }

# the clock for the cases: Fri 2026-10-23 14:39:00 PDT (America/Los_Angeles) = 1792791540
NOW=1792791540
tick "$NOW"; [ "$?" = 0 ]; _s=$?; chk "fixture: a plain r7 tick runs the fake claude (exit 0)" $_s

# --- 1. the exact string from the incident ---
limit "$NOW" "You've hit your weekly limit · resets Oct 26, 9pm"; rc=$?
# expected 1793073600 = Mon 2026-10-26 21:00 PDT (America/Los_Angeles is HARDCODED in ft_parse_la_date; the host TZ and any "(tz)" text are ignored)
[ "$rc" = 0 ] && [ "$(jseat .quota_wait_until)" = 1793073600 ] && [ "$(jseat .quota_kind)" = weekly ] && [ "$(jseat .quota_parse_failed)" = false ]; _s=$?; chk "weekly: \"You've hit your weekly limit · resets Oct 26, 9pm\" at 2026-10-23 14:39 PDT -> quota_wait_until=1793073600 (Oct 26 21:00 PDT, LA) quota_kind=weekly (got $(jseat .quota_wait_until) $(jseat .quota_kind))" $_s
grep -qF 'seat-tick: r7 quota-wait until' "$T/e" && grep -qF '(weekly limit) kind=weekly' "$T/e"; _s=$?; chk "weekly: stderr names the weekly limit and kind=weekly" $_s
[ "$(jseat .last_skip_reason)" = "quota-wait:2026-10-26T21:00:00-07:00" ]; _s=$?; chk "weekly: last_skip_reason=quota-wait:2026-10-26T21:00:00-07:00 (got $(jseat .last_skip_reason))" $_s
# the wait holds: a tick 3 days later (Sun 2026-10-25 14:39 PDT, still before Mon 21:00 PDT) does not launch claude
before="$(runs)"; tick "$((NOW + 2 * 86400))"
[ "$(runs)" = "$before" ] && grep -q 'quota-wait in effect' "$T/e" && [ "$(jseat .quota_wait_until)" = 1793073600 ]; _s=$?; chk "weekly: a 2-day-later tick is still parked (no cap on the wait, claude not launched)" $_s
# 8 days later is still before a 9 day wait: build one (Nov 1, 2026 21:00 is PDT->PST night; use the PST side: Nov 10 9pm = 2026-11-10 21:00 PST = 1794373200)
limit "$NOW" "You've hit your weekly limit · resets Nov 10, 9pm"
# expected 1794373200 = Tue 2026-11-10 21:00 PST (America/Los_Angeles hardcoded; PST = UTC-8 after the 2026-11-01 fall-back), 18.3 days out
[ "$(jseat .quota_wait_until)" = 1794373200 ]; _s=$?; chk "weekly: an 18-day wait (Nov 10, 9pm PST = 1794373200) is recorded in full, not dropped or clamped (got $(jseat .quota_wait_until))" $_s
before="$(runs)"; tick "$((NOW + 9 * 86400))"
[ "$(runs)" = "$before" ] && grep -q 'quota-wait in effect' "$T/e"; _s=$?; chk "weekly: 9 days into an 18-day wait the seat is still parked (no 8-day cap)" $_s

# --- 2. session texts ---
limit "$NOW" "You've hit your session limit · resets 7:10pm (America/Los_Angeles)"
# expected 1792807800 = Fri 2026-10-23 19:10 PDT (LA hardcoded; the paren is dropped, not honoured)
[ "$(jseat .quota_wait_until)" = 1792807800 ] && [ "$(jseat .quota_kind)" = session ]; _s=$?; chk "session: 'resets 7:10pm' at 14:39 PDT -> 1792807800 (19:10 PDT, LA), kind session (got $(jseat .quota_wait_until) $(jseat .quota_kind))" $_s
limit "$NOW" "You've hit your session limit · resets 9pm"
# expected 1792814400 = Fri 2026-10-23 21:00 PDT (LA hardcoded)
[ "$(jseat .quota_wait_until)" = 1792814400 ] && [ "$(jseat .quota_kind)" = session ]; _s=$?; chk "session: 'resets 9pm' -> 1792814400 (21:00 PDT, LA), kind session (got $(jseat .quota_wait_until) $(jseat .quota_kind))" $_s
# no phrase at all, a bare reset clause: kind by wait length (<= 24 h = session)
limit "$NOW" "Claude usage limit reached · resets 9pm"
[ "$(jseat .quota_wait_until)" = 1792814400 ] && [ "$(jseat .quota_kind)" = session ]; _s=$?; chk "kind: a bare 'resets 9pm' (no 'hit your ... limit' words, 6 h out) -> session by wait length" $_s

# --- 3. year roll (weekly) and day roll (session) ---
# now = Tue 2026-12-22 20:26:00 PST (America/Los_Angeles) = 1797999960
limit 1797999960 "You've hit your weekly limit · resets Jan 3, 9am"
# expected 1798995600 = Sun 2027-01-03 09:00 PST (LA hardcoded, UTC-8): January in a December clock is NEXT year
[ "$(jseat .quota_wait_until)" = 1798995600 ] && [ "$(jseat .quota_kind)" = weekly ]; _s=$?; chk "weekly year roll: now 2026-12-22 20:26 PST, 'resets Jan 3, 9am' -> 1798995600 (2027-01-03 09:00 PST, LA) kind weekly (got $(jseat .quota_wait_until))" $_s
# now = Fri 2026-10-23 23:30:00 PDT (LA) = 1792823400; 12:05am is already past today -> tomorrow
limit 1792823400 "You've hit your session limit · resets 12:05am"
# expected 1792825500 = Sat 2026-10-24 00:05 PDT (LA hardcoded)
[ "$(jseat .quota_wait_until)" = 1792825500 ] && [ "$(jseat .quota_kind)" = session ]; _s=$?; chk "session day roll: now 23:30 PDT, 'resets 12:05am' -> 1792825500 (tomorrow 00:05 PDT, LA) (got $(jseat .quota_wait_until))" $_s
# the rolled wait is over at its epoch: the tick at 1792825500 runs and clears everything
before="$(runs)"; tick 1792825500
[ "$(runs)" = "$((before + 1))" ] && [ "$(jseat .quota_wait_until)" = null ] && [ "$(jseat .quota_kind)" = null ] && [ "$(jseat .quota_account)" = null ]; _s=$?; chk "the first tick at the reset epoch runs claude and clears quota_wait_until / quota_kind / quota_account" $_s

# --- 4. unparseable limit text: the old fallback stays, the failure is recorded and alarmed ---
rm -f "$T/dash/ctl-events.log"
long="You've hit your weekly limit · resets Smarch 45, 99pm $(printf 'x%.0s' $(seq 1 150))"
limit "$NOW" "$long"; rc=$?
[ "$rc" = 0 ] && [ "$(jseat .quota_wait_until)" = null ] && [ "$(jseat .last_skip_reason)" = "quota-wait:unknown" ] && [ "$(jseat .quota_parse_failed)" = true ] && [ "$(jseat .quota_kind)" = weekly ]; _s=$?; chk "unparseable: exit 0, quota_wait_until null (old fallback: quota-wait:unknown), quota_parse_failed=true" $_s
pt="$(jseat .quota_parse_text)"; [ "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' _ "$pt")" = 120 ] && [ "$pt" = "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${1:0:120}"' _ "$long")" ]; _s=$?; chk "unparseable: quota_parse_text is the limit line cut to exactly 120 chars" $_s
grep -q 'ALARM fleet-token: seat r7 limit text did not parse (quota_parse_failed' "$T/dash/ctl-events.log"; _s=$?; chk "unparseable: one ALARM line in ctl-events.log (the file fleet-dash's alarm_events relays to ctl)" $_s
tick "$((NOW + 60))"
[ "$(jseat .quota_parse_failed)" = false ] && [ "$(jseat .quota_parse_text)" = null ] && [ "$(runs)" -gt 0 ]; _s=$?; chk "unparseable: the next tick retries (claude runs) and the next exit-0 turn clears quota_parse_failed / quota_parse_text" $_s
limit "$NOW" "You've hit your session limit · try again later"
[ "$(jseat .quota_parse_failed)" = true ] && [ "$(jseat .quota_parse_text)" = "You've hit your session limit · try again later" ]; _s=$?; chk "unparseable: a limit line with NO reset text at all is also flagged" $_s
tick "$((NOW + 60))"
# a prose 'resets' line is not a limit
tick "$NOW" FAKE_EXIT=1 FAKE_LIMIT="all your base: resets are fine, nothing at 5 is limited"; rc=$?
[ "$rc" = 1 ] && [ "$(jseat .quota_parse_failed)" = false ]; _s=$?; chk "non-limit prose containing 'resets' is still a plain failure (exit 1, no quota-wait, no parse-failed)" $_s
tick "$NOW"

# --- 5. account change clears the wait ---
settoken acctA
limit "$NOW" "You've hit your weekly limit · resets Oct 26, 9pm"
[ "$(jseat .quota_account)" = acctA ] && [ "$(jseat .quota_wait_until)" = 1793073600 ]; _s=$?; chk "account: the weekly limit is recorded with quota_account=acctA (read from token.json .account)" $_s
before="$(runs)"; tick "$((NOW + 600))"
[ "$(runs)" = "$before" ] && [ "$(jseat .quota_account)" = acctA ]; _s=$?; chk "account: token.json still acctA -> the wait holds" $_s
settoken acctB
tick "$((NOW + 600))"
[ "$(runs)" = "$((before + 1))" ] && [ "$(jseat .quota_wait_until)" = null ] && [ "$(jseat .quota_kind)" = null ] && [ "$(jseat .quota_account)" = null ]; _s=$?; chk "account: token.json now acctB -> quota_wait_until, quota_kind, quota_account cleared, claude ran" $_s
# parse-failed is cleared by an account change too
settoken acctA; limit "$NOW" "You've hit your weekly limit · resets Smarch 45, 99pm"
[ "$(jseat .quota_parse_failed)" = true ] && [ "$(jseat .quota_account)" = acctA ]; _s=$?; chk "account: an unparseable weekly limit under acctA records quota_account=acctA and quota_parse_failed" $_s
settoken acctB; tick "$((NOW + 600))"
[ "$(jseat .quota_parse_failed)" = false ] && [ "$(jseat .quota_parse_text)" = null ]; _s=$?; chk "account: acctB -> quota_parse_failed / quota_parse_text cleared" $_s

# --- 6. rotation: a weekly block, then fleet-token-rotate's token.json + placed token; the next tick runs ON THE NEW TOKEN and the wait is gone ---
setoauth faketokA; settoken acctA
limit "$NOW" "You've hit your weekly limit · resets Oct 26, 9pm"
[ "$(jseat .quota_wait_until)" = 1793073600 ] && [ "$(jseat .quota_account)" = acctA ]; _s=$?; chk "rotation: weekly block on acctA, parked until 1793073600 (Oct 26 21:00 PDT, LA)" $_s
before="$(runs)"; tick "$((NOW + 1200))"
[ "$(runs)" = "$before" ]; _s=$?; chk "rotation: before the rotation the next tick is parked (claude not launched)" $_s
# what fleet-token-rotate.sh does: place the new token (environment.d file) + write token.json {account,...} + start seat-tick@ units
setoauth faketokB; settoken acctB
: >"$T/dash/fake-claude.log"
tick "$((NOW + 1260))"; rc=$?
[ "$rc" = 0 ] && [ "$(runs)" = 1 ] && [ "$(jseat .quota_wait_until)" = null ] && [ "$(jseat .quota_kind)" = null ] && [ "$(jseat .quota_account)" = null ] && [ "$(jseat .last_skip_reason)" = null ]; _s=$?; chk "rotation: the tick after the rotation runs claude, quota_wait_until / quota_kind / quota_account / last_skip_reason all cleared (seat not parked on the multi-day wait)" $_s
grep -q "sha8=$(sha8 faketokB)\$" "$T/dash/fake-claude.log" && ! grep -q "sha8=$(sha8 faketokA)\$" "$T/dash/fake-claude.log"; _s=$?; chk "rotation: that turn ran with the NEW token (seat-tick re-sources \$OAUTH_ENV every tick; a oneshot unit needs no restart)" $_s
! grep -q '^run' "$T/o" && ! grep -q 'faketok' "$T/o" "$T/e"; _s=$?; chk "rotation: no token text on the tick's stdout/stderr" $_s
tick "$((NOW + 1300))" ; [ "$(runs)" = 2 ]; _s=$?; chk "rotation: and the seat keeps running on later ticks" $_s

# --- 7. the shared parser: injected now (2nd argument, or FLEET_TOKEN_NOW_EPOCH with FLEET_TOKEN_SELFTEST=1) ---
( . "$lib"; ft_paths
  # all of these: America/Los_Angeles hardcoded (FT_LA_TZ)
  [ "$(ft_parse_la_date "resets Oct 26, 9pm" 1792791540)" = 1793073600 ] &&                    # Mon 2026-10-26 21:00 PDT
  [ "$(ft_parse_la_date "You've hit your weekly limit · resets Oct 26, 9pm" 1792791540)" = 1793073600 ] &&
  [ "$(ft_parse_la_date "resets 7:10pm" 1792791540)" = 1792807800 ] &&                          # Fri 2026-10-23 19:10 PDT
  [ "$(ft_parse_la_date "resets 7:10pm (America/New_York)" 1792791540)" = 1792807800 ] &&       # the paren is dropped: still LA
  [ "$(ft_parse_la_date "resets Jan 3, 9am" 1797999960)" = 1798995600 ] &&                      # Sun 2027-01-03 09:00 PST
  [ "$(ft_parse_la_date "resets 12:05am" 1792823400)" = 1792825500 ]                            # Sat 2026-10-24 00:05 PDT
); _s=$?; chk "lib: ft_parse_la_date <text> <now> takes an injected now (weekly, session, tz paren ignored, year roll, day roll)" $_s
( . "$lib"; ft_paths; export FLEET_TOKEN_SELFTEST=1 FLEET_TOKEN_NOW_EPOCH=1792791540
  [ "$(ft_parse_la_date "resets Oct 26, 9pm")" = 1793073600 ] && [ "$(ft_parse_la_date "resets 7:10pm")" = 1792807800 ]
); _s=$?; chk "lib: the env form (FLEET_TOKEN_NOW_EPOCH under FLEET_TOKEN_SELFTEST=1) injects the same now" $_s
( . "$lib"; ft_paths; ! ft_parse_la_date "resets Smarch 45, 99pm" 1792791540 >/dev/null && ! ft_parse_la_date "resets 25:99pm" 1792791540 >/dev/null && ! ft_parse_la_date "" 1792791540 >/dev/null ); _s=$?; chk "lib: unparseable text returns 1 and prints nothing" $_s

# --- 8. no drift: seat-tick has no reset regex of its own and calls the shared parser ---
code="$(awk '/^selftest\(\) \{$/{s=1} !s{print} /^}$/{s=0}' "$SELF" | grep -v -E '^[[:space:]]*#')"
! grep -qi 'resets' <<<"$code"; _s=$?; chk "no-drift: seat-tick.sh code (outside comments and its selftest) has no 'resets' pattern of its own" $_s
grep -q 'ft_parse_la_date' <<<"$code" && grep -q 'fleet-token-lib.sh' <<<"$code"; _s=$?; chk "no-drift: seat-tick.sh sources fleet-token-lib.sh and calls ft_parse_la_date" $_s
! grep -q -E '(am\|pm|\(am\|pm\)|\[ap\]m)' <<<"$code"; _s=$?; chk "no-drift: seat-tick.sh code has no am|pm time regex" $_s

# --- 9. the 429 watcher blocks quota_account and never clamps a long wait (its own selftest carries the 9-day case) ---
grep -q 'ft_block "\$limacct"' "$bin/fleet-token-429-watch.sh"; _s=$?; chk "watcher: ft_block takes the seats' quota_account (limacct), not a re-read of the current account" $_s

[ "$fail" = 0 ] && echo "SELFTEST PASS seat-tick-weekly-quota" || echo "SELFTEST FAIL seat-tick-weekly-quota"
exit "$fail"
