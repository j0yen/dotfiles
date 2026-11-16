#!/usr/bin/env bash
# fable-launch-review AC 1: every launch row carries role, scope and scope_id (R1, R2, R4); the eleven existing fields are unchanged.
# Run alone: bash tests/fable-launch-review_ac01_fields.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
K11='["ts","decision","task_id","skill","route","model","effort","account","session","resume","reasons"]'
WANT="$(cd "$FX" && sha256sum PRD-rs-alpha.md PRD-rs-beta.md notes.md | LC_ALL=C sort -u | sha256sum | cut -c1-64)"   # R4 over the stubs, not the manifest

S1="$(uuid)"; flr_req rev A1 "$FX/happy.sha256"; flr_run rev rev --session-id "$S1" -p x
ck "review request with a pre-drawn id launches (rc 0, spy started with that id)" '[ "$FLR_RC" = 0 ] && grep -q -- "--session-id $S1" "$T/spy.rev"'
ck "review launch row: role review" '[ "$(flr_get rev "select(.decision==\"launch\") | .role")" = review ]'
ck "review launch row: scope is the manifest real path" '[ "$(flr_get rev "select(.decision==\"launch\") | .scope")" = "$(readlink -f "$FX/happy.sha256")" ]'
ck "review launch row: scope_id is the sha256 of the canonical scope text (R4)" '[ "$(flr_get rev "select(.decision==\"launch\") | .scope_id")" = "$WANT" ]'
ck "review launch row: eleven existing fields keep names and order, new three appended" '[ "$(flr_get rev "keys_unsorted | .[0:11] == $K11 and .[11:] == [\"role\",\"scope\",\"scope_id\"]")" = true ]'
ck "review launch row: existing values (launch, A1, dream, fable-xhigh, fable xhigh, jyen.pm, session, resume false)" '[ "$(flr_get rev "[.decision,.task_id,.skill,.route,.model,.effort,.account,.session,(.resume|tostring)] | join(\",\")")" = "launch,A1,dream,fable-xhigh,claude-fable-5-1,xhigh,jyen.pm,$S1,false" ]'
flr_req au A1b; flr_run au au -p x
ck "author request launches (rc 0)" '[ "$FLR_RC" = 0 ] && [ -s "$T/spy.au" ]'
ck "author launch row: role author, scope and scope_id empty" '[ "$(flr_get au "[.role,.scope,.scope_id] | join(\"|\")")" = "author||" ]'
ck "author and review rows agree on the eleven fields but ts, task, session (reasons from the resolver)" '[ "$(flr_get au "del(.ts,.task_id,.session,.role,.scope,.scope_id)")" = "$(flr_get rev "del(.ts,.task_id,.session,.role,.scope,.scope_id)")" ]'
flr_req obj A1c - 'del(.review) | .review={reason:"independent_verifier_required",evidence:.evidence_refs}'; flr_run obj obj -p x
ck "review object without snapshot launches as author (rc 0, role author)" '[ "$FLR_RC" = 0 ] && [ "$(flr_get obj ".role")" = author ]'
ck "review object without snapshot: the R2 stderr line" 'grep -qxF "fable-launch: review object without snapshot: launching as author (unbindable as a Review: line once the lint PRD is installed)" "$T/err.obj"'
ck "review object without snapshot: reasons end with ; review-without-snapshot" '[ "$(flr_get obj ".reasons")" = "$(flr_get au ".reasons"); review-without-snapshot" ]'
ck "plain author request: no review-without-snapshot marker, no stderr line" '! grep -q review-without-snapshot "$T/new.au" "$T/err.au"'
R_ROLE=review R_SCOPE=/x R_SCOPE_ID=abc flr_req env A1d '-' '.role="review" | .scope_id="abc"'; R_ROLE=review R_SCOPE=/x R_SCOPE_ID=abc flr_run env env -p x
ck "no env var or request field sets the role (R_ROLE in env, role in request): author" '[ "$FLR_RC" = 0 ] && [ "$(flr_get env "[.role,.scope,.scope_id] | join(\"|\")")" = "author||" ]'
S2="$(uuid)"; flr_req rel A1e review-scope/single.sha256; (cd "$FX/.." && flr_run rel rel --session-id "$S2" -p x)
ck "relative review.snapshot resolved with readlink -f against the launcher cwd" '[ "$(cat "$T/rc.rel")" = 0 ] && [ "$(flr_get rel ".scope")" = "$(readlink -f "$FX/single.sha256")" ]'
flr_end
