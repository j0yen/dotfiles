#!/usr/bin/env bash
# fable-launch-review AC 6: a review session that ended other than clean is not resumed without the unknown-effect ack (77) and is never replayed;
# a fresh review of the same manifest under a new pre-drawn id starts with its own row only when review.replay declares exactly the blocking
# prior reviews, and then one replay row precedes its launch row (amended by A1300 FFDR spec r2, F2). Run alone: bash tests/fable-launch-review_ac06_unknown_effect.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
SU="$(uuid)"; flr_req rv A6 "$FX/happy.sha256"
FLR_SPY_RC=1 flr_run u rv --session-id "$SU" -p x
ck "review session whose run ends non-zero (spy exits 1)" '[ "$FLR_RC" != 0 ] && grep -q -- "--session-id $SU" "$T/spy.u"'
ck "its launch row says role review with the manifest's scope_id" '[ "$(flr_get u "select(.decision==\"launch\") | [.role,(.scope_id|length)]|map(tostring)|join(\",\")")" = "review,64" ]'
ck "lane state records the session as unknown_effect" '[ "$(jq -r --arg s "$SU" ".sessions[\$s].unknown_effect // .[\$s].unknown_effect" "$ACCOUNT_LANE_STATE/sessions.json")" = true ]'
flr_run res rv --resume "$SU" -p again
ck "resume without the unknown-effect ack: exit 77, nothing started" '[ "$FLR_RC" = 77 ] && flr_spy_empty res'
ck "resume without the ack: no new launch row" '[ "$(flr_count res launch)" = 0 ]'
SN="$(uuid)"; flr_run fresh rv --session-id "$SN" -p x
ck "fresh review of the same manifest under a new id, no review.replay: 64, nothing started, one denied row naming the failed prior and the declaration to make" '[ "$FLR_RC" = 64 ] && flr_spy_empty fresh && [ "$(flr_count fresh launch)" = 0 ] && [ "$(flr_count fresh denied)" = 1 ] && flr_get fresh .reasons | grep -qF "unchanged-review-replay" && flr_get fresh .reasons | grep -qF "$SU (failed)" && flr_get fresh .reasons | grep -qF "prior:[\"$SU\"]"'
flr_req rvd A6 "$FX/happy.sha256" '.review.replay={reason:"prior reviewer exited non-zero before recording a verdict",evidence:["ledger:A1300"],prior:["'"$SU"'"]}'
SN2="$(uuid)"; flr_run fresh2 rvd --session-id "$SN2" -p x
ck "the fresh review declaring exactly that prior in review.replay starts" '[ "$FLR_RC" = 0 ] && grep -q -- "--session-id $SN2" "$T/spy.fresh2"'
ck "the fresh review has its own launch row (role review, same scope_id), immediately after one replay row" '[ "$(jq -r .decision "$T/new.fresh2" | tr "\n" " ")" = "replay launch " ] && [ "$(flr_get fresh2 "select(.decision==\"launch\") | [.session,.role,.scope_id]|join(\",\")")" = "$SN2,review,$(flr_get u "select(.decision==\"launch\") | .scope_id")" ]'
ck "the replay row's reasons are the declaration with the prior's outcome" '[ "$(flr_get fresh2 "select(.decision==\"replay\") | .reasons | fromjson | [(.prior|join(\",\")), .prior_outcomes[\"$SU\"], .reason] | join(\"|\")")" = "$SU|failed|prior reviewer exited non-zero before recording a verdict" ]'
ck "the ended session is not replayed (spy never saw its id again)" '! grep -qF "$SU" "$T/spy.fresh" "$T/spy.res" "$T/spy.fresh2"'
flr_end
