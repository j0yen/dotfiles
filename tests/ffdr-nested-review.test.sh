#!/usr/bin/env bash
# ffdr-nested-review.test.sh: A1300 FFDR spec r2 R4.2/R4.3 (test T3). A routed launch from inside a review is refused as nested-dispatch:
# by the inherited SKILL_ROUTE_ROLE=review, or by process identity (an ancestor holding a review session's account-lane claim, pid + start
# time; or a claude / account-lane.py run ancestor whose argv carries a review id). A tmux-server-shaped ancestor or a driver script carrying a
# review id is not a review ancestor; an author worker may launch reviews; the launch's own resumed id is not nested; a review-ancestor
# answer that fails, does not parse or does not arrive within the 10 s bound refuses (fail closed; PB-L3). self-review,
# session-id-grammar and session-reuse refuse before the claim. Each refusal is one denied row, exit 64, nothing started.
# Spy CLI, private lane state and log (fable-launch-review_lib.sh); ancestors are real processes whose argv the test sets with exec -a.
# Run alone: bash tests/ffdr-nested-review.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
refused(){ # NAME WHY: exit 64, nothing started, exactly one denied row (no launch row) whose reason contains WHY
  [ "$(cat "$T/rc.$1")" = 64 ] && flr_spy_empty "$1" && [ "$(flr_count "$1" denied)" = 1 ] && [ "$(flr_count "$1" launch)" = 0 ] \
    && [ "$(wc -l <"$T/new.$1")" = 1 ] && flr_get "$1" .reasons | grep -qF "$2"; }
