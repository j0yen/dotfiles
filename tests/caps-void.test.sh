#!/usr/bin/env bash
# caps-void (P28 mechanism 4; amendment 1 falsifier part 2): `--class C --dry-run` lists every live row of the class
# against today's caps.tsv and against the registry as it was in git; a real run rewrites verdicts in the given file only.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
V="$here/.local/bin/caps-void.sh"; T="$here/.config/fleet/caps.tsv"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# the checked set is read from the registry at test time (Joe #195 voids rationing rows; a removed row must not fail this test)
ids_of() { awk -F'\t' -v c="$2" -v v="$3" '!/^#/ && $6==c && $8 ~ v {print $1}' "$1" | sort; }
listed() { sed -n 's/^ROW \([^ ]*\) .*/\1/p' <<<"$1" | sort; }
live_rat="$(ids_of "$T" rationing '^(KEEP|CHECK|CHANGE)$')"; live_rou="$(ids_of "$T" routing '^(KEEP|CHECK|CHANGE)$')"
nonlive="$(awk -F'\t' '!/^#/ && $8 ~ /^(VOID|DEAD|DROP)$/ {print $1}' "$T" | sort)"
# listing_matches REG CLASS EXPECTED: the dry run lists exactly the registry's live rows of the class, and no VOID/DEAD/DROP row
listing_matches() {
  local o; o="$("$V" --class "$2" --dry-run --registry "$1" 2>&1)"
  [ "$(listed "$o")" = "$3" ] && ! comm -12 <(listed "$o") <(awk -F'\t' '!/^#/ && $8 ~ /^(VOID|DEAD|DROP)$/ {print $1}' "$1" | sort) | grep -q .
}
out="$("$V" --class rationing --dry-run --registry "$T" 2>&1)"
listing_matches "$T" rationing "$live_rat" && ok "today rationing dry-run lists exactly the registry's live rationing rows ($(echo $live_rat))" || bad "rationing listing differs from registry live rows"
out2="$("$V" --class routing --dry-run --registry "$T" 2>&1)"
listing_matches "$T" routing "$live_rou" && ok "today routing dry-run lists exactly the registry's live routing rows ($(echo $live_rou))" || bad "routing listing differs from registry live rows"
comm -12 <(listed "$out") <(echo "$live_rou") | grep -q . && bad "a routing row is listed under rationing" || ok "routing rows are not in the rationing listing"
comm -12 <(listed "$out") <(echo "$nonlive") | grep -q . && bad "VOID rows listed as live" || ok "VOID/DEAD/DROP rows not listed"
# per-host enforced_at lines: path:L1/L2/.. maps positionally onto the host list, a single number applies to every host
exp="$(awk -F'\t' -v OFS=' ' '!/^#/ && $6=="rationing" && $8 ~ /^(KEEP|CHECK|CHANGE)$/ && $5 ~ /^~/ {
  i=index($5,":"); if(!i) next; path=substr($5,1,i-1); nl=split(substr($5,i+1),L,"/"); nh=split($4,H,",")
  if(nl==1) for(k=1;k<=nh;k++) print $1,H[k],path":"L[1]; else if(nl==nh) for(k=1;k<=nh;k++) print $1,H[k],path":"L[k] }' "$T")"
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; n=$((n+1)); grep -qxF "  $l" <<<"$out" || bad "per-host line missing: $l"; done <<<"$exp"
ok "per-host enforced_at lines printed for all $n derived host entries"
cp "$T" "$tmp/before.tsv"; "$V" --class rationing --dry-run --registry "$T" >/dev/null 2>&1
cmp -s "$T" "$tmp/before.tsv" && ok "dry run leaves caps.tsv byte-identical" || bad "dry run changed the registry"

# --- falsifier part 2: the registry as it was at the parent of 24e320d (#181)
if git -C "$here" cat-file -e "24e320d^:.config/fleet/caps.tsv" 2>/dev/null; then
  git -C "$here" show "24e320d^:.config/fleet/caps.tsv" > "$tmp/parent.tsv"
  p="$("$V" --class rationing --dry-run --registry "$tmp/parent.tsv" 2>&1)"
  echo "$p" | sed 's/^/  | /'
  ok "parent registry readable"
