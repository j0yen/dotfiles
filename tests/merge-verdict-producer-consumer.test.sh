#!/usr/bin/env bash
# producer -> consumers: the row verifier-record.sh writes (stub wm-decide captures argv) is accepted by the rb-merge pre-gate A parse (merge_verdict_grammar.parse_ex, the
# helper that block imports) and selected by fleet-merge.sh; the same row with COMMIT one hex digit off the live head is skipped. All externals stubbed; no network, no ledger.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
H="7b5d87787ea9bd9368a4ebb3906e293edc4dd3c2"
HX="7b5d87787ea9bd9368a4ebb3906e293edc4dd3c3"   # one hex digit different
# stub gh: `pr view .. --json url` (producer) and `pr list` (fleet-merge)
cat > "$T/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"--json url"*) echo "https://github.com/j0yen/mcphost/pull/541" ;;
  *"pr list"*) cat "$STUB_PRS" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/wmd" <<'SH'
#!/usr/bin/env bash
if [ "$1" = record ]; then printf '%s\0' "$@" > "$STUB_ARGV"; exit 0; fi
cat "$STUB_ROWS"
SH
cat > "$T/rbm" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
echo "PASS stub"
SH
chmod +x "$T/gh" "$T/wmd" "$T/rbm"
export VERIFIER_RECORD_GH="$T/gh" FLEET_MERGE_GH="$T/gh" WM_DECIDE_BIN="$T/wmd" FLEET_MERGE_RB_MERGE="$T/rbm" FLEET_MERGE_STATE="$T/state"
export FLEET_MERGE_REPOS="j0yen/mcphost" STUB_PRS="$T/prs.json" STUB_ROWS="$T/rows.json" STUB_CALLS="$T/calls" STUB_ARGV="$T/argv"
: > "$T/calls"
log="$T/bundle.log"; printf 'suite output\nWM-VERIFY HEAD=%s\nWM-VERIFY CMD=echo ok\nWM-VERIFY DIRTY=0\nWM-VERIFY EXIT=0\n' "$H" > "$log"

# producer
bash "$here/.local/bin/verifier-record.sh" --pr j0yen/mcphost#541 --suite "$log" --agent aide --name v541 --note "scope=suite ok" -- --gates d-1 >/dev/null
what="$(python3 -I -c 'import sys; a=open(sys.argv[1],"rb").read().split(b"\0"); print(a[a.index(b"--what")+1].decode())' "$T/argv")"
[ "$what" = "MERGE-OK j0yen/mcphost#541 COMMIT=$H agent=verifier:aide-verifier-v541 scope=suite ok" ] && ok producer-row-shape || bad "producer-row-shape: $what"
tr '\0' ' ' < "$T/argv" | grep -q -- '--via verifier --kind verdict .*--gates d-1' && ok producer-argv || bad "producer-argv: $(tr '\0' ' ' < "$T/argv")"
# no suite: free text + NOT-MERGE-GRADE, never a MERGE-OK line
err="$(bash "$here/.local/bin/verifier-record.sh" --pr j0yen/mcphost#541 --agent aide --name v541 2>&1 >/dev/null)"
[ "$err" = "NOT-MERGE-GRADE: no suite head" ] && ok no-suite-not-merge-grade || bad "no-suite: $err"
w2="$(python3 -I -c 'import sys; a=open(sys.argv[1],"rb").read().split(b"\0"); print(a[a.index(b"--what")+1].decode())' "$T/argv")"
case "$w2" in CONFIRM*) ok no-suite-row-is-confirm-text ;; *) bad "no-suite row: $w2" ;; esac

# consumer 1: the rb-merge pre-gate A parse (same module, same env the wrapper exports by sourcing the lib)
. "$here/.local/lib/merge-verdict-grammar.sh"
res="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import merge_verdict_grammar as m; r, d = m.parse_ex(sys.argv[2]); print(r or "OK", *(d if not r else []))' "$here/.local/lib" "$what")"
[ "$res" = "OK j0yen mcphost 541 $H aide-verifier-v541" ] && ok rb-merge-parse-accepts || bad "rb-merge-parse: $res"

# consumer 2: fleet-merge plan selection
printf '[{"id":"d-v1","ts":"2026-11-02T04:00:00+00:00","via":"verifier","agent":"aide","kind":"verdict","what":"%s","evidence":""}]' "$what" > "$T/rows.json"
printf '[{"number":541,"headRefOid":"%s","title":"t"}]' "$H" > "$T/prs.json"
bash "$here/.local/bin/fleet-merge.sh" >/dev/null
[ "$(cat "$T/calls")" = "d-v1 541 j0yen/mcphost" ] && ok fleet-merge-selects-live-head || bad "fleet-merge-selects: $(cat "$T/calls")"
: > "$T/calls"; rm -rf "$T/state"
printf '[{"number":541,"headRefOid":"%s","title":"t"}]' "$HX" > "$T/prs.json"
out="$(bash "$here/.local/bin/fleet-merge.sh")"
[ ! -s "$T/calls" ] && ok fleet-merge-skips-moved-head || bad "fleet-merge-skips-moved-head: $(cat "$T/calls")"
# a 12-hex prefix of the live head is not a head
: > "$T/calls"
printf '[{"id":"d-v2","ts":"2026-11-02T04:00:00+00:00","via":"verifier","agent":"aide","kind":"verdict","what":"j0yen/mcphost#541 head %s CONFIRM ok","evidence":""}]' "${H:0:12}" > "$T/rows.json"
printf '[{"number":541,"headRefOid":"%s","title":"t"}]' "$H" > "$T/prs.json"
out="$(bash "$here/.local/bin/fleet-merge.sh")"
[ ! -s "$T/calls" ] && printf '%s\n' "$out" | grep -q 'confirm-not-canonical' && ok fleet-merge-skips-legacy-prefix-row || bad "legacy row: $out"
# a newer block row on the canonical row's PR blocks it
: > "$T/calls"
printf '[{"id":"d-v1","ts":"2026-11-02T04:00:00+00:00","via":"verifier","agent":"aide","kind":"verdict","what":"%s","evidence":""},{"id":"d-b1","ts":"2026-11-02T05:00:00+00:00","via":"controller","agent":"controller","kind":"verdict","what":"CORRECT j0yen/mcphost#541 head %s no","evidence":""}]' "$what" "${H:0:12}" > "$T/rows.json"
bash "$here/.local/bin/fleet-merge.sh" >/dev/null
[ ! -s "$T/calls" ] && ok fleet-merge-newer-block-wins || bad "newer block: $(cat "$T/calls")"
[ "$fail" = 0 ] && echo "ALL PASS merge-verdict-producer-consumer" || { echo "FAILED merge-verdict-producer-consumer"; exit 1; }
