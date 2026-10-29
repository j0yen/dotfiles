#!/usr/bin/env bash
# Read-after-inject: the ledger row gains `injected`; the Stop hook scores Reads of those pages
# (realpath -m on both sides, symlinked vault path included); SessionStart prints `read-after-inject 7d: x/y`.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="$here/.claude/scripts"
FV="$here/tests/fixtures/summa-vault"
T="$(mktemp -d "${TMPDIR:-/tmp}/summa-rai.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "NOT OK - $2"; fail=1; fi; }

cp -a "$FV" "$T/real-vault"; ln -s "$T/real-vault" "$T/link-vault"   # SUMMA_VAULT is the symlink
L="$T/lookups.jsonl"; : >"$L"; D="$T/drafts"; SID="sid-rai-1"
export SUMMA_VAULT="$T/link-vault" SUMMA_LEDGER="$L" SUMMA_ANSWER_CANDIDATES_DIR="$D"
printf '%s' "$(jq -nc --arg p 'what is the verify and merge gates rule for the verifier protocol' --arg s "$SID" '{prompt:$p,session_id:$s}')" | bash "$S/summa-lookup-inject.sh" >/dev/null
mapfile -t INJ < <(jq -r '.injected[]' "$L")
[ "${#INJ[@]}" -ge 3 ]; chk $? "hook ledger row records injected paths (${#INJ[@]})"
A="${INJ[0]}"; B="${INJ[1]}"; C="${INJ[2]}"

mk_transcript() { # real-path read of A, symlink-path read of B, non-injected read, Grep of C (not a Read)
  sed -e "s|__SID__|$SID|g" -e "s|__READ_A__|$T/real-vault/$A|" -e "s|__READ_B__|$T/link-vault/$B|" \
      -e "s|__READ_OTHER__|$T/real-vault/wiki/entities/Carbon.md|" -e "s|__READ_C__|$T/real-vault/$C|" \
      "$here/tests/fixtures/summa-transcript-shape.jsonl" >"$T/tr.jsonl"
}
stop() { printf '%s' "$(jq -nc --arg s "$SID" --arg t "$T/tr.jsonl" '{session_id:$s,transcript_path:$t}')" | bash "$S/summa-answer-candidate.sh"; }
mk_transcript; stop
row="$(grep -F '"kind":"read-after-inject"' "$L" | tail -n1)"
exp_bytes=$(( $(printf '1\t# page A body line one\n2\tline two\n' | wc -c) + $(printf '1\t# page B body\n' | wc -c) ))
[ "$(jq -r '.read' <<<"$row")" = 2 ] && [ "$(jq -r '.injected' <<<"$row")" = "${#INJ[@]}" ]; chk $? "read=2 of injected=${#INJ[@]} (real-path Read + symlinked-path Read; Grep and a non-injected Read not counted)"
[ "$(jq -r '.bytes' <<<"$row")" = "$exp_bytes" ]; chk $? "bytes = sum of the two Read result sizes ($exp_bytes)"
[ "$(jq -r '.sid' <<<"$row")" = "$SID" ] && jq -e '.ts' <<<"$row" >/dev/null; chk $? "row carries ts + sid"

stop; [ "$(grep -cF '"kind":"read-after-inject"' "$L")" = 1 ]; chk $? "an unchanged second Stop appends nothing (one row)"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_D1","name":"Read","input":{"file_path":"'"$T/real-vault/$C"'"}}]},"sessionId":"'"$SID"'"}' >>"$T/tr.jsonl"
stop; row="$(grep -F '"kind":"read-after-inject"' "$L" | tail -n1)"
[ "$(jq -r '.read' <<<"$row")" = 3 ] && [ "$(grep -cF '"kind":"read-after-inject"' "$L")" = 2 ]; chk $? "a third page read appends a cumulative row (read=3)"
# a session with no injected rows writes no row
printf '%s' "$(jq -nc '{session_id:"sid-none",transcript_path:"'"$T/tr.jsonl"'"}')" | bash "$S/summa-answer-candidate.sh"
! grep -F '"sid":"sid-none"' "$L" | grep -q read-after-inject; chk $? "no injected rows for the sid -> no read-after-inject row"

# SessionStart: last row per sid, summed over 7 days; stale rows excluded
printf '%s\n' '{"ts":"2020-01-01T00:00:00Z","sid":"old","kind":"read-after-inject","read":9,"injected":9}' \
  "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"sid-two\",\"kind\":\"read-after-inject\",\"read\":1,\"injected\":4}" >>"$L"
out="$(bash "$S/summa-candidates-start.sh")"
grep -qx "read-after-inject 7d: 4/$(( ${#INJ[@]} + 4 ))" <<<"$out"; chk $? "SessionStart prints read-after-inject 7d: 4/$(( ${#INJ[@]} + 4 )) (last row per sid)"
! grep -q 'lookups last 7d' <<<"$out"; chk $? "the hit/miss line is replaced"
exit $fail
