#!/usr/bin/env bash
# fable-launch-review AC 7: the log is append-only (unchanged prefix, fourteen-field rows, R8); every scope vector holds via a launcher row (R9);
# rows.jsonl matches a replay. Compares against the checked-in fixture and never regenerates it. Run alone: bash tests/fable-launch-review_ac07_append_only_vectors.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin torn
V="$FX/scope-vectors.tsv"
ck "scope-vectors.tsv present with its header" '[ "$(head -1 "$V" 2>/dev/null)" = "$(printf "manifest\tcanonical\tlauncher")" ]'
ck "every manifest in the fixture directory has one vector row" '[ "$(cd "$FX" && ls *.sha256 | sort | tr "\n" " ")" = "$(tail -n +2 "$V" 2>/dev/null | cut -f1 | sort | tr "\n" " ")" ]'
while IFS=$'\t' read -r man canon lch; do
  n="${man%.sha256}"; got="$(flr_vector "$n")"; gl="${got%%$'\t'*}"; gid="${got#*$'\t'}"
  case "$lch" in
    ok|refused:no-prd|refused:sha256sum)
      ck "vector $man: launcher $lch and its row's scope_id equals canonical" '[ "$gl" = "$lch" ] && [ "$gid" = "$canon" ] && [ ${#canon} = 64 ]' ;;
    *)
      ck "vector $man: refused, reason names ${lch#refused:}, scope_id empty" '[ "$gl" = "$lch" ] && [ "$canon" = "$lch" ] && [ -z "$gid" ]' ;;
  esac
done < <(tail -n +2 "$V" 2>/dev/null)
ck "vectors happy, reordered, prefixed, dupline share one id; dupname and single differ" 'h="$(awk -F"\t" "\$1==\"happy.sha256\"{print \$2}" "$V")"; [ -n "$h" ] && [ "$(awk -F"\t" -v h="$h" "(\$1==\"reordered.sha256\"||\$1==\"prefixed.sha256\"||\$1==\"dupline.sha256\")&&\$2==h" "$V" | wc -l)" = 3 ] && [ "$(awk -F"\t" -v h="$h" "(\$1==\"dupname.sha256\"||\$1==\"single.sha256\")&&\$2!=h" "$V" | wc -l)" = 2 ]'
flr_rows_scenario RS-ROWS >"$T/rows.replay"
ck "rows.jsonl matches the replayed rows (all fields but ts, session, account, ids/pids in reasons)" '[ -s "$FX/rows.jsonl" ] && diff <(flr_norm <"$FX/rows.jsonl") <(flr_norm <"$T/rows.replay")'
ck "rows.jsonl rows: author launch, review launch, same-scope denied, author denied, resume denied" '[ "$(jq -r "[.decision,.role]|join(\":\")" "$FX/rows.jsonl" 2>/dev/null | tr "\n" " ")" = "launch:author launch:review denied:review denied:author denied:review " ]'
ck "rows after the torn line are read: the author denied row named the live author" 'flr_get rs4 .reasons | grep -qF "$(flr_get rs1 .session)"'
ck "README names the launcher source commit and sha256" 'grep -qE "commit: \`[0-9a-f]{40}\`" "$FX/README.md" && grep -qE "sha256 \`[0-9a-f]{64}\`" "$FX/README.md"'
flr_end
