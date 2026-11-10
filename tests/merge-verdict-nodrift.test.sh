#!/usr/bin/env bash
# No-drift: the merge-verdict grammar has ONE definition (.local/lib/merge-verdict-grammar.sh). rb-merge.sh, fleet-merge.sh, aide-verifier.sh and verifier-record.sh must source it
# and must not carry their own merge-verdict word or COMMIT pattern (the adv-grammar.sh pattern).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
lib="$here/.local/lib/merge-verdict-grammar.sh"
for f in rb-merge fleet-merge aide-verifier verifier-record; do
  s="$here/.local/bin/$f.sh"
  grep -q 'merge-verdict-grammar.sh' "$s" && ok "$f sources the lib" || bad "$f does not source the lib"
done
# a regex of their own: a re./grep call (or a pattern variable) that names the MERGE-OK word, or a COMMIT= pattern with a hex class / capture group
for f in rb-merge fleet-merge verifier-record; do
  s="$here/.local/bin/$f.sh"
  if grep -nE 're\.[a-z]+\(.*(MERGE-OK|COMMIT=)|grep[^|]*(MERGE-OK|COMMIT=\(|COMMIT=\[)|COMMIT=\(\[|COMMIT=\\\(|COMMIT=\[0-9a-f' "$s" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
    bad "$f carries its own MERGE-OK / COMMIT= pattern: $(grep -nE 're\.[a-z]+\(.*(MERGE-OK|COMMIT=)|COMMIT=\[0-9a-f' "$s" | head -2)"
  else ok "$f has no own merge-verdict pattern"; fi
done
# aide-verifier.sh keeps GATED-row and ADV COMMIT patterns (other grammars); it must not match the merge verdict word in a pattern
if grep -nE 're\.[a-z]+\(.*MERGE-OK|grep[^|]*-E[^|]*MERGE-OK' "$here/.local/bin/aide-verifier.sh" >/dev/null; then bad "aide-verifier.sh carries its own MERGE-OK pattern"; else ok "aide-verifier.sh has no own MERGE-OK pattern"; fi
# the word and both patterns are defined once, in the lib
n="$(grep -c "^MVG_RE=\|^MVG_WORD=" "$lib")"; [ "$n" = 2 ] && ok "lib defines the word and the pattern once" || bad "lib definition count $n"
if grep -rlE "\^MERGE-OK|\^\(MERGE-OK" "$here/.local" "$here/.claude" 2>/dev/null | grep -v "merge-verdict-grammar.sh"; then bad "an anchored MERGE-OK pattern outside the lib"; else ok "no anchored MERGE-OK pattern outside the lib"; fi
# the python parser has no pattern literal of its own
grep -q 'MERGE-OK' "$here/.local/lib/merge_verdict_grammar.py" && bad "merge_verdict_grammar.py names MERGE-OK" || ok "merge_verdict_grammar.py reads its patterns from the environment"
[ "$fail" = 0 ] && echo "ALL PASS merge-verdict-nodrift" || { echo "FAILED merge-verdict-nodrift"; exit 1; }
