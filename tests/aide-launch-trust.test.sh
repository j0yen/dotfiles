#!/usr/bin/env bash
# Test: aide-launch.sh flips projects[$HOME].hasTrustDialogAccepted to true, keeps other keys, then execs the claude bin.
set -u
d=$(mktemp -d); cj="$d/claude.json"
# own HOME fixture: aide-launch.sh sources the fleet token conf under $HOME/.config/environment.d, absent on RB / a fresh HOME
export HOME="$d/home"; mkdir -p "$HOME/.config/environment.d"
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-not-a-token\n' > "$HOME/.config/environment.d/90-claude-oauth.conf"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false,"keep":1},"/other":{"x":2}},"top":3}\n' "$HOME" > "$cj"
printf '#!/bin/sh\necho STUB-RAN "$@"\n' > "$d/stub"; chmod +x "$d/stub"
out=$(AIDE_CLAUDE_JSON="$cj" AIDE_CLAUDE_BIN="$d/stub" "${AIDE_LAUNCH:-$(dirname "$0")/../.local/bin/aide-launch.sh}" --model x 2>&1)
fail=0
[ "$(jq -r --arg h "$HOME" '.projects[$h].hasTrustDialogAccepted' "$cj")" = true ] || { echo "FAIL trust not set"; fail=1; }
[ "$(jq -r --arg h "$HOME" '.projects[$h].keep' "$cj")" = 1 ] || { echo "FAIL lost project key"; fail=1; }
[ "$(jq -r '.projects["/other"].x + .top' "$cj")" = 5 ] || { echo "FAIL lost other keys"; fail=1; }
grep -q 'STUB-RAN' <<<"$out" || { echo "FAIL stub not exec'd"; fail=1; }
grep -q 'trust pre-accepted' <<<"$out" || { echo "FAIL no log line"; fail=1; }
# second run: already true -> no rewrite line
out2=$(AIDE_CLAUDE_JSON="$cj" AIDE_CLAUDE_BIN="$d/stub" "${AIDE_LAUNCH:-$(dirname "$0")/../.local/bin/aide-launch.sh}" --model x 2>&1)
grep -q 'trust pre-accepted' <<<"$out2" && { echo "FAIL rewrote when already true"; fail=1; }
ls "$d" | grep -q '\.aide\.' && { echo "FAIL temp file left"; fail=1; }
rm -rf "$d"
[ $fail = 0 ] && echo "PASS trust-preaccept (5 checks + idempotent)"
exit $fail