started(){ [ "$(cat "$T/rc.$1")" = 0 ] && ! flr_spy_empty "$1" && [ "$(flr_count "$1" launch)" = 1 ] && [ "$(flr_count "$1" denied)" = 0 ]; }
# nest NAME REQ ARGV0 [ANCESTOR ARGS...] :: LAUNCHER ARGS...: run the launcher as the child of a process whose argv is [ARGV0, <script>,
# ANCESTOR ARGS...]; the script runs the launcher, then records its rc (two commands, so bash forks the launcher and stays its parent).
nest(){
  local n="$1" r="$2" a0="$3" anc=() before; shift 3
  while [ $# -gt 0 ] && [ "$1" != :: ]; do anc+=("$1"); shift; done; shift
  { echo '#!/usr/bin/env bash'; printf '%q ' "$L" --route-request "$T/req.$r.json" "$@"; printf '2>%q\necho $? >%q\n' "$T/err.$n" "$T/rc.$n"; } >"$T/nest.$n.sh"
  before="$(wc -l <"$DEC")"; : >"$T/spy.$n"
  SPYLOG="$T/spy.$n" bash -c 'exec -a "$0" bash "$@"' "$a0" "$T/nest.$n.sh" "${anc[@]}"
  FLR_RC="$(cat "$T/rc.$n")"; tail -n +"$((before+1))" "$DEC" >"$T/new.$n"
}
flr_begin
SR1="$(uuid)"; flr_req rv T3 "$FX/happy.sha256"; flr_run rv rv --session-id "$SR1" -p x
flr_req au T3; flr_run au au -p x; SA1="$(flr_get au .session)"
ck "setup: a finished review SR1 and a finished author SA1 under T3" '[ "$(flr_get rv .role)" = review ] && [ "$(flr_get au .role)" = author ] && [ "$(cat $T/rc.rv)$(cat $T/rc.au)" = 00 ]'
flr_req au2 T3-B; flr_req rs T3-B "$FX/single.sha256"

# --- R4.2 (a): the inherited role
SKILL_ROUTE_ROLE=review SKILL_ROUTE_SESSION="$SR1" flr_run i1 au2 -p x
ck "inherited SKILL_ROUTE_ROLE=review: an author launch is refused nested-dispatch naming the review session" 'refused i1 "nested-dispatch: launched from inside review session $SR1"'
SKILL_ROUTE_ROLE=review SKILL_ROUTE_SESSION="$SR1" flr_run i2 rs --session-id "$(uuid)" -p x
ck "inherited SKILL_ROUTE_ROLE=review: a review launch is refused too" 'refused i2 "nested-dispatch"'

# --- R4.2 (b): process identity
cat >"$T/w.sh" <<S
#!/usr/bin/env bash
while [ ! -e "$T/go.w" ]; do sleep 0.1; done
$(printf '%q ' "$L" --route-request "$T/req.au2.json" -p x)2>"$T/err.w"
echo \$? >"$T/rc.w"
S
before="$(wc -l <"$DEC")"; : >"$T/spy.w"; SPYLOG="$T/spy.w" bash "$T/w.sh" & WP=$!; FLR_BG+=("$WP"); sleep 0.3
WS="$(cut -d')' -f2- /proc/$WP/stat | awk '{print $20}')"
jq --arg s "$SR1" --argjson p "$WP" --argjson st "$WS" '.sessions[$s].claim={pid:$p,start:$st}' "$ACCOUNT_LANE_STATE/sessions.json" >"$T/ss.tmp" && mv "$T/ss.tmp" "$ACCOUNT_LANE_STATE/sessions.json"
touch "$T/go.w"; wait "$WP"; tail -n +"$((before+1))" "$DEC" >"$T/new.w"
ck "an ancestor whose pid and start time are review SR1's sessions.json claim (argv plain bash): refused nested-dispatch by process identity" 'refused w "nested-dispatch: ancestor process of review session $SR1" && flr_get w .reasons | grep -qF "holds the account-lane claim"'
nest c1 au2 claude --session-id "$SR1" -p x :: -p x
ck "an ancestor with argv[0] claude carrying review SR1's --session-id: refused" 'refused c1 "nested-dispatch: ancestor process of review session $SR1" && flr_get c1 .reasons | grep -qF "(claude)"'
nest c2 au2 python3 -I /x/account-lane.py run --session "$SR1" -- /x/claude --resume "$SR1" :: -p x
ck "an account-lane.py run ancestor carrying review SR1's id: refused" 'refused c2 "nested-dispatch: ancestor process of review session $SR1"'
nest t1 au2 tmux new-session -d -s r7b claude --session-id "$SR1" :: -p x
ck "a tmux-server-shaped ancestor (argv[0] tmux) carrying a finished review's --session-id: allowed" 'started t1'
nest d1 au2 bash -r "$SR1" :: -p x
ck "a driver script taking -r <review sid>: allowed" 'started d1'
# A routed launch from inside a running review worker, its environment markers removed: the review's supervisor is the claim pid.
cat >"$T/claude-nest" <<'S'
#!/usr/bin/env bash
echo "spy role=${SKILL_ROUTE_ROLE:-} session=${SKILL_ROUTE_SESSION:-} scope=${SKILL_ROUTE_SCOPE_ID:-} args=$*" >>"$SPYLOG"
[ -z "${T3_NEST:-}" ] || { SPYLOG="$T3_NEST.spy" bash "$T3_NEST" >"$T3_NEST.out" 2>&1; echo $? >"$T3_NEST.rc"; }
exit 0
S
chmod +x "$T/claude-nest"
mkn(){ # FILE ENV... :: LAUNCHER ARGS...: a nested launch script; its own CLI is the shared spy, so an allowed nested launch never recurses
  local f="$1"; shift; local e=(); while [ "$1" != :: ]; do e+=("$1"); shift; done; shift
  { echo '#!/usr/bin/env bash'; printf '%q ' env -u T3_NEST "${e[@]}" FABLE_CLAUDE_BIN="$T/claude" "$L" --route-request "$@"; echo; } >"$f"; }
SR2="$(uuid)"; NI="$(uuid)"; flr_req rv2 T3-W "$FX/happy.sha256"; flr_req in1 T3-W2
mkn "$T/nest1" -u SKILL_ROUTE_ROLE -u SKILL_ROUTE_SESSION -u SKILL_ROUTE_SCOPE_ID :: "$T/req.in1.json" --session-id "$NI" -p x
before="$(wc -l <"$DEC")"; FABLE_CLAUDE_BIN="$T/claude-nest" T3_NEST="$T/nest1" flr_run w2 rv2 --session-id "$SR2" -p x
ck "review worker SR2 got the R4.1 markers (role review, its own session, its scope_id)" 'grep -qF "spy role=review session=$SR2 scope=$(flr_get w2 "select(.decision==\"launch\") | .scope_id") " "$T/spy.w2"'
ck "a routed launch from inside SR2 with the markers removed: refused by process identity (exit 64, nested-dispatch, nothing started)" '[ "$(cat "$T/nest1.rc")" = 64 ] && [ ! -s "$T/nest1.spy" ] && jq -e --arg s "$NI" "select(.session==\$s) | .decision==\"denied\" and (.reasons|test(\"nested-dispatch: ancestor process of review session $SR2\"))" "$DEC" >/dev/null && [ "$(jq -r --arg s "$NI" "select(.session==\$s) | .decision" "$DEC" | tr "\n" " ")" = "denied " ]'
mkn "$T/nest2" :: "$T/req.in1.json" --session-id "$(uuid)" -p x
flr_req rv4 T3-W3 "$FX/happy.sha256"   # its own task: SR2 under T3-W has completed, so another T3-W review of happy is unchanged-review-replay
FABLE_CLAUDE_BIN="$T/claude-nest" T3_NEST="$T/nest2" flr_run w3 rv4 --session-id "$(uuid)" -p x 2>/dev/null
ck "the same from inside a review worker that keeps its markers: refused by the inherited role" '[ "$(cat "$T/nest2.rc")" = 64 ] && grep -q "nested-dispatch: launched from inside review session" "$T/nest2.out"'
SA2="$(uuid)"; flr_req a2 T3-A; flr_req ar T3-A "$FX/single.sha256"; NR="$(uuid)"
mkn "$T/nest3" :: "$T/req.ar.json" --session-id "$NR" -p x
FABLE_CLAUDE_BIN="$T/claude-nest" T3_NEST="$T/nest3" flr_run w4 a2 --session-id "$SA2" -p x
ck "an author worker (role author, its own session) may launch a review: the nested review starts" '[ "$(cat "$T/nest3.rc")" = 0 ] && grep -qF -- "--session-id $NR" "$T/nest3.spy" && grep -qF "spy role=author session=$SA2 scope= " "$T/spy.w4" && jq -e --arg s "$NR" "select(.session==\$s and .decision==\"launch\") | .role==\"review\"" "$DEC" >/dev/null'
# The launch's own resumed id is never its own ancestor's review: a claude ancestor carrying --resume SR3 resumes SR3 (failed) itself.
SR3="$(uuid)"; flr_req rv3 T3-R "$FX/happy.sha256"; FLR_SPY_RC=1 flr_run rv3 rv3 --session-id "$SR3" -p x
FABLE_LAUNCH_ACK_UNKNOWN_EFFECT=1 nest o1 rv3 claude --resume "$SR3" :: --resume "$SR3" -p again
ck "a claude ancestor carrying the launch's own resumed review id: not nested, the resume continues" 'started o1 && grep -q -- "--resume $SR3" "$T/spy.o1"'
nest o2 au2 claude --resume "$SR3" :: -p x
ck "control: the same ancestor around a different (author) launch is refused" 'refused o2 "nested-dispatch: ancestor process of review session $SR3"'

# --- R4.2 fail closed: a review-ancestor answer that is a non-zero exit, garbage or the wrong shape refuses. The fake reader stands in for
# skill-route-terminal.py through SKILL_ROUTE_TERMINAL (honoured under FABLE_LAUNCH_TEST=1 only; T2 shows production ignores it).
cat >"$T/anc-fake" <<'S'
#!/usr/bin/env python3
import os, sys, time
if "review-ancestor" not in sys.argv[1:]:
    sys.exit(9)
mode = os.environ.get("T3_ANC", "")
if mode == "sleep":
    time.sleep(15)
    mode = "null"
if mode == "exit":
    sys.exit(3)
if mode == "garbage":
    print("not json {")
if mode == "shape":
    print('{"pid": null, "reason": "an answer without review_session"}')
if mode == "null":
    print('{"review_session": null, "pid": null, "reason": "fake: no review ancestor"}')
S
for mode in exit garbage shape; do SKILL_ROUTE_TERMINAL="$T/anc-fake" T3_ANC=$mode flr_run "f$mode" au2 -p x
  ck "review-ancestor answer $mode: refused, nested-dispatch check failed (fail closed)" 'refused f$mode "nested-dispatch check failed"'; done
# A1300 FFDR PB-L3: a reader that hangs (sleeps 15 s, then would answer null) is cut off by the launcher's 10 s bound.
s0=$(date +%s); SKILL_ROUTE_TERMINAL="$T/anc-fake" T3_ANC=sleep flr_run fsleep au2 -p x; s1=$(date +%s)
ck "review-ancestor hangs: refused after the 10 s bound (9 <= elapsed < 15 s), nested-dispatch check failed, nothing started" 'refused fsleep "nested-dispatch check failed" && [ $((s1-s0)) -ge 9 ] && [ $((s1-s0)) -lt 15 ]'
SKILL_ROUTE_TERMINAL="$T/anc-fake" T3_ANC=null flr_run fnull au2 -p x
ck "control: the same fake reader answering review_session null lets the author launch start" 'started fnull'

# --- R4.3: self-review, id grammar, reuse
SKILL_ROUTE_ROLE=author SKILL_ROUTE_SESSION="$SA1" flr_run s1 rv --resume "$SA1" -p x
ck "self-review: a review resuming the caller's own session (SKILL_ROUTE_SESSION) is refused" 'refused s1 "self-review: review launch id $SA1"'
SX="$(uuid)"; SKILL_ROUTE_ROLE=author SKILL_ROUTE_SESSION="$SX" flr_run s2 rs --session-id "$SX" -p x
ck "self-review: a fresh review whose pre-drawn id is the caller's own session is refused" 'refused s2 "self-review"'
flr_run g1 au2 --session-id AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE -p x
ck "session-id-grammar: an uppercase pre-drawn id is refused (author)" 'refused g1 "session-id-grammar"'
flr_run g2 rs --session-id 0123456789abcdef0123456789abcdef0123 -p x
ck "session-id-grammar: a 36-character id that is not 8-4-4-4-12 is refused (review; the base pattern [0-9a-f-]{36} admitted it)" 'refused g2 "session-id-grammar"'
flr_run g3 au2 "--session-id=$(uuid)x" -p x
ck "session-id-grammar: the --session-id= form with a trailing character is refused" 'refused g3 "session-id-grammar"'
flr_run r1 au2 --session-id "$SA1" -p x
ck "session-reuse: a fresh author launch reusing a logged id (its process gone) is refused" 'refused r1 "session-reuse: pre-drawn --session-id $SA1 already appears in a launch row"'
flr_run r2 rs --session-id "$SR1" -p x
ck "session-reuse: a fresh review launch reusing a logged id is refused" 'refused r2 "session-reuse"'
ck "no token in stderr, spy args or any row" '! grep -q TOKEN- "$T"/err.* "$T"/spy.* "$DEC"'
flr_end
