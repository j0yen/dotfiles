#!/usr/bin/env bash
# fable-launch-review AC 8: role never changes route, model, effort or account (R7); conflicts still 64; no token leaks; a routed SID-guard
# refusal and an unopenable guard lock are 73 with a denied row (R11). Run alone: bash tests/fable-launch-review_ac08_route_account.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
SR="$(uuid)"; flr_req rv A8 "$FX/happy.sha256"; flr_run r rv --session-id "$SR" -p x
flr_req au A8; flr_run a au -p x
ck "review and author with one task, skill and decision_class both launch" '[ "$(cat $T/rc.r)" = 0 ] && [ "$(cat $T/rc.a)" = 0 ] && [ "$(flr_get r .role)" = review ] && [ "$(flr_get a .role)" = author ]'
ck "their rows carry the same route, model and effort; each account is its nonfable round-robin slot (review 0, author 1), not chosen by role" '[ "$(flr_get r "[.route,.model,.effort]|join(\",\")")" = "$(flr_get a "[.route,.model,.effort]|join(\",\")")" ] && [ "$(flr_get r .account)" = "$(flr_nf 0)" ] && [ "$(flr_get a .account)" = "$(flr_nf 1)" ]'
ck "the spy got the same model and effort for both, each under the account its row records" '[ "$(grep -o "acct=[^ ]*" "$T/spy.r")" = "acct=$(flr_get r .account)" ] && [ "$(grep -o "acct=[^ ]*" "$T/spy.a")" = "acct=$(flr_get a .account)" ] && grep -q -- "--model claude-opus-5-5" "$T/spy.r" && grep -q -- "--effort xhigh" "$T/spy.r" && grep -q -- "--model claude-opus-5-5" "$T/spy.a" && grep -q -- "--effort xhigh" "$T/spy.a"'
# A1300 FFDR PA-L1: the opposite order (author first, then review) under another task. Each account is still the next round-robin slot
# (2, then 3), so a launcher that maps role to account (review -> primaries[0], author -> primaries[1]) fails here although it fits the pair above.
flr_req au3 A8-R; flr_run a2 au3 -p x
SR2="$(uuid)"; flr_req rv3 A8-R "$FX/happy.sha256"; flr_run r2 rv3 --session-id "$SR2" -p x
ck "opposite order under another task (author, then review): both launch; the author takes round-robin slot 2 and the review slot 3, each seen by the CLI" '[ "$(cat $T/rc.a2)" = 0 ] && [ "$(cat $T/rc.r2)" = 0 ] && [ "$(flr_get a2 .role)" = author ] && [ "$(flr_get r2 .role)" = review ] && [ "$(flr_get a2 .account)" = "$(flr_nf 2)" ] && [ "$(flr_get r2 .account)" = "$(flr_nf 3)" ] && [ "$(grep -o "acct=[^ ]*" "$T/spy.a2")" = "acct=$(flr_nf 2)" ] && [ "$(grep -o "acct=[^ ]*" "$T/spy.r2")" = "acct=$(flr_nf 3)" ]'
# The conflict vectors use a scope with no prior review (A1300 FFDR O3): beside SR's completed review of happy, a same-scope launch is also
# refused as unchanged-review-replay, so rc 64 alone would not show the conflict; the denied row must carry the resolver's conflict reason.
flr_req rvc A8 "$FX/single.sha256"
flr_run cm rvc --session-id "$(uuid)" --model claude-fable-5-1 -p x
ck "review request with a conflicting --model (Fable, off the Opus route): 64, nothing started, the conflict reason" '[ "$FLR_RC" = 64 ] && flr_spy_empty cm && [ "$(flr_count cm denied)" = 1 ] && flr_get cm .reasons | grep -qF "requested claude-fable-5-1/- does not match the resolved route claude-opus-5-5/xhigh"'
flr_run ce rvc --session-id "$(uuid)" --effort high -p x
ck "review request with a conflicting --effort: 64, nothing started, the conflict reason" '[ "$FLR_RC" = 64 ] && flr_spy_empty ce && [ "$(flr_count ce denied)" = 1 ] && flr_get ce .reasons | grep -qF "requested -/high does not match the resolved route claude-opus-5-5/xhigh"'
SX="$(uuid)"; flr_live "$SX"; LX=$FLR_LIVE
flr_run sg rv --session-id "$SX" -p x
ck "routed launch whose pre-drawn id a non-ancestor sleep carries: 73, nothing started" '[ "$FLR_RC" = 73 ] && flr_spy_empty sg'
ck "that refusal is a denied row naming the pid, with the derived review fields" '[ "$(flr_count sg denied)" = 1 ] && flr_get sg .reasons | grep -qE "pid $LX( |\$|\))" && [ "$(flr_get sg .role)" = review ]'
flr_req au2 A8-B; flr_run sga au2 --session-id "$SX" -p x
ck "routed author launch with that id: 73 and a denied row naming the pid" '[ "$FLR_RC" = 73 ] && flr_get sga .reasons | grep -qE "pid $LX( |\$|\))" && [ "$(flr_get sga .role)" = author ]'
flr_kill "$LX"
rm -f "$DEC.guard.lock"; mkdir "$DEC.guard.lock"   # earlier routed runs left the (inert) lock file
flr_run gl rv --session-id "$(uuid)" -p x
ck "unopenable guard lock file: 73, nothing started" '[ "$FLR_RC" = 73 ] && flr_spy_empty gl'
ck "unopenable guard lock file: denied row whose reason begins guard lock" '[ "$(flr_count gl denied)" = 1 ] && [ "$(flr_count gl launch)" = 0 ] && case "$(flr_get gl .reasons)" in "guard lock"*) :;; *) false;; esac'
flr_run gla au -p x
ck "routed author launch with the lock unopenable: 73, reason guard lock" '[ "$FLR_RC" = 73 ] && case "$(flr_get gla .reasons)" in "guard lock"*) :;; *) false;; esac'
: >"$T/spy.plain"; SPYLOG="$T/spy.plain" "$L" --model claude-fable-5-1 --effort high -p x 2>"$T/err.plain"; prc=$?
ck "an unrouted launch never takes the guard lock (runs with the lock unopenable)" '[ "$prc" = 0 ] && ! flr_spy_empty plain'
rmdir "$DEC.guard.lock"
ck "no token in stderr, spy args or any row" '! grep -q TOKEN- "$T"/err.* "$T"/spy.* "$DEC"'
flr_end
