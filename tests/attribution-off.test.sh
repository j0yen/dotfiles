#!/usr/bin/env bash
# No Claude attribution in commits or PR bodies (Joe 10-22 "leave the history, just stop adding the trailer").
# Guards the settings keys fleet-sync carries to every host; a drift here re-adds "claude" to GitHub contributors.
set -u
S="$(dirname "$0")/../.claude/settings.json"
fail=0
python3 -I - "$S" <<'PY' || fail=1
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get('includeCoAuthoredBy') is False, 'includeCoAuthoredBy must be false'
a=d.get('attribution'); assert isinstance(a,dict), 'attribution must be an object'
assert a.get('commit')=='' and a.get('pr')=='', 'attribution.commit and .pr must be empty strings'
PY

# --- landed-commit mechanism (rb-merge.sh passes the PR title/body explicitly with attribution lines stripped) ---
here="$(cd "$(dirname "$0")/.." && pwd)"
RBM="$here/.local/bin/rb-merge.sh"
# (a) the gh pr merge invocation carries --subject and --body on the SAME line, and the strip regex is present
if grep -E 'pr merge' "$RBM" | grep -v '^[[:space:]]*#' | grep -q -- '--subject .*--body'; then echo "ok - rb-merge.sh passes --subject and --body on the gh pr merge call"
else echo "NOT OK - rb-merge.sh gh pr merge lacks --subject/--body on one invocation"; fail=1; fi
if grep -qE "^ATTR_RE='co-authored-by\|generated with'" "$RBM" && grep -q 'grep -viE "\$ATTR_RE"' "$RBM"; then echo "ok - rb-merge.sh strips co-authored-by/generated-with lines from the body"
else echo "NOT OK - rb-merge.sh strip regex missing"; fail=1; fi
# (b) the latest commit on j0yen/dotfiles main: a trailer is a FAILURE only when the commit is newer than tests/attribution-off.since (the mechanism's timestamp)
since_f="$here/tests/attribution-off.since"
if ! command -v gh >/dev/null 2>&1 || ! timeout 20 gh auth status >/dev/null 2>&1; then echo "skip - gh missing or unauthenticated; landed-commit check not run"
else
  c="$(timeout 30 gh api 'repos/j0yen/dotfiles/commits?per_page=1' -q '.[0] | [.sha, .commit.committer.date, (.commit.message | gsub("\n"; "\u0001"))] | join("\t")' 2>/dev/null)" || c=""
  if [ -z "$c" ]; then echo "skip - network/gh api unavailable; landed-commit check not run"
  else
    sha="${c%%$'\t'*}"; rest="${c#*$'\t'}"; cdate="${rest%%$'\t'*}"; msg="${rest#*$'\t'}"; msg="${msg//$'\001'/$'\n'}"
    hits="$(printf '%s\n' "$msg" | grep -ciE 'co-authored-by|generated with' || true)"
    since="$(cat "$since_f" 2>/dev/null || true)"
    if [ "$hits" = 0 ]; then echo "ok - latest main commit ${sha:0:7} carries no attribution trailer"
    elif [ -n "$since" ] && [[ "$cdate" > "$since" ]]; then echo "NOT OK - ATTRIBUTION-LANDED $sha ($cdate is after the mechanism marker $since)"; fail=1
    else echo "info: legacy trailer in $sha (pre-mechanism; committed $cdate, marker ${since:-none})"; fi
  fi
fi

[ $fail = 0 ] && echo "PASS attribution-off" || echo "FAIL attribution-off"
exit $fail
