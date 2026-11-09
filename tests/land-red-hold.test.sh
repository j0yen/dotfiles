#!/usr/bin/env bash
# tests/land-red-hold.test.sh: hermetic test of .local/bin/land-red-hold.sh. Every dir is a mktemp -d, HOME is a throwaway; wm-build, r7-rw.sh, gh and seat-event are stubs that
# append their argv to files: no ssh, no real journal, no real gh, no real seat. The whole suite runs twice, once per profile (rb: default `wm-build decision open` cordon,
# inbox rb; r7: LRH_CORDON_CMD = an r7-rw.sh form, inbox r7, LRH_OWNER r7). Run: bash tests/land-red-hold.test.sh
# Mutation m1 (LRH_MUTATE=drop-tests-check, the tests-empty check dropped) re-runs the "named tests do nothing" case and the test exits non-zero unless that case FAILS under it.
set -u
here=$(cd "$(dirname "$0")" && pwd)
W="$here/../.local/bin/land-red-hold.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/land-red-hold-test.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
fail=0; n=0
ok() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS: $PROFILE $1"; else echo "FAIL: $PROFILE $1"; fail=$((fail+1)); fi; }

FUT=$(date -d '+30 days' -Is); PAST=$(date -d '-1 day' -Is)
ts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000000Z; }
SLUG=mcphost-table-import-url-live-proof
nenv=0
mkenv() {
  nenv=$((nenv+1)); R="$BASE/e$nenv"
  mkdir -p "$R/bin" "$R/home" "$R/state" "$R/wp"
  : > "$R/cordon.calls"; : > "$R/gh.calls"; : > "$R/posts"
  cat > "$R/bin/wm-build" <<'EOS'
#!/bin/bash
case "$*" in
  --version) echo "wm-build ${STUB_WMV:-0.9.9}"; exit 0;;
  "decision open"*) printf '%s\n' "$*" >> "$STUB_DIR/cordon.calls"; [ "${STUB_CORDON_RC:-0}" = 0 ] || { echo "boom: sqlite locked" >&2; exit "$STUB_CORDON_RC"; }; echo "opened decision d-0042"; exit 0;;
  "decision list"*) echo "d-0042 $STUB_SLUG x"; exit 0;;
esac
printf 'UNEXPECTED wm-build %s\n' "$*" >> "$STUB_DIR/cordon.calls"; exit 3
EOS
  cat > "$R/bin/r7-rw.sh" <<'EOS'
#!/bin/bash
printf 'r7 %s\n' "$*" >> "$STUB_DIR/cordon.calls"; [ "${STUB_CORDON_RC:-0}" = 0 ] || { echo "boom: r7 ssh 255" >&2; exit "$STUB_CORDON_RC"; }; echo "opened decision d-0042"
EOS
  cat > "$R/bin/gh" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.calls"
case "$*" in
  "pr list"*) cat "$STUB_DIR/pr.json";;
  "run list"*) cat "$STUB_DIR/runlist.json";;
  *"--log-failed"*) cat "$STUB_DIR/log.txt";;
  "run view"*"--json jobs"*) cat "$STUB_DIR/jobs.json";;
  *) exit 4;;
