#!/usr/bin/env bash
# adv-grammar.sh - the ONE definition of the adversarial-pass (ADV) row grammar that rb-merge.sh enforces (source it; defines variables only).
# rb-merge.sh, rb-merge-adv-check.py (receives these through its environment) and tests/rb-merge-adv.test.sh all read THIS file: there is no prose or regex copy
# anywhere else (tests/rb-merge-adv.test.sh greps rb-merge.sh for a literal). Patterns stay in the subset where POSIX ERE (grep -E) and Python re agree
# (no [[:class:]], no \d, no lookaround); the test compiles every pattern with both. @REPO@ = owner/name and @PR@ = the PR number are substituted by the consumer.
#
# An ADV row is a ledger row  --kind verdict  --gates <G>  whose `what` starts:
#   ADV-PASS|ADV-FAIL|ADV-UNVERIFIED <owner/name>#<pr> COMMIT=<40 hex> agent=verifier:<name> scope=adversarial log=/<abs path>(:| )...
# <G> is the row the merge verdict V gates. log= names the verifier's output file; the merging host must hold it as a non-empty regular file.
# The author of an ADV row is NOT checked (free text any seat can type): Fable re-grades every ADV row because each one gates a merge.
ADV_PASS_WORD='ADV-PASS'
ADV_FAIL_WORD='ADV-FAIL'
ADV_UNVERIFIED_WORD='ADV-UNVERIFIED'
ADV_ROW_KIND='verdict'
ADV_RE_FMT="^(${ADV_PASS_WORD}|${ADV_FAIL_WORD}|${ADV_UNVERIFIED_WORD}) @REPO@#@PR@ COMMIT=[0-9a-f]{40} agent=verifier:[^ ]+ scope=adversarial log=/[^ :]+(:| )"
ADV_LOG_RE='scope=adversarial log=(/[^ :]+)'
ADV_COMMIT_RE='COMMIT=([0-9a-f]{12,40})'        # case-insensitive; V's COMMIT may be a >= 12-hex prefix (the merge gate's own minimum)
# Trigger (i): every PR in these repos needs an ADV pass (fail-closed, brief or not). Trigger (ii): the gated row G's what/why/evidence matches ADV_BRIEF_RE (case-insensitive), any repo.
ADV_TRIGGER_REPOS='j0yen/mcphost j0yen/synthorg'
ADV_BRIEF_RE='briefs?[/=:]'
# Waiver: RB_MERGE_ADV_WAIVE=<d-id> of a row of kind ADV_WAIVE_KIND recorded BY ADV_WAIVE_AGENT (the ledger `agent` column the recorder sets from --agent; ctl rows carry
# agent=controller, never ctl; an agent= token typed inside `what` never counts) whose what holds ADV-WAIVE <owner/name>#<pr> for THIS PR and a future until=<ISO-8601 with a time part>.
ADV_WAIVE_KIND='other'
ADV_WAIVE_AGENT='controller'
ADV_WAIVE_RE_FMT='ADV-WAIVE @REPO@#@PR@([^0-9]|$)'
ADV_UNTIL_RE='until=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})?)'
ADV_EXIT=4                                       # every ADV refusal; exit 3 stays attribution-only
# adv_ere FMT OWNER/NAME PR -> the ERE with the placeholders filled (repo dots escaped), for bash/grep consumers and the drift test
adv_ere() { local f=$1 r=${2//./\\.}; f=${f//@REPO@/$r}; printf '%s' "${f//@PR@/$3}"; }
