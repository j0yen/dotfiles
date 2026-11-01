#!/usr/bin/env bash
# caps-void (P28 mechanism 4; amendment 1 falsifier part 2): `--class C --dry-run` lists every live row of the class
# against today's caps.tsv and against the registry as it was in git; a real run rewrites verdicts in the given file only.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
V="$here/.local/bin/caps-void.sh"; T="$here/.config/fleet/caps.tsv"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# today's registry: live rationing rows, live routing rows
out="$("$V" --class rationing --dry-run --registry "$T" 2>&1)"
for id in C093 C125 C157 R021; do grep -q "^ROW $id " <<<"$out" && ok "today rationing dry-run lists $id" || bad "today rationing lacks $id"; done
grep -q '^ROW R023 ' <<<"$out" && bad "R023 is class routing and must not be listed under rationing" || ok "R023 not in rationing (it is class routing)"
grep -q '^ROW R00[1-9] ' <<<"$out" && bad "VOID rows listed as live" || ok "VOID/DEAD/DROP rows not listed"
out2="$("$V" --class routing --dry-run --registry "$T" 2>&1)"
grep -q '^ROW R023 ' <<<"$out2" && ok "today routing dry-run lists R023" || bad "today routing lacks R023"
grep -q 'C093 redbaron ~/.config/wm-build/config.toml:88' <<<"$out" && grep -q 'C093 orch ~/.config/wm-build/config.toml:57' <<<"$out" && ok "per-host enforced_at lines printed (C093 rb:88 orch:57)" || bad "per-host lines"
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
for id in C093 C125 C157 R021; do
  awk -F'\t' -v i="$id" '$1==i && $8=="VOID" && $10 ~ /VOID #195$/ {f=1} END{exit !f}' "$tmp/work.tsv" && ok "$id rewritten to VOID with #195 in the note" || bad "$id not voided"
done
diff <(grep -vP '^(C093|C125|C157|R021)\t' "$T") <(grep -vP '^(C093|C125|C157|R021)\t' "$tmp/work.tsv") >/dev/null && ok "all other lines byte-identical" || bad "other lines changed"
python3 -I "$here/.local/bin/caps-lint.py" "$tmp/work.tsv" | head -1 | grep -q ' 0 violation' && ok "voided registry still lints clean" || bad "voided registry lint"
out="$("$V" --class rationing --dry-run --registry "$tmp/work.tsv" 2>&1)"
grep -q 'class rationing: 0 live row' <<<"$out" && ok "second dry run: 0 live rows" || bad "second dry run"
"$V" --class nonsense --dry-run --registry "$T" >/dev/null 2>&1; [ $? = 64 ] && ok "unknown class refused" || bad "unknown class accepted"
exit $fail