esac
EOS
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/posts"\n' "$R" > "$R/bell"
  chmod +x "$R/bin/"* "$R/bell"
  echo '[{"headRefName":"'"$SLUG"'","headRefOid":"abc123def4567890","updatedAt":"2026-10-25T00:00:00Z"}]' > "$R/pr.json"
  echo '[{"databaseId":77,"status":"in_progress","conclusion":null,"url":"https://gh/run/77"}]' > "$R/runlist.json"
  echo '{"jobs":[{"databaseId":701,"name":"sandbox suites (all shards)","conclusion":"failure"},{"databaseId":702,"name":"lint","conclusion":"success"}]}' > "$R/jobs.json"
  printf 'noise\ntest suite::alpha_case ... FAILED\n---- suite::beta_case stdout ----\ntest suite::alpha_case ... FAILED\n' > "$R/log.txt"
  J="$R/journal.jsonl"; echo '{"op":"filler","row":{},"table":"x","ts":"2026-10-01T00:00:00Z"}' > "$J"
}
run() { # [extra env...] -> stdout of one tick
  env -i HOME="$R/home" PATH="$R/bin:/usr/bin:/bin" TZ=UTC STUB_DIR="$R" STUB_SLUG="$SLUG" LRH_JOURNAL="$J" LRH_STATE_DIR="$R/state" WP_STATE="$R/wp" \
    LRH_EXPIRES="$FUT" LRH_SEAT_EVENT="$R/bell" LRH_WP_LIB="$here/../.local/lib/watcher-premise.sh" LRH_ENV_FILE="$R/none.env" WP_GATE_TTL=0 \
    "${PROFILE_ENV[@]}" "$@" bash "$W" 2>&1
}
nc() { grep -c '' "$R/cordon.calls" | tr -d ' '; }
np() { grep -c '' "$R/posts" | tr -d ' '; }
ab_row() { printf '{"op":"ci-red-classified","row":{"attempt":1,"check":"sandbox suites (all shards)","kind":"own","run_id":"%s","slug":"%s","tests":%s},"table":"land","ts":"%s"}\n' "$1" "$SLUG" "$2" "$3" >> "$J"; }
b_row() { printf '{"op":"readmit-from-land-failed","row":{"cause":"no PRD entry on record for slug %s","slug":"%s"%s},"table":"daemon","ts":"%s"}\n' "$SLUG" "$SLUG" "${2:+,\"run_id\":\"$2\"}" "$1" >> "$J"; }
c_row() { printf '{"op":"insert","row":{"id":%s,"slug":"%s","stage":"claimed"},"table":"runs","ts":"%s"}\n' "$1" "$SLUG" "$2" >> "$J"; }
prime() { run > /dev/null; }   # first tick: cursor at EOF

