#!/usr/bin/env bash
# fleet-merge.sh: eligibility, gh --limit, headless CONFIRM, real JSON-array shape, newer-block, gate refusal, dry-run, per-tick cap. All externals stubbed; mktemp HOME; no network.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/.local/bin/fleet-merge.sh"
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
cat > "$T/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_GHARGS"
cat "$STUB_PRS"
SH
cat > "$T/wmd" <<'SH'
#!/usr/bin/env bash
cat "$STUB_ROWS"
SH
cat > "$T/rbm" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
if [ -n "${STUB_RC:-}" ] && [ "$STUB_RC" != 0 ]; then echo "G3 required tokens not shown" >&2; exit "$STUB_RC"; fi
echo "PASS stub"
SH
chmod +x "$T/gh" "$T/wmd" "$T/rbm"
export FLEET_MERGE_GH="$T/gh" WM_DECIDE_BIN="$T/wmd" FLEET_MERGE_RB_MERGE="$T/rbm" FLEET_MERGE_STATE="$T/state"
export FLEET_MERGE_REPOS="j0yen/dotfiles" STUB_PRS="$T/prs.json" STUB_ROWS="$T/rows.json" STUB_CALLS="$T/calls" STUB_GHARGS="$T/ghargs"
H1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; H2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
reset() { rm -rf "$T/state" "$T/calls"; : > "$T/calls"; : > "$T/ghargs"; unset STUB_RC; }
row() { # id ts via what
  printf '{"id":"%s","ts":"%s","via":"%s","agent":"%s","kind":"verdict","what":"%s","evidence":""}' "$1" "$2" "$3" "$3" "$4"
}
receipt() { python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])[sys.argv[2]])' "$T/state/ticks.jsonl" "$1"; }

# (a) one PR with a CONFIRM row
reset
echo "[{\"number\":7,\"headRefOid\":\"$H1\",\"title\":\"t\"}]" > "$T/prs.json"
echo "[$(row d-1 2026-11-01T01:00:00+00:00 verifier "dotfiles#7 head aaaaaaaa CONFIRM looks good")]" > "$T/rows.json"
out="$(bash "$script")"
[ "$(cat "$T/calls")" = "d-1 7 j0yen/dotfiles" ] && ok a-call-args || bad a-call-args
printf '%s\n' "$out" | grep -qx 'MERGED j0yen/dotfiles#7' && ok a-merged-line || bad a-merged-line
[ "$(receipt merged)" = 1 ] && ok a-receipt-merged || bad a-receipt-merged

# (b) a newer CORRECT row on the same head blocks
reset
echo "[$(row d-1 2026-11-01T01:00:00+00:00 verifier "dotfiles#7 head aaaaaaaa CONFIRM ok"),$(row d-2 2026-11-01T02:00:00+00:00 controller "dotfiles#7 head aaaaaaaa CORRECT no")]" > "$T/rows.json"
out="$(bash "$script")"
[ ! -s "$T/calls" ] && ok b-not-called || bad b-not-called
[ "$(receipt skipped)" = 1 ] && ok b-skipped || bad b-skipped

# (c) rb-merge rc 2 with a G3 stderr line
reset
echo "[$(row d-1 2026-11-01T01:00:00+00:00 verifier "dotfiles#7 head aaaaaaaa CONFIRM ok")]" > "$T/rows.json"
rc=0; STUB_RC=2 bash "$script" > "$T/out.txt" || rc=$?
[ "$rc" = 0 ] && ok c-tick-rc0 || bad c-tick-rc0
[ "$(receipt refused_by_gate)" = "{'G3': 1}" ] && ok c-refused-G3 || bad c-refused-G3
[ "$(receipt merged)" = 0 ] && ok c-not-merged || bad c-not-merged

# (d) --dry-run never calls rb-merge
reset
out="$(bash "$script" --dry-run)"
[ ! -s "$T/calls" ] && ok d-dry-run-no-call || bad d-dry-run-no-call
printf '%s\n' "$out" | grep -q '^DRY-RUN' && ok d-dry-run-prints || bad d-dry-run-prints

# (e) FLEET_MERGE_MAX=1, two eligible PRs: only the older merges
reset
echo "[{\"number\":9,\"headRefOid\":\"$H2\",\"title\":\"t\"},{\"number\":7,\"headRefOid\":\"$H1\",\"title\":\"t\"}]" > "$T/prs.json"
echo "[$(row d-1 2026-11-01T01:00:00+00:00 verifier "dotfiles#7 head aaaaaaaa CONFIRM ok"),$(row d-3 2026-11-01T01:30:00+00:00 verifier "dotfiles#9 head bbbbbbbb CONFIRM ok")]" > "$T/rows.json"
FLEET_MERGE_MAX=1 bash "$script" > /dev/null
[ "$(cat "$T/calls")" = "d-1 7 j0yen/dotfiles" ] && ok e-only-older || bad e-only-older

# (f) gh pr list is called with --limit 500
reset
echo "[{\"number\":7,\"headRefOid\":\"$H1\",\"title\":\"t\"}]" > "$T/prs.json"
echo "[$(row d-1 2026-11-01T01:00:00+00:00 verifier "dotfiles#7 head aaaaaaaa CONFIRM ok")]" > "$T/rows.json"
bash "$script" > /dev/null
grep -q -- '--limit 500' "$T/ghargs" && ok f-gh-limit-500 || bad f-gh-limit-500

# (g) a CONFIRM row without a head matches no head; the receipt line names the reason
reset
printf '[{"id":"d-9","ts":"2026-11-01T01:00:00+00:00","via":"verifier","agent":"verifier","kind":"verdict","what":"CONFIRM dotfiles#7 no head named","evidence":""}]' > "$T/rows.json"
out="$(bash "$script")"
[ ! -s "$T/calls" ] && ok g-headless-not-called || bad g-headless-not-called
printf '%s\n' "$out" | grep -q 'skip: confirm-without-head j0yen/dotfiles#7' && ok g-headless-reason || bad g-headless-reason

# (h) real wm-decide list --json shape (pretty-printed array): observe row ignored, constructed CONFIRM found
reset
echo "[{\"number\":7,\"headRefOid\":\"cccccccccccccccccccccccccccccccccccccccc\",\"title\":\"t\"}]" > "$T/prs.json"
STUB_ROWS="$here/tests/fixtures/wm-decide-list-sample.json" bash "$script" > /dev/null
[ "$(cat "$T/calls")" = "d-20261101-014500-verifier-dotfiles-7-c0de 7 j0yen/dotfiles" ] && ok h-fixture-confirm-found || bad h-fixture-confirm-found
[ "$fail" = 0 ] && echo "ALL PASS fleet-merge" || { echo "FAILED fleet-merge"; exit 1; }
