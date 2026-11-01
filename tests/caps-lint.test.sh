#!/usr/bin/env bash
# caps-lint (P28 five-whys 11-01; Joe 11-01 1:5x AM "stop using rationing limits", "find and consolidate all of them into a single file", approvals #194/#195):
# the caps registry .config/fleet/caps.tsv lints clean, and the lint refuses a live cap of a voided class and an expired cap.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
L="$here/.local/bin/caps-lint.py"; T="$here/.config/fleet/caps.tsv"
python3 -I -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$L" && ok "caps-lint.py parses" || bad "caps-lint.py parse"
if out="$(python3 -I "$L" "$T" 2>&1)"; then ok "caps.tsv lints clean ($(printf '%s\n' "$out" | head -1))"; else bad "caps.tsv has violations"; printf '%s\n' "$out" | grep '^VIOLATION' | head -5; fi
grep -q $'^# id\t.*\tpremise\texpires\tapplied_by$' "$T" && ok "caps.tsv header carries the v2 columns" || bad "caps.tsv header lacks premise/expires/applied_by"
G="$here/.local/bin/caps-digest.py"; M="$here/.config/fleet/caps-digest.md"
if out="$(python3 -I "$G" "$T" "$M" --check 2>&1)"; then ok "caps-digest.md matches caps.tsv"; else bad "caps-digest.md drifted: $out (regenerate: python3 -I $G $T $M)"; fi
tmp="$(mktemp)"
printf '# id\tname\tvalue\thost\tenforced_at\tclass\tsource\tverdict\towner\tnote\tpremise\texpires\tapplied_by\n' > "$tmp"
printf 'X1\tseat tick\t90 min\tcarbon\tx.conf:1\trationing\tJoe\tKEEP\taide\t-\tquota\t\t\n' >> "$tmp"
printf 'X2\tfoo\t1\tcarbon\tx:1\tmemory\tJoe\tKEEP\trb\t-\t\t2026-01-01\t\n' >> "$tmp"
printf 'X3\tbar\t0 (none)\tcarbon\tx:2\trationing\tJoe\tKEEP\trb\t-\t\t\t\n' >> "$tmp"
out="$(python3 -I "$L" "$tmp" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'X1 line 2: live cap of voided class rationing' <<<"$out" && grep -q 'X2 line 3: expired 2026-01-01' <<<"$out" && ! grep -q '^VIOLATION X3' <<<"$out"; then ok "lint refuses a live rationing cap and an expired cap, accepts the no-cap sentinel"; else bad "negative fixture (rc=$rc)"; printf '%s\n' "$out" | head -6; fi
rm -f "$tmp"
exit $fail
