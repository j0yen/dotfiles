#!/usr/bin/env bash
# Provenance only (the tests never run this): how tests/fixtures/summa-lookup-rank.jsonl rows and
# tests/fixtures/summa-vault/ were selected from the REAL ledger and vault (read-only).
# usage: summa-rank-gen.sh <ledger> <vault-root> <outdir>
set -euo pipefail
L="$1"; V="$2"; O="$3"; mkdir -p "$O"
# 20 = the most frequent distinct keyword sets with >= 2 keywords
jq -c 'select(.keywords != null and (.keywords|length) >= 2) | .keywords' "$L" | sort | uniq -c | sort -rn | head -20 | sed -E 's/^ *[0-9]+ //' >"$O/top20.txt"
# 10 = random distinct sets (>= 2 keywords) outside the top 20, fixed seed
jq -c 'select(.keywords != null and (.keywords|length) >= 2) | .keywords' "$L" | sort -u | grep -vxFf "$O/top20.txt" \
  | shuf -n 10 --random-source=<(yes summa-rank-seed-1029) >"$O/rand10.txt"

# ---- part 2: fixture vault (trimmed copies) + rows --------------------------
set +e
# usage after part 1: summa-rank-gen.sh <ledger> <vault-root> <outdir> <repo>   (writes under <repo>/tests/fixtures)
R="${4:-}"; [ -n "$R" ] || exit 0
FV="$R/tests/fixtures/summa-vault"; rm -rf "$FV"; mkdir -p "$FV/wiki/entities" "$FV/wiki/answers" "$FV/wiki/playbooks"
{ sed 's/$/\ttop20/' "$O/top20.txt"; sed 's/$/\trand10/' "$O/rand10.txt"
  printf '["seat","events","2026"]\tspec\n["wait","lets","switch","models"]\tspec\n'; } >"$O/all.tsv"   # the two spec rows are NOT in this host's ledger
trim() { # <src> <dst>: frontmatter minus sources:, plus the first paragraph; padded to >= 200 body bytes unless a mention stub
  awk 'NR==1&&$0=="---"{fm=1;print;next} fm&&$0=="---"{fm=0;skip=0;print;next} fm{ if($0 ~ /^sources:/){skip=1;next} if(skip&&$0 ~ /^[ \t]*-/)next; skip=0; print;next}
       !fm{ if($0 ~ /^[ \t]*$/||$0 ~ /^#/){ if(inp)exit; next } print; inp=1 }' "$1" | grep -viE 'key|token|password|secret' >"$2"
  if ! grep -q '^## Mentions' "$1"; then printf '\nFixture body: a trimmed copy of the real page, padded so the stub check (body outside a Mentions section < 200 bytes) does not exclude it. Padding padding padding padding padding padding padding.\n' >>"$2"; fi
}
copy() { # <rel wiki path>
  mkdir -p "$(dirname "$FV/$1")"; [ -f "$FV/$1" ] || trim "$V/$1" "$FV/$1"; }
# every hub page
grep -rlw --include='*.md' hub "$V/wiki" | while read -r f; do awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} /^tags:.*hub|^  - hub/{h=1} END{exit !h}' "$f" && copy "wiki/${f#"$V"/wiki/}"; done
# the base ranker's top page for every row + every page the new ranker emits for any row
i=0
while IFS=$'\t' read -r k src; do i=$((i+1))
  jq -r --argjson k "$k" 'select(.keywords==$k)|.pages[]?' "$1" | sort -u | while read -r p; do [ -f "$V/$p" ] && copy "$p"; done
  pr="$(jq -r 'join(" ")' <<<"$k")"
  printf '%s' "$(jq -nc --arg p "$pr" --arg s "g$i" '{prompt:$p,session_id:$s}')" | SUMMA_VAULT="$V" SUMMA_LEDGER="$O/g$i.jsonl" bash "$R/.claude/scripts/summa-lookup-inject.sh" >/dev/null
  jq -r '.pages[]?' "$O/g$i.jsonl" 2>/dev/null | while read -r p; do copy "$p"; done
done <"$O/all.tsv"
# decoys: 5 real mention-only stubs + 12 seeded-random pages
ls "$V"/wiki/entities/*.md | shuf -n 5 --random-source=<(yes stub-seed) | while read -r f; do [ "$(wc -c <"$f")" -lt 400 ] && copy "wiki/entities/$(basename "$f")"; done
ls "$V"/wiki/entities/*.md "$V"/wiki/answers/*.md | shuf -n 12 --random-source=<(yes decoy-seed) | while read -r f; do copy "wiki/${f#"$V"/wiki/}"; done
