#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC7: with a status.json older than 60 s the
# generator calls operator-status-gen.sh first, and the Generated line's
# status age is < 60 s; a fresh status.json is not regenerated.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
hgen_setup
st="$work/cache/status.json"
# age the fixture status.json: generated_at 10 minutes ago
jq --arg t "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '.generated_at=$t' "$st" >"$st.n" && mv "$st.n" "$st"
touch -d '10 minutes ago' "$st"
# spy status generator: logs the call and rewrites status.json with a fresh stamp
cat >"$work/spy-gen.sh" <<SPY
#!/usr/bin/env bash
echo "called active=\${HANDOFF_GEN_ACTIVE:-} at \$(date +%s)" >>"$work/spy.log"
jq --arg t "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.generated_at=\$t' "$st" >"$st.n" && mv "$st.n" "$st"
SPY
chmod +x "$work/spy-gen.sh"
export HANDOFF_STATUS_GEN="$work/spy-gen.sh"
"$HGEN" --out "$work/t.md"; assert_eq "$?" "0" "exits 0"
assert_eq "$(wc -l <"$work/spy.log")" "1" "operator-status-gen.sh called once"
assert_contains "$(cat "$work/spy.log")" "called active=1" "called with the recursion guard set"
age="$(sed -n 's/^Generated: .*status age \([0-9]*\)s$/\1/p' "$work/t.md")"
assert_eq "$([ -n "$age" ] && [ "$age" -lt 60 ] && echo yes)" "yes" "Generated line status age < 60 s (got '${age}')"
# fresh status.json: not regenerated
"$HGEN" --out "$work/u.md"
assert_eq "$(wc -l <"$work/spy.log")" "1" "fresh status.json is not regenerated"
# the real generator, called through the stale path, also yields a fresh age
unset HANDOFF_STATUS_GEN
touch -d '10 minutes ago' "$st"; jq '.generated_at="2026-01-01T00:00:00Z"' "$st" >"$st.n" && mv "$st.n" "$st"
"$HGEN" --out "$work/r.md"
age="$(sed -n 's/^Generated: .*status age \([0-9]*\)s$/\1/p' "$work/r.md")"
assert_eq "$([ -n "$age" ] && [ "$age" -lt 60 ] && echo yes)" "yes" "real operator-status-gen.sh path: age < 60 s (got '${age}')"
exit $fail