suite() {
  PROFILE=$1
  if [ "$PROFILE" = rb ]; then PROFILE_ENV=(LRH_OWNER=rb LRH_INBOX_SEAT=rb); else PROFILE_ENV=(LRH_OWNER=r7 LRH_INBOX_SEAT=r7 "LRH_CORDON_CMD=r7-rw.sh decision open \"\$2\" --slug \"\$1\""); fi
  local out cmd

  # 1. first run reads nothing old: an old trigger row in the fixture gives no action
  mkenv; ab_row 1058 '[]' "$(ts '-10 minutes')"; out=$(run)
  [ "$(nc)" = 0 ] && [ "$(np)" = 0 ] && echo "$out" | grep -q 'FIRST RUN'; ok "first run reads nothing old (calls $(nc), posts $(np))" $?
  # 2. a tests:[] row -> one cordon, then after a completed stub run one post naming the stubbed failed tests
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; out=$(run); c1=$(nc); p1=$(np)
  if [ "$PROFILE" = rb ]; then cmd="decision open"; else cmd="r7 decision open"; fi
  [ "$c1" = 1 ] && grep -qF -- "$cmd" "$R/cordon.calls" && grep -qF -- "--slug $SLUG" "$R/cordon.calls" && grep -qF 'RELEASE=close this decision after reading the posted CI failure names' "$R/cordon.calls" && [ "$p1" = 0 ]; ok "tests:[] row gives one cordon ($(head -c 90 "$R/cordon.calls")...), no post while CI runs" $?
  echo '[{"databaseId":77,"status":"completed","conclusion":"failure","url":"https://gh/run/77"}]' > "$R/runlist.json"; run > /dev/null; run > /dev/null
  [ "$(np)" = 1 ] && grep -q "$SLUG run 1058: CI completed failure; failed tests: suite::alpha_case suite::beta_case; cordon d-0042 stays until a seat decides" "$R/posts" && head -c 3 "$R/posts" | grep -q "^$([ "$PROFILE" = rb ] && echo rb || echo r7)"; ok "completed run gives ONE post naming the failed tests to seat $(head -c 3 "$R/posts" | tr -d ' '): $(cut -c1-130 "$R/posts")" $?
  [ "$(nc)" = 1 ] && ! grep -q 'pause\|close\|redrive\|unpause' "$R/cordon.calls"; ok "no pause/close/redrive/unpause call, cordons $(nc)" $?
  # 3. a row whose tests are named does nothing
  mkenv; prime; ab_row 1058 '["suite::alpha_case"]' "$(ts '-1 minutes')"; run > /dev/null
  [ "$(nc)" = 0 ] && [ "$(np)" = 0 ] && [ ! -s "$R/gh.calls" ]; ok "named tests do nothing (calls $(nc), posts $(np))" $?
  # 4. readmit-from-land-failed gives a cordon
  mkenv; prime; b_row "$(ts '-1 minutes')"; run > /dev/null
  [ "$(nc)" = 1 ]; ok "readmit-from-land-failed gives a cordon (calls $(nc))" $?
  # 5. a repeated row, and A then B for the same (slug, run), give no second cordon
  mkenv; prime; ab_row 1058 '[]' "$(ts '-2 minutes')"; run > /dev/null; ab_row 1058 '[]' "$(ts '-1 minutes')"; run > /dev/null; b_row "$(ts '-1 minutes')" 1058; run > /dev/null; run > /dev/null
  [ "$(nc)" = 1 ]; ok "repeated A row + B row for the same run give ONE cordon (calls $(nc))" $?
  # 6. partial trailing line waits for the next tick; a malformed line is skipped
  mkenv; prime; printf '%s\n' 'not json at all {{{' >> "$J"; ab_row 1058 '[]' "$(ts '-1 minutes')"; line=$(tail -n1 "$J"); head -n -1 "$J" > "$J.t"; mv "$J.t" "$J"
  printf '%s' "${line:0:60}" >> "$J"; run > /dev/null; c0=$(nc); printf '%s\n' "${line:60}" >> "$J"; run > /dev/null
  [ "$c0" = 0 ] && [ "$(nc)" = 1 ]; ok "partial line waits (calls $c0 -> $(nc)); malformed line skipped, no crash" $?
  # 7. rotation: a shrunk, replaced file resets the cursor to 0 and reads the new file
  mkenv; for i in 1 2 3 4 5 6 7 8; do echo '{"op":"filler","row":{"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},"table":"x","ts":"2026-10-01T00:00:00Z"}' >> "$J"; done
  prime; rm -f "$J"; ab_row 1058 '[]' "$(ts '-1 minutes')"; out=$(run)
  [ "$(nc)" = 1 ] && grep -q ROTATION "$R/state/land-red-hold.log"; ok "rotation (shrunk file) resets and reads the new file (calls $(nc))" $?
  # 8. an expired or false premise gives no write; one disarm post lists the open cordons
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; run > /dev/null; ab_row 1059 '[]' "$(ts '-1 minutes')"; out=$(run LRH_EXPIRES="$PAST"); out2=$(run LRH_EXPIRES="$PAST")
  [ "$(nc)" = 1 ] && echo "$out" | grep -q 'DISARMED expired' && [ "$(grep -c 'DISARMED' "$R/posts")" = 1 ] && grep -q "$SLUG/run1058=d-0042" "$R/posts"; ok "expired premise: no write, ONE disarm post naming open cordons ($(cut -c1-120 "$R/posts" | tail -n1))" $?
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; out=$(run LRH_PREMISE_CMD='exit 1')
  [ "$(nc)" = 0 ] && echo "$out" | grep -q DISARMED; ok "false premise: no write ($out)" $?
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; out=$(run LRH_FIXED_VERSION=0.9.9)
  [ "$(nc)" = 0 ] && echo "$out" | grep -q DISARMED; ok "F6 default premise: LRH_FIXED_VERSION matches wm-build --version -> disarmed ($out)" $?
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; out=$(run LRH_FIXED_VERSION=1.0.0)
  [ "$(nc)" = 1 ]; ok "F6 default premise: other version -> armed (calls $(nc))" $?
  # 9. F7: a row older than 2 h gets a post only, no cordon
  mkenv; prime; ab_row 1058 '[]' "$(ts '-3 hours')"; run > /dev/null
  [ "$(nc)" = 0 ] && [ "$(np)" = 1 ] && grep -q 'older than 2 h' "$R/posts"; ok "F7 stale row: post only (calls $(nc), posts $(np))" $?
  # 10. F8 trigger C: an admission inside 300 s gives one post, no pause, no second cordon; outside the window nothing
  mkenv; prime; ab_row 1058 '[]' "$(ts '-10 minutes')"; c_row 1061 "$(ts '-8 minutes')"; run > /dev/null; run > /dev/null
  [ "$(nc)" = 1 ] && [ "$(grep -c 'fresh run 1061 admitted 120 s after the red' "$R/posts")" = 1 ] && ! grep -q 'pause' "$R/cordon.calls"; ok "trigger C: one post, no pause call, no second cordon ($(grep 'fresh run' "$R/posts" | cut -c1-150))" $?
  c_row 1062 "$(ts '-1 minutes')"; run > /dev/null
  [ "$(grep -c 'fresh run' "$R/posts")" = 1 ] && [ "$(nc)" = 1 ]; ok "trigger C: an admission outside the 300 s window gives no post" $?
  # 11. cordon failure: <= 3 attempts, one post with the stderr tail
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; for i in 1 2 3 4 5; do run STUB_CORDON_RC=1 > /dev/null; done
  [ "$(nc)" = 3 ] && [ "$(grep -c 'cordon FAILED' "$R/posts")" = 1 ] && grep -q 'boom' "$R/posts"; ok "cordon failure: 3 attempts, ONE fail post with stderr (attempts $(nc))" $?
  # 12. CI still running after 90 min: one post, then the completion post later
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; run > /dev/null
  pf=$(ls "$R/state/pending/"*.tsv); awk -F'\t' -v OFS='\t' -v t=$(( $(date +%s) - 6000 )) '{$5=t; print}' "$pf" > "$pf.t" && mv "$pf.t" "$pf"; run > /dev/null; run > /dev/null
  [ "$(grep -c 'still running after 90 min' "$R/posts")" = 1 ]; ok "CI still running after 90 min: ONE post" $?
  # 13. aggregator-only red: no test names -> failed jobs listed
  mkenv; prime; ab_row 1058 '[]' "$(ts '-1 minutes')"; echo 'only noise' > "$R/log.txt"; echo '[{"databaseId":77,"status":"completed","conclusion":"failure","url":"https://gh/run/77"}]' > "$R/runlist.json"; run > /dev/null; run > /dev/null
  grep -q 'no test names; failed jobs: sandbox suites (all shards)' "$R/posts" && grep -q 'run list --repo j0yen/mcphost --commit abc123def4567890' "$R/gh.calls"; ok "aggregator-only: 'no test names; failed jobs' post, CI keyed on the PR head sha" $?
}

