#!/usr/bin/env bash
# analysis-route AC 6 (A1300 E13): the unchanged launcher, under FABLE_LAUNCH_TEST=1 with a spy CLI, launches a wwhtbt request whose
# requested names route opus-xhigh, claude-opus-5-5 and xhigh on claude-opus-5-5 xhigh in the non-Fable lane and writes one launch row
# with route opus-xhigh and the alternate reason; without requested the spy sees claude-fable-5-1. From R (AR_ROOT): launcher, resolver
# and policy. Run alone: bash tests/analysis-route_ac06_launcher.test.sh
. "$(dirname "$0")/analysis-route_lib.sh"
ar_launcher_env "$R"
WUC='{"task_id":"AR6-%s","skill":"wwhtbt","decision_class":"unresolved_consequential","evidence_refs":'"$EVJ"'%s}'
OPX=',"requested":{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}'
row(){ jq -R -r "fromjson? | objects | select(.decision==\"$2\") | $3" "$T/new.$1" | tail -1; }
nrows(){ jq -R -r "fromjson? | objects | select(.decision==\"$2\") | .decision" "$T/new.$1" | wc -l | tr -d ' '; }
acct(){ sed -n 's/^spy acct=\([^ ]*\) .*/\1/p' "$T/spy.$1" | head -1; }
NF="$(jq -r '.lanes.nonfable.primaries | join(" ")' "$ACCOUNT_LANE_POLICY")"

S1="$(uuid)"; ar_launch alt "$(printf "$WUC" alt "$OPX")" --session-id "$S1" -p x
ck "alternate request: launcher rc 0, the spy ran once" '[ "$(cat "$T/rc.alt")" = 0 ] && [ "$(grep -c . "$T/spy.alt")" = 1 ]' || head -3 "$T/err.alt"
ck "alternate request: the spy sees claude-opus-5-5 xhigh, one --model, the pre-drawn session id" 'grep -q -- "--model claude-opus-5-5" "$T/spy.alt" && grep -q -- "--effort xhigh" "$T/spy.alt" && [ "$(grep -o -- "--model" "$T/spy.alt" | wc -l)" = 1 ] && grep -q -- "--session-id $S1" "$T/spy.alt" && ! grep -q fable "$T/spy.alt"'
ck "alternate request: the account is the non-Fable lane's first round-robin primary ($(ar_nf 0)), not the Fable lane's" '[ "$(acct alt)" = "$(ar_nf 0)" ] && [ "$(acct alt)" != "$(ar_fl)" ]'
ck "alternate request: exactly one launch row (no denied row), with the fourteen fields in order" '[ "$(nrows alt launch)" = 1 ] && [ "$(nrows alt denied)" = 0 ] && jq -R -e --argjson k "$AR_FIELDS" "fromjson | keys_unsorted==\$k" "$T/new.alt" >/dev/null 2>&1'
ck "alternate row: route opus-xhigh, model claude-opus-5-5, effort xhigh, role author, session = the pre-drawn id, account = the spy's" '[ "$(row alt launch "[.route,.model,.effort,.role,.session,.account]|join(\" \")")" = "opus-xhigh claude-opus-5-5 xhigh author $S1 $(acct alt)" ]'
ck "alternate row: reasons is one string carrying the alternate reason (requested alternate opus-xhigh for fable-xhigh)" '[ "$(row alt launch ".reasons|type")" = string ] && row alt launch .reasons | grep -qF "requested alternate opus-xhigh for fable-xhigh"'

S2="$(uuid)"; ar_launch def "$(printf "$WUC" def "")" --session-id "$S2" -p x
ck "same request without requested: the spy sees claude-fable-5-1 (xhigh) on the Fable lane ($(ar_fl))" '[ "$(cat "$T/rc.def")" = 0 ] && grep -q -- "--model claude-fable-5-1" "$T/spy.def" && grep -q -- "--effort xhigh" "$T/spy.def" && [ "$(acct def)" = "$(ar_fl)" ]'
ck "without requested: one launch row, route fable-xhigh, no alternate reason" '[ "$(nrows def launch)" = 1 ] && [ "$(row def launch .route)" = fable-xhigh ] && ! row def launch .reasons | grep -q "requested alternate"'

S3="$(uuid)"; ar_launch ro "$(printf "$WUC" ro ',"requested":{"route":"opus-xhigh"}')" --session-id "$S3" -p x
ck "route-only request: 64, nothing started, one denied row naming requested.model" '[ "$(cat "$T/rc.ro")" = 64 ] && [ ! -s "$T/spy.ro" ] && [ "$(nrows ro denied)" = 1 ] && [ "$(nrows ro launch)" = 0 ] && row ro denied .reasons | grep -q "requested\.model"'
S4="$(uuid)"; ar_launch cli "$(printf "$WUC" cli ',"requested":{"route":"opus-xhigh"}')" --session-id "$S4" --model claude-opus-5-5 --effort xhigh -p x
ck "route in the request + --model/--effort on the command line: the launcher's merge keeps requested.route, so the alternate launches on a non-Fable primary" '[ "$(cat "$T/rc.cli")" = 0 ] && grep -q -- "--model claude-opus-5-5" "$T/spy.cli" && grep -q -- "--effort xhigh" "$T/spy.cli" && [ "$(row cli launch .route)" = opus-xhigh ] && case " $NF " in *" $(acct cli) "*) true;; *) false;; esac'
S5="$(uuid)"; ar_launch cf "$(printf "$WUC" cf "$OPX")" --session-id "$S5" --model claude-fable-5-1 -p x
ck "alternate request with a conflicting --model claude-fable-5-1: 64, nothing started, denied naming requested.model" '[ "$(cat "$T/rc.cf")" = 64 ] && [ ! -s "$T/spy.cf" ] && row cf denied .reasons | grep -q "requested\.model claude-fable-5-1"'
S6="$(uuid)"; ar_launch fw '{"task_id":"AR6-fw","skill":"5whysandrhyme","decision_class":"consequential_prevention","evidence_refs":'"$EVJ"',"requested":{"route":"opus-xhigh","model":"claude-opus-5-5","effort":"xhigh"}}' --session-id "$S6" -p x
ck "5whysandrhyme consequential_prevention alternate: the spy sees claude-opus-5-5 xhigh on a non-Fable primary; row route opus-xhigh with the reason" '[ "$(cat "$T/rc.fw")" = 0 ] && grep -q -- "--model claude-opus-5-5" "$T/spy.fw" && grep -q -- "--effort xhigh" "$T/spy.fw" && case " $NF " in *" $(acct fw) "*) true;; *) false;; esac && row fw launch .reasons | grep -qF "requested alternate opus-xhigh for fable-xhigh"'
ck "no token in stderr, spy args or any row" '! grep -q TOKEN- "$T"/err.* "$T"/spy.* "$SKILL_ROUTING_DECISIONS"'
ar_end
