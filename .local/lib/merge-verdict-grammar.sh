#!/usr/bin/env bash
# merge-verdict-grammar.sh - the ONE definition of the merge-verdict row grammar (source it; defines variables and mvg_* functions).
# Producers (verifier-record.sh, the aide-verifier.sh launch lint), the pre-gate A parse in rb-merge.sh and the candidate selection in fleet-merge.sh all read THIS
# file (through merge_verdict_grammar.py for the parse): the MERGE-OK word and both patterns below exist nowhere else in the repo (tests/merge-verdict-nodrift.test.sh).
#
# A merge verdict is a ledger row  --kind verdict --via verifier  whose `what` STARTS (byte 0 of line 1, no leading space) with the machine prefix:
#   MERGE-OK <owner>/<name>#<pr> COMMIT=<40 lowercase hex> agent=verifier:<agent>-verifier-<name>   then free text
# <owner>/<name> is the PR's BASE repo nameWithOwner (never the fork). COMMIT is the head the suite ran on (the HEAD trailer of the wm-verify-run log), never a fresh read at record time.
# The whole `what` holds exactly one COMMIT= token and exactly one agent=verifier: token. A second sha in the free text is never read. No alias word (a CONFIRM-prefixed row is not a merge verdict).
MVG_WORD='MERGE-OK'
MVG_REF_RE='([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]*)'
MVG_COMMIT_RE='COMMIT=([0-9a-f]{40})( |$)'
MVG_RE="^${MVG_WORD} ${MVG_REF_RE} ${MVG_COMMIT_RE}"
MVG_COMMIT_COUNT_RE='(^| )COMMIT='                  # applied per line over the whole `what`, like grep -oE | wc -l; must count exactly 1
MVG_AGENT_COUNT_RE='(^| )agent=verifier:'             # per line over the whole `what`; must count exactly 1
MVG_AGENT_RE='(^| )agent=verifier:((aide|rb|r7)-verifier-([a-z0-9][a-z0-9-]{0,30}))( |$)'   # group 2 is the agent token
MVG_AGENT_RE_BASH='(aide|rb|r7)-verifier-[a-z0-9][a-z0-9-]{0,30}'              # what mvg_format accepts as <agent>-verifier-<name>
MVG_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export MVG_WORD MVG_REF_RE MVG_COMMIT_RE MVG_RE MVG_COMMIT_COUNT_RE MVG_AGENT_COUNT_RE MVG_AGENT_RE MVG_LIB_DIR   # the python parser reads these: no second copy

# mvg_format <owner/name> <pr> <40hex> <agent-token> -> the machine prefix on stdout; rc 1 (nothing printed) on a short sha, a missing owner, a non-numeric pr or a bad token
mvg_format() {
  local repo="${1:-}" pr="${2:-}" sha="${3:-}" tok="${4:-}"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "mvg_format: repo must be owner/name, got '$repo'" >&2; return 1; }
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || { echo "mvg_format: pr must be a number, got '$pr'" >&2; return 1; }
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "mvg_format: commit must be 40 lowercase hex, got '$sha'" >&2; return 1; }
  [[ "$tok" =~ ^${MVG_AGENT_RE_BASH}$ ]] || { echo "mvg_format: agent token must be <agent>-verifier-<name>, got '$tok'" >&2; return 1; }
  printf '%s %s#%s COMMIT=%s agent=verifier:%s' "$MVG_WORD" "$repo" "$pr" "$sha" "$tok"
}

# mvg_parse <what> -> one line "<owner> <name> <pr> <commit> <agent-token>" on stdout, rc 0; otherwise rc 1 and one line "REFUSE <prefix|commit|agent> <why>" on stderr
mvg_parse() { printf '%s' "${1-}" | python3 -I "$MVG_LIB_DIR/merge_verdict_grammar.py" parse; }