suite rb
suite r7

# --- on-host decision --help check inside --selftest (F5): LRH_SELFTEST_HELP_ONLY=1 skips the suite (no recursion), LRH_HELP_CMD stubs `wm-build decision --help`
mkenv; PROFILE=help
hc() { env -i HOME="$R/home" PATH="/usr/bin:/bin" LRH_SELFTEST_HELP_ONLY=1 LRH_HELP_CMD="$1" bash "$W" --selftest 2>&1; }
out=$(hc "printf 'P1: decision open <question> [--slug <s>]\\n\\nCommands:\\n  open   \\n  close  \\n'"); echo "$out" | grep -q '^PASS on-host'; ok "selftest help check passes on help with open + --slug ($out)" $?
out=$(hc "printf 'Commands:\\n  close  \\n  list\\n'"); echo "$out" | grep -q '^FAIL on-host'; ok "selftest help check FAILs when there is no open/--slug" $?

# --- m1 mutation: dropping the tests-empty check makes the "named tests do nothing" case FAIL
PROFILE=m1; PROFILE_ENV=(LRH_OWNER=rb LRH_INBOX_SEAT=rb)
mkenv; prime; ab_row 1058 '["suite::alpha_case"]' "$(ts '-1 minutes')"; run LRH_MUTATE=drop-tests-check > /dev/null
if [ "$(nc)" -gt 0 ]; then echo "PASS: m1 mutation drop-tests-check makes 'named tests do nothing' FAIL (cordon calls 0 -> $(nc))"; n=$((n+1)); else echo "FAIL: m1 mutation did not break the named-tests case"; fail=$((fail+1)); fi

if [ "$fail" = 0 ]; then echo "PASS land-red-hold n=$n (rb profile + r7 profile)"; exit 0; fi
echo "FAIL land-red-hold failures=$fail of $n"; exit 1
