#!/usr/bin/env bash
# followup-outbox-reconcile: .local/bin/followup-outbox-reconcile.py marks reviewed STALE-SUPERSEDED outbox entries by exact (id, rev, fp) in a sidecar,
# never rewrites outbox.jsonl, never touches CURRENT or UNKNOWN rows, and followup-eval.py replay skips sidecar identities but delivers the rest.
# Synthetic outbox + sidecar in an isolated HOME and state dir; delivery is a logging stub; no network, no live outbox.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-reconcile.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
REC="$here/.local/bin/followup-outbox-reconcile.py"; EV="$here/.local/bin/followup-eval.py"
export HOME="$base/home" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_DELIVER_CMD="$base/deliver.sh" DLOG="$base/delivered.log"
mkdir -p "$HOME" "$FOLLOWUP_STATE_DIR"
printf '#!/usr/bin/env bash\njq -r .id >>"$DLOG"\n' >"$base/deliver.sh"; chmod +x "$base/deliver.sh"
e() { jq -nc --arg id "$1" --argjson rev "$2" --arg fp "$3" --arg ts "$4" '{id:$id,rev:$rev,kind:"correction-owed",seat:"ctl",fp:$fp,detail:"x",ts:$ts,delivered:false}'; }
{ e S1 1 S1fp 2026-11-08T10:00:00; e C1 1 C1fp 2026-11-08T10:00:01; e U1 1 U1fp 2026-11-08T10:00:02
  e S2 2 S2fp-new 2026-11-08T10:00:03; e S3 3 S3fp 2026-11-08T10:00:04; e S4 1 S4fp 2026-11-08T10:00:05; } >"$base/snap.jsonl"
cp "$base/snap.jsonl" "$FOLLOWUP_OUTBOX"
e S4 1 S4fp 2026-11-08T11:00:00 >>"$FOLLOWUP_OUTBOX"   # same identity as a reviewed row but queued AFTER the snapshot
# classification: S2 was reviewed at fp S2fp-old / rev 1 (the live entry has a changed rev and fp); S3 is classified UNKNOWN-adjacent via rev mismatch
printf 'STALE-SUPERSEDED\tS1\t1\tcorrection-owed\tctl\tS1fp\task closed\nCURRENT-UNDELIVERED\tC1\t1\tcorrection-owed\tctl\tC1fp\topen\nUNKNOWN\tU1\t1\tcorrection-owed\tctl\tU1fp\tnot in ledger\nSTALE-SUPERSEDED\tS2\t1\tcorrection-owed\tctl\tS2fp-old\tclosed\nSTALE-SUPERSEDED\tS3\t2\tcorrection-owed\tctl\tS3fp\tclosed\nSTALE-SUPERSEDED\tS4\t1\tcorrection-owed\tctl\tS4fp\tclosed\n' >"$base/classified.tsv"
SIDE="$base/state/outbox.superseded.jsonl"; before="$(cksum <"$FOLLOWUP_OUTBOX")"

# 1. dry-run (default): lists the exact matches, writes nothing
out="$(python3 -I "$REC" --classified "$base/classified.tsv" --snapshot "$base/snap.jsonl" 2>&1)"
grep -q 'WOULD-SUPERSEDE S1 ' <<<"$out" && ! grep -q -E 'WOULD-SUPERSEDE (C1|U1|S2|S3) ' <<<"$out" && [ ! -e "$SIDE" ] && [ "$(cksum <"$FOLLOWUP_OUTBOX")" = "$before" ]
chk "1: dry-run lists S1 only, writes no sidecar, outbox untouched" $?

# 2. --apply: sidecar holds exactly S1 (+S4's pre-snapshot line) with evidence; outbox byte-identical; CURRENT, UNKNOWN, changed rev/fp and post-snapshot copies are not superseded
python3 -I "$REC" --classified "$base/classified.tsv" --snapshot "$base/snap.jsonl" --apply >/dev/null 2>&1; rc=$?
ids="$(jq -r '.id' "$SIDE" 2>/dev/null | sort | tr '\n' ' ')"
[ "$rc" = 0 ] && [ "$ids" = "S1 S4 " ] && jq -e -s 'any(.[]; .id=="S1" and .evidence=="ask closed" and .fp=="S1fp")' "$SIDE" >/dev/null && [ "$(cksum <"$FOLLOWUP_OUTBOX")" = "$before" ]
chk "2: apply writes sidecar {S1,S4} with evidence, outbox byte-identical (ids: $ids)" $?
! jq -e -s 'any(.[]; .id=="C1" or .id=="U1")' "$SIDE" >/dev/null 2>&1; chk "2: UNKNOWN U1 and CURRENT C1 are not in the sidecar" $?
! jq -e -s 'any(.[]; .id=="S2" or .id=="S3")' "$SIDE" >/dev/null 2>&1; chk "2: changed fp (S2) and changed rev (S3) are not superseded" $?
python3 -I "$REC" --classified "$base/classified.tsv" --snapshot "$base/snap.jsonl" --apply >/dev/null 2>&1; [ "$(wc -l <"$SIDE")" = 2 ]; chk "2: a second apply adds nothing" $?
grep -c '"delivered":false' "$FOLLOWUP_OUTBOX" | grep -qx 7; chk "2: all 7 outbox lines still delivered:false (U1 retained)" $?

