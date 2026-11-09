#!/usr/bin/env bash
# followup-suggestion (ledger ask A1346 amendment, W4): a typed suggestion-only final message with no owned next action is a defect the one evaluator
# (.local/bin/followup-eval.py suggestion) flags; the same message with an owner + due passes; a repeat is deduped through the emit fingerprint store.
# Fixture state dir only; no real ledger.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
base="$(mktemp -d "${TMPDIR:-/tmp}/followup-suggestion.XXXXXX")"; trap 'rm -rf "$base"' EXIT
fail=0; pass=0
chk() { if [ "$2" = 0 ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
EV="$here/.local/bin/followup-eval.py"
export HOME="$base/home" FOLLOWUP_STATE_DIR="$base/state" FOLLOWUP_OUTBOX="$base/state/outbox.jsonl" FOLLOWUP_NOW="2026-11-08T12:00"
mkdir -p "$HOME"
BAD='I recommend moving the retry guard into the shared hook, and the next step would be to add a regression test for it.'
FACT='The hook ran at 10:41 and exited 0; nothing else changed.'
sug() { printf '%s' "$MSG" | python3 -I "$EV" suggestion --seat ctl --id T1 --rev 1 "$@"; }
# (a) suggestion-only, no owned next action: flagged (exit 1), one outbox line
MSG="$BAD"; out="$(sug 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && jq -e '.flagged==true and .emitted==true' <<<"$out" >/dev/null; chk "a: suggestion-only message is flagged and emitted (rc $rc)" $?
[ "$(wc -l <"$FOLLOWUP_OUTBOX")" = 1 ] && jq -e '.kind=="suggestion-only" and .delivered==false' "$FOLLOWUP_OUTBOX" >/dev/null; chk "a: one outbox line of kind suggestion-only" $?
# a/control: a factual message with no suggestion is not flagged
MSG="$FACT"; out="$(sug 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && jq -e '.flagged==false' <<<"$out" >/dev/null; chk "a: factual message is not flagged (rc $rc)" $?
# (b) same message with an owner and a due passes and persists nothing
rm -rf "$FOLLOWUP_STATE_DIR"
MSG="$BAD"; out="$(sug --owner ctl --due 2026-11-08T15:00 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && jq -e '.flagged==false' <<<"$out" >/dev/null && [ ! -s "$FOLLOWUP_OUTBOX" ]; chk "b: owned next action with due passes, no outbox line (rc $rc)" $?
MSG="$BAD"; sug --owner ctl >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ]; chk "b: owner without a due is still a defect (rc $rc)" $?
# (c) repeating the same suggestion dedupes through the emit fingerprint store (one store, one outbox line)
rm -rf "$FOLLOWUP_STATE_DIR"
MSG="$BAD"; sug >/dev/null 2>&1; out="$(sug 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && jq -e '.flagged==true and .emitted==false and .deduped==true' <<<"$out" >/dev/null; chk "c: repeat is flagged but deduped (rc $rc)" $?
[ "$(wc -l <"$FOLLOWUP_OUTBOX")" = 1 ] && [ "$(ls "$FOLLOWUP_STATE_DIR" | sort | paste -sd, -)" = "fingerprints.json,lock,outbox.jsonl" ]; chk "c: still one outbox line and no second store" $?
fp="$(jq -r '.fp' "$FOLLOWUP_OUTBOX")"; jq -e --arg fp "$fp" 'has($fp)' "$FOLLOWUP_STATE_DIR/fingerprints.json" >/dev/null; chk "c: the fp sits in the shared fingerprints.json" $?
python3 -I "$EV" emit --seat ctl --id T1 --rev 1 --kind suggestion-only --fp "$fp" --detail d | jq -e '.deduped==true' >/dev/null; chk "c: plain emit of that fp is deduped too" $?
MSG="$BAD Also add a lint."; out="$(sug 2>/dev/null)"; jq -e '.emitted==true' <<<"$out" >/dev/null; chk "c: a changed message is a new fingerprint" $?
echo "followup-suggestion: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