else
  git -C "$here" cat-file -e "24e320d:.config/fleet/caps.tsv" 2>/dev/null && ok "registry is ABSENT at 24e320d^ (created by 24e320d): the two drop-in rows, the one-slot row and the 144M row do not exist there as registry rows" || bad "24e320d not in history"
  git -C "$here" show "24e320d:.config/fleet/caps.tsv" > "$tmp/first.tsv"
  p="$("$V" --class rationing --dry-run --registry "$tmp/first.tsv" 2>&1)"
  echo "$p" | sed 's/^/  | first registry version 24e320d: /'
  awk -F'\t' '($1=="C007b"||$1=="C026a") && $8=="DEAD" {n++} END{exit n!=2}' "$tmp/first.tsv" && ok "24e320d registry already carries C007b + C026a as DEAD (retired in the same commit), so they are not live rows there" || bad "24e320d C007b/C026a rows"
  grep -q '^ROW C007b \|^ROW C026a ' <<<"$p" && bad "DEAD rows listed as live" || ok "24e320d dry run omits the DEAD drop-in rows"
  # reconstruct the pre-#181 state: the same two rows live (KEEP) as the registry would have shown them before the drop-ins were deleted
  awk -F'\t' -v OFS='\t' '($1=="C007b"||$1=="C026a"||$1=="C007a"){$8="KEEP"} {print}' "$tmp/first.tsv" > "$tmp/pre.tsv"
  q="$("$V" --class rationing --dry-run --registry "$tmp/pre.tsv" 2>&1)"
  grep -q '^ROW C007b ' <<<"$q" && grep -q '^ROW C026a ' <<<"$q" && ok "falsifier part 2 (reconstructed pre-#181 rows): both 60-quota-stretch drop-in rows listed live" || { bad "reconstructed pre-#181 listing"; echo "$q"; }
  grep -q '^  C007b ryzen7 ~/.config/systemd/user/seat-tick@.timer.d/60-quota-stretch.conf:6' <<<"$q" && ok "neutralise list names the drop-in path per host" || bad "drop-in path in neutralise list"
  grep -q 'R002\|R007' <<<"$p" && bad "one-slot/144M rows unexpectedly live in 24e320d" || ok "one-slot (R007) and 144M (R002) are VOID rows in 24e320d, not live: they appear only as VOID, never listed"
fi

# --- real run: only the given file changes, every other line stays byte-identical
cp "$T" "$tmp/work.tsv"
"$V" --class rationing --registry "$tmp/work.tsv" >/dev/null 2>&1; [ $? = 64 ] && ok "real run without --approvals is refused" || bad "real run accepted no approvals"
out="$("$V" --class rationing --approvals 195 --registry "$tmp/work.tsv" 2>&1)"
for id in $live_rat; do
  awk -F'\t' -v i="$id" '$1==i && $8=="VOID" && $10 ~ /VOID #195$/ {f=1} END{exit !f}' "$tmp/work.tsv" && ok "$id rewritten to VOID with #195 in the note" || bad "$id not voided"
done
pat="^($(echo $live_rat | tr ' ' '|'))\$"
diff <(awk -F'\t' -v p="$pat" '$1 !~ p' "$T") <(awk -F'\t' -v p="$pat" '$1 !~ p' "$tmp/work.tsv") >/dev/null && ok "all other lines byte-identical" || bad "other lines changed"
python3 -I "$here/.local/bin/caps-lint.py" "$tmp/work.tsv" | head -1 | grep -q ' 0 violation' && ok "voided registry still lints clean" || bad "voided registry lint"
out="$("$V" --class rationing --dry-run --registry "$tmp/work.tsv" 2>&1)"
grep -q 'class rationing: 0 live row' <<<"$out" && ok "second dry run: 0 live rows" || bad "second dry run"
"$V" --class nonsense --dry-run --registry "$T" >/dev/null 2>&1; [ $? = 64 ] && ok "unknown class refused" || bad "unknown class accepted"

# --- negative fixtures: the derived checks must detect a real defect, so they are not tautological
# (a) a rationing row that is still live in a registry otherwise equal to the expected one is a listing mismatch
printf 'ZZ999\tfixture\t5\tfleet\tnone\trationing\tfixture\tKEEP\taide\tfixture live row\n' | cat "$T" - > "$tmp/neg-live.tsv"
listing_matches "$tmp/neg-live.tsv" rationing "$live_rat" && bad "negative fixture: an extra live rationing row went undetected" || ok "negative fixture: extra live rationing row is detected"
# (b) a voided row put back to KEEP after the real run (a void row with a live consumer) fails the zero-live check
zero_live() { "$V" --class rationing --dry-run --registry "$1" 2>&1 | grep -q 'class rationing: 0 live row'; }
awk -F'\t' -v OFS='\t' '!/^#/ && $6=="rationing" && $8=="VOID" && !d {$8="KEEP"; d=1} {print}' "$tmp/work.tsv" > "$tmp/neg-void.tsv"
printf 'ZZ998\tfixture\t5\tfleet\tnone\trationing\tfixture\tVOID\taide\tfixture\n' >> "$tmp/neg-void.tsv"
sed -i 's/^ZZ998\(.*\)VOID\(.*\)$/ZZ998\1KEEP\2/' "$tmp/neg-void.tsv"
zero_live "$tmp/work.tsv" && ok "voided registry passes the zero-live check" || bad "voided registry has live rows"
zero_live "$tmp/neg-void.tsv" && bad "negative fixture: a void row with a live consumer went undetected" || ok "negative fixture: void row revived as live is detected"
exit $fail