# 3. replay: skips sidecar identities (id, rev, fp, entry ts), still delivers CURRENT, UNKNOWN, changed rev/fp and the post-snapshot S4 copy
: >"$DLOG"; python3 -I "$EV" replay >/dev/null 2>&1
got="$(sort "$DLOG" | tr '\n' ' ')"
[ "$got" = "C1 S2 S3 S4 U1 " ] && ! grep -qx S1 "$DLOG"; chk "3: replay delivers C1 S2 S3 U1 and the post-snapshot S4 copy, skips superseded S1 and the snapshot S4 line (got: $got)" $?

# 4. conflicting classification: CURRENT/UNKNOWN with the same identity as a STALE row vetoes it (either row order); apply without --snapshot is refused; truncated sidecar gets a newline first
export FOLLOWUP_STATE_DIR="$base/state4" FOLLOWUP_OUTBOX="$base/state4/outbox.jsonl"; mkdir -p "$FOLLOWUP_STATE_DIR"
SIDE="${FOLLOWUP_OUTBOX%.jsonl}.superseded.jsonl"
{ e K1 1 K1fp 2026-11-08T10:00:00; e K2 1 K2fp 2026-11-08T10:00:01; e K3 1 K3fp 2026-11-08T10:00:02; } >"$FOLLOWUP_OUTBOX"; cp "$FOLLOWUP_OUTBOX" "$base/snap4.jsonl"
printf 'CURRENT-UNDELIVERED\tK1\t1\tcorrection-owed\tctl\tK1fp\topen\nSTALE-SUPERSEDED\tK1\t1\tcorrection-owed\tctl\tK1fp\tclosed\nSTALE-SUPERSEDED\tK2\t1\tcorrection-owed\tctl\tK2fp\tclosed\nUNKNOWN\tK2\t1\tcorrection-owed\tctl\tK2fp\tnone\nSTALE-SUPERSEDED\tK3\t1\tcorrection-owed\tctl\tK3fp\tclosed\n' >"$base/classified4.tsv"
out="$(python3 -I "$REC" --classified "$base/classified4.tsv" --snapshot "$base/snap4.jsonl" 2>&1)"
grep -q 'WOULD-SUPERSEDE K3 ' <<<"$out" && ! grep -q -E 'WOULD-SUPERSEDE (K1|K2) ' <<<"$out"; chk "4: CURRENT/STALE and STALE/UNKNOWN conflicts veto the STALE row (dry-run lists K3 only)" $?
python3 -I "$REC" --classified "$base/classified4.tsv" --apply >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -e "$SIDE" ]; chk "4: apply without --snapshot is refused (rc=$rc), no sidecar written" $?
python3 -I "$REC" --classified "$base/classified4.tsv" --snapshot "$base/snap4.jsonl" --apply >/dev/null 2>&1
[ "$(jq -r .id "$SIDE" | tr '\n' ' ')" = "K3 " ]; chk "4: apply with conflicts supersedes K3 only" $?
printf '{"id":"zz","entry_ts":"2' >"$SIDE"   # crash-truncated sidecar, no trailing newline
printf 'STALE-SUPERSEDED\tK1\t1\tcorrection-owed\tctl\tK1fp\tclosed\n' >"$base/classified5.tsv"
python3 -I "$REC" --classified "$base/classified5.tsv" --snapshot "$base/snap4.jsonl" --apply >/dev/null 2>&1
[ "$(wc -l <"$SIDE")" = 2 ] && [ "$(tail -n1 "$SIDE" | jq -r .id)" = K1 ] && head -n1 "$SIDE" | grep -qx '{"id":"zz","entry_ts":"2'; chk "4: truncated sidecar gets a newline before the append (new line is valid JSON on its own line)" $?
