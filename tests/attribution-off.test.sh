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
[ $fail = 0 ] && echo "PASS attribution-off" || echo "FAIL attribution-off"
exit $fail
