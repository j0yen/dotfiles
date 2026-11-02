#!/usr/bin/env bash
# ask-check-lint.sh (A254, mechanism 3 of 2026-10-31 fleet-dash stale-carbon-tree five-whys): refuse a SOURCE-SHAPED done-check on an ask about a
# consumer-visible thing. A21 closed MET on `ls-remote main = sha` for a page-shaped ask while carbon rendered an old tree.
#   ask-check-lint.sh --subject "<ask subject>" --check "<done-check>"
#   ask-check-lint.sh --text "<ask text carrying 'done-check: <check>'>"   (check = text after `done-check[:=]` up to ` | ` or end; none found = pass)
# Exit 0 pass, 2 refusal ('source-shaped check' on stderr). Every pass and refusal is appended to $ASK_CHECK_LINT_DIR/fires.log
# (default ~/.local/state/ask-check-lint). Called by seat-ask.sh, approve.sh and the aide sweep row writer.
# Rule: subject matches page|tile|card|dashboard|status.json|binary|prod AND the check reads only source (ls-remote, rev-parse, merge, merge-base, git log, a bare sha)
# with no consumer read (a status.json key, a URL/curl, --version, systemctl/journalctl on the running host) => refuse.
set -u
subject=""; check=""; text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subject) subject="${2:-}"; shift 2 ;;
    --check) check="${2:-}"; shift 2 ;;
    --text) text="${2:-}"; shift 2 ;;
    *) echo "usage: ask-check-lint.sh (--subject S --check C | --text T)" >&2; exit 64 ;;
  esac
done
if [ -n "$text" ]; then
  subject="$text"
  check="$(printf '%s' "$text" | sed -n 's/.*[Dd]one-check[:=][[:space:]]*//p' | sed 's/ | .*//' | head -n1)"
fi
log() {
  local d="${ASK_CHECK_LINT_DIR:-$HOME/.local/state/ask-check-lint}"
  ( umask 077; mkdir -p "$d" && printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "${subject:0:80}" "${check:0:120}" >>"$d/fires.log" ) 2>/dev/null
}
if [ -z "${check//[[:space:]]/}" ]; then log pass-nocheck; exit 0; fi
if ! printf '%s' "$subject" | grep -qiE 'page|tile|card|dashboard|status\.json|binary|prod'; then log pass-subject; exit 0; fi
if printf '%s' "$check" | grep -qE 'status\.json|--version|curl|wget|https?://|systemctl|journalctl'; then log pass-consumer; exit 0; fi
if printf '%s' "$check" | grep -qE 'ls-remote|rev-parse|merge|git log|(^|[^0-9a-fA-F])[0-9a-f]{7,40}($|[^0-9a-fA-F])'; then
  log refuse
  echo "ask-check-lint: source-shaped check: '$check' reads only source; the ask is about a consumer-visible thing, so the check must name a status.json key, a page string (curl) or --version on the running host" >&2
  exit 2
fi
log pass-other; exit 0
