#!/usr/bin/env bash
# Hub coverage alarm: each of the 30 most frequent real keyword shapes must map to ONE hub page.
# The ranker (summa-lookup-inject.sh v2) runs over a vault holding only the hub pages of the fixture vault.
# Column 2 is what v2 yields TODAY over the hubs: the hub title when exactly one hub page is emitted and it is the judged subject, NO-HIT for a probe prompt,
# MISSING-HUB otherwise (zero, several, or the wrong hub: no single match). Column 3 is the judged subject (informational: which hub should answer).
# A shape marked MISSING-HUB is printed and FAILS the test: that is the alarm.
# There is no skip switch; fix it by writing the hub page, then editing the TSV line to its title.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
H="$here/.claude/scripts/summa-lookup-inject.sh"
FV="$here/tests/fixtures/summa-vault"
TSV="$here/tests/fixtures/summa-hub-coverage.tsv"
T="$(mktemp -d "${TMPDIR:-/tmp}/summa-cov.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/v/wiki"
for d in entities playbooks answers; do
  mkdir -p "$T/v/wiki/$d"
  for f in "$FV/wiki/$d"/*.md; do
    [ -e "$f" ] || continue
    awk 'NR==1&&$0!="---"{exit 1} NR>1&&$0=="---"{exit !h} /^tags:.*hub|^  - hub/{h=1}' "$f" && cp "$f" "$T/v/wiki/$d/"
  done
done
nhub="$(find "$T/v/wiki" -name '*.md' | wc -l)"
[ "$nhub" -ge 30 ] && echo "ok - hub-only fixture vault: $nhub pages" || { echo "NOT OK - hub-only fixture vault has $nhub pages"; fail=1; }

lines="$(grep -v '^#' "$TSV" | grep -c .)"
[ "$lines" = 30 ] && echo "ok - 30 keyword shapes" || { echo "NOT OK - $lines shapes in the TSV (want 30)"; fail=1; }

# positive control: the harness can see a covered subject (so 29 MISSING-HUB lines mean 29 uncovered shapes, not a broken runner)
L="$T/control.jsonl"; : >"$L"
printf '%s' "$(jq -nc '{prompt:"landing train rb-manual-train",session_id:"ctl"}')" | SUMMA_VAULT="$T/v" SUMMA_LEDGER="$L" bash "$H" >/dev/null
[ "$(jq -c '.injected' "$L")" = '["wiki/entities/Landing Train.md"]' ] && echo "ok - control: "landing train rb-manual-train" maps to exactly Landing Train" || { echo "NOT OK - control shape did not map to exactly Landing Train: $(jq -c '.injected' "$L")"; fail=1; }

i=0; missing=0; wrong=0
while IFS=$'\t' read -r kw expect judged; do
  [ -n "$kw" ] || continue
  i=$((i + 1))
  L="$T/l$i.jsonl"; : >"$L"
  printf '%s' "$(jq -nc --arg p "$kw" --arg s "cov$i" '{prompt:$p,session_id:$s}')" | SUMMA_VAULT="$T/v" SUMMA_LEDGER="$L" bash "$H" >/dev/null
  mapfile -t got < <(jq -r '.injected[]?' "$L" 2>/dev/null)
  if [ "$expect" = "MISSING-HUB" ]; then
    echo "MISSING-HUB: [$kw] ranker emits ${#got[@]} hub page(s)${got[*]:+: $(printf '%s; ' "${got[@]##*/}")} judged subject: ${judged:-?}"
    missing=$((missing + 1)); continue
  fi
  if [ "$expect" = "NO-HIT" ]; then
    [ "${#got[@]}" = 0 ] || { echo "WRONG: [$kw] is a probe prompt, must inject nothing; got ${got[*]}"; wrong=$((wrong + 1)); }
    continue
  fi
  if [ "${#got[@]}" != 1 ] || [ "$(basename "${got[0]}" .md)" != "$expect" ]; then
    echo "WRONG: [$kw] expected exactly one hub '$expect', ranker gave ${#got[@]}: ${got[*]:-none}"; wrong=$((wrong + 1))
  fi
done < <(grep -v '^#' "$TSV")
[ "$missing" = 0 ]; r=$?; [ "$r" = 0 ] && echo "ok - no MISSING-HUB shapes" || { echo "NOT OK - $missing shape(s) have no hub page (MISSING-HUB above)"; fail=1; }
[ "$wrong" = 0 ]; r=$?; [ "$r" = 0 ] && echo "ok - every other shape maps to its hub" || { echo "NOT OK - $wrong shape(s) map to the wrong page or none"; fail=1; }
exit $fail
