#!/usr/bin/env bash
# Ranker v2 of summa-lookup-inject.sh, replayed over 32 real/spec keyword arrays against a
# trimmed fixture vault (tests/fixtures/summa-vault; provenance: tests/fixtures/summa-rank-gen.sh).
# Row `expect` = the top injected page (first line of the ledger row's `injected`) or NO-HIT.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
H="$here/.claude/scripts/summa-lookup-inject.sh"
FV="$here/tests/fixtures/summa-vault"
ROWS="$here/tests/fixtures/summa-lookup-rank.jsonl"
T="$(mktemp -d "${TMPDIR:-/tmp}/summa-rank.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "NOT OK - $2"; fail=1; fi; }
hook() { # <vault> <ledger> <sid> <prompt> -> stdout of the hook
  printf '%s' "$(jq -nc --arg p "$4" --arg s "$3" '{prompt:$p,session_id:$s}')" | SUMMA_VAULT="$1" SUMMA_LEDGER="$2" bash "$H"
}

# (1) replay every row
n=0; bad=0; i=0
while IFS= read -r row; do
  i=$((i + 1)); n=$((n + 1))
  k="$(jq -r '.keywords | join(" ")' <<<"$row")"; exp="$(jq -r '.expect' <<<"$row")"
  L="$T/r$i.jsonl"; : >"$L"
  hook "$FV" "$L" "row$i" "$k" >/dev/null
  got="$(jq -r '.injected[0] // "NO-HIT"' "$L" 2>/dev/null | head -n1)"; [ -n "$got" ] || got=NO-HIT
  if [ "$got" != "$exp" ]; then bad=$((bad + 1)); echo "  row $i [$k]: expected '$exp' got '$got'"; fi
done <"$ROWS"
[ "$n" -ge 30 ] && [ "$bad" = 0 ]; chk $? "replay: $n rows, $bad mismatches"

# (2) the two spec shapes are present and are NO-HIT
jq -e -s 'any(.[]; .keywords==["seat","events","2026"] and .expect=="NO-HIT") and any(.[]; .keywords==["wait","lets","switch","models"] and .expect=="NO-HIT")' "$ROWS" >/dev/null; chk $? "seat/events/2026 and wait/lets/switch/models rows expect NO-HIT"
L="$T/stop.jsonl"; : >"$L"; out="$(hook "$FV" "$L" s0 'seat events 2026 wait lets status event')"
[ -z "$out" ] && [ ! -s "$L" ]; chk $? "stopwords (seat event events wait lets status, 20xx years) leave no keyword: no output, no row"

# (3) a hub-subsystem query injects the hub page first
L="$T/hub.jsonl"; : >"$L"; out="$(hook "$FV" "$L" h1 'how does the parked prds capacity work')"
[ "$(jq -r '.injected[0]' "$L")" = "wiki/entities/Parked PRDs.md" ]; chk $? "hub query -> wiki/entities/Parked PRDs.md first"
[ "$(jq -c '.injected == .pages' "$L")" = true ] && grep -qF 'wiki/entities/Parked PRDs.md' <<<"$out"; chk $? "ledger injected == emitted pages"

# (4) same sid again: nothing re-injected; another sid injects again
out2="$(hook "$FV" "$L" h1 'how does the parked prds capacity work')"
[ -z "$out2" ] && [ "$(tail -n1 "$L" | jq -c '.injected')" = "[]" ] && [ "$(tail -n1 "$L" | jq '.deduped')" -ge 1 ]; chk $? "second identical-sid query: no re-injection"
out3="$(hook "$FV" "$L" h2 'how does the parked prds capacity work')"
grep -qF 'wiki/entities/Parked PRDs.md' <<<"$out3"; chk $? "a different sid injects the page again"

# (5) kill: rows whose base ranker top was a five-whys post-mortem now resolve to a hub page
k=0
while IFS= read -r row; do
  bt="$(jq -r '.base_top' <<<"$row")"; ex="$(jq -r '.expect' <<<"$row")"
  case "$bt" in */answers/*five-whys*) ;; *) continue ;; esac
  [ "$ex" != "NO-HIT" ] || continue
  grep -qE '^tags:.*hub' "$FV/$ex" && k=$((k + 1))
done <"$ROWS"
[ "$k" -ge 1 ]; chk $? "post-mortem-top rows now resolving to a hub: $k"

# (6) mention-only stubs are excluded; the same page with real body qualifies
V2="$T/v2"; cp -a "$FV" "$V2"
{ printf -- '---\nsumma: entity\ntitle: Zorblax Quindle Gateway\ncreated: 2026-06-21T00:00:00Z\n---\n\n## Mentions\n\n'
  for i in 1 2 3 4 5 6; do printf -- '- [[Doc %s]] — zorblax quindle gateway mentioned in a long ingest line of text number %s\n' "$i" "$i"; done; } >"$V2/wiki/entities/Zorblax Quindle Gateway.md"
L="$T/stub.jsonl"; : >"$L"; out="$(hook "$V2" "$L" st1 'zorblax quindle gateway')"
! grep -q Zorblax <<<"$out"; chk $? "mention-only stub (body only under ## Mentions) is not injected"
printf '\nThe Zorblax Quindle Gateway routes inbound requests to the fleet and is owned by the aide. It is configured in one file and restarted by a timer when it dies.\n' >>"$V2/wiki/entities/Zorblax Quindle Gateway.md"
sed -i 's/^## Mentions$/## Notes/' "$V2/wiki/entities/Zorblax Quindle Gateway.md"
L="$T/stub2.jsonl"; : >"$L"; out="$(hook "$V2" "$L" st2 'zorblax quindle gateway')"
grep -q Zorblax <<<"$out"; chk $? "the same page with >= 200 B of body outside ## Mentions is injected"

# (7) one keyword match is not enough (threshold is 2)
L="$T/one.jsonl"; : >"$L"; out="$(hook "$FV" "$L" o1 'parked')"
[ -z "$out" ]; chk $? "a single keyword match does not qualify"
exit $fail
