#!/usr/bin/env bash
# tests/rb-etx-watch.test.sh: hermetic test of .local/bin/rb-etx-watch.sh. Every dir is a mktemp -d, HOME is a throwaway, ETX_SEAT_EVENT is a stub that
# appends its argv to a file: no ssh, no claude, no real seat-event, no real coders/verifier dir. Run: bash tests/rb-etx-watch.test.sh
# Cases etx2-g1..g6 cover the (path, ETX-line count) fire key. Cases a-k are the spec's (counted in the last line); x1-x3 are extra guards (in-flight, .out without report, vetx dir). The G9 mutation
# (ETX_MUTATE=seen-false) re-runs (c) and the test exits non-zero unless (c) FAILS under it.
set -u
here=$(cd "$(dirname "$0")" && pwd)
W="$here/../.local/bin/rb-etx-watch.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/rb-etx-watch-test.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
pass=0; fail=0; extra_fail=0
ok() { # name cond-result(0=ok)
  if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }

PAST=$(date -d '-1 day' -Is); FUT=$(date -d '+30 days' -Is)
nenv=0
mkenv() { # sets R (root) and the per-env dirs
  nenv=$((nenv+1)); R="$BASE/e$nenv"
  mkdir -p "$R/coders" "$R/verif" "$R/state" "$R/wp" "$R/home"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$R" > "$R/stub"; chmod +x "$R/stub"
  : > "$R/calls"
}
run() { # [extra env...] -> stdout of the watcher
  env -i HOME="$R/home" PATH="$PATH" TZ=UTC ETX_CODERS_DIR="$R/coders" ETX_VERIFIER_DIR="$R/verif" ETX_STATE="$R/state" ETX_SEAT_EVENT="$R/stub" \
    WP_STATE="$R/wp" ETX_EXPIRES="$FUT" ETX_PREMISE_DIR="$R/coders" ETX_WP_LIB="$here/../.local/lib/watcher-premise.sh" "$@" bash "$W" 2>&1
}
ncalls() { wc -l < "$R/calls" | tr -d ' '; }
hit() { # path [pac_a y|n]  -> a real red, old enough to not be in flight
  { echo "running 3 tests"
    if [ "${2:-y}" = y ]; then echo "thread 'pac_a_exit_code_passes_through' panicked at tests/pac_a_cargo_shim.rs:271:93:"
    else echo "thread 'other_test' panicked at tests/other.rs:9:1:"; fi
    echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }'; } > "$1"
  touch -d '-10 minutes' "$1"; }

# (a) empty state + one hit file -> seed, zero calls
mkenv; hit "$R/coders/v1.report.md"
out=$(run); [ "$out" = "ETX SEED n=1" ] && [ "$(ncalls)" = 0 ] && [ "$(cat "$R/state/fired")" = 1 ]; rc=$?; ok "a seed: '$out', 0 calls" $rc
# (b) a new hit after seeding -> exactly one call with the G10 line
hit "$R/coders/new.report.md" y; out=$(run)
[ "$(ncalls)" = 1 ] && [ "$(cat "$R/calls")" = "rb ETX TRIGGER n=2 new.report.md pac_a=y" ]; rc=$?; ok "b one call: '$(cat "$R/calls")'" $rc
# (c) same file rescanned unchanged -> zero new calls
run >/dev/null; [ "$(ncalls)" = 1 ]; rc=$?; ok "c rescan unchanged: calls still $(ncalls)" $rc
# (d) etx.report.md with the pattern -> zero
hit "$R/coders/etx.report.md" y; run >/dev/null; [ "$(ncalls)" = 1 ]; rc=$?; ok "d etx.report.md skipped: calls $(ncalls)" $rc
# (e) a non-matching new file -> zero
printf 'all green\ntest result: ok. 3 passed\n' > "$R/coders/clean.report.md"; touch -d '-10 minutes' "$R/coders/clean.report.md"; run >/dev/null
[ "$(ncalls)" = 1 ]; rc=$?; ok "e non-matching skipped: calls $(ncalls)" $rc
# (f) EXPIRES in the past -> ETX DISARMED, zero calls (a fresh hit is present)
hit "$R/coders/late.report.md" n; out=$(run ETX_EXPIRES="$PAST"); [ "$out" = "ETX DISARMED expired" ] && [ "$(ncalls)" = 1 ]; rc=$?; ok "f expired: '$out', calls $(ncalls)" $rc
# (g) etxfix.report.md with a real red -> zero; other.report.md quoting the pattern inside a fence (panicked elsewhere) -> zero
mkenv; run >/dev/null   # seeded, nothing
hit "$R/coders/etxfix.report.md" y
{ echo 'thread panicked at tests/x.rs:1:1: boom'; echo '```'; echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }'; echo '```'; echo '> ETXTBSY quoted'; echo '- ETXTBSY in a list'; echo '# ETXTBSY heading'; } > "$R/coders/other.report.md"
touch -d '-10 minutes' "$R/coders/other.report.md"; run >/dev/null; [ "$(ncalls)" = 0 ]; rc=$?; ok "g skip glob + fenced/quoted: calls $(ncalls)" $rc
# (h) a hit file that grows after firing -> zero
mkenv; run >/dev/null; hit "$R/coders/g.report.md" y; run >/dev/null; c1=$(ncalls)
echo 'more output after the red' >> "$R/coders/g.report.md"; run >/dev/null; [ "$c1" = 1 ] && [ "$(ncalls)" = 1 ]; rc=$?; ok "h grown file silent: calls $c1 -> $(ncalls)" $rc
# (i) delete seen, keep seeded, new hit -> fires
mkenv; run >/dev/null; rm -f "$R/state/seen"; hit "$R/coders/i.report.md" n; out=$(run)
[ -e "$R/state/seeded" ] && [ "$(ncalls)" = 1 ] && [ "$(cat "$R/calls")" = "rb ETX TRIGGER n=1 i.report.md pac_a=n" ]; rc=$?; ok "i seen gone, seeded kept: '$(cat "$R/calls")'" $rc
# (j) truncated last line of seen: complete keys above still suppress, the cut record is ignored
mkenv; hit "$R/coders/a.report.md" y; hit "$R/coders/b.report.md" y; run >/dev/null
head -c -6 "$R/state/seen" > "$R/state/seen.cut"; mv -f "$R/state/seen.cut" "$R/state/seen"
run >/dev/null; [ "$(ncalls)" = 1 ] && grep -q ' b.report.md ' "$R/calls"; rc=$?; ok "j truncated seen: calls $(ncalls) ($(tr '\n' '|' < "$R/calls"))" $rc
# (k) premise dir missing -> ETX DISARMED premise, zero calls, no seen write
mkenv; hit "$R/coders/k.report.md" y; out=$(run ETX_PREMISE_DIR="$R/nonexistent")
[ "$out" = "ETX DISARMED premise" ] && [ "$(ncalls)" = 0 ] && [ ! -e "$R/state/seen" ] && [ ! -e "$R/state/seeded" ]; rc=$?; ok "k premise gone: '$out', calls $(ncalls), no seen" $rc
n_ab=11

# extras: x1 run.out with no result.json / fresh result.json is in flight; x2 .out without .report.md; x3 vetx dir skipped; x4 old result.json fires
mkenv; run >/dev/null
mkdir -p "$R/verif/v1" "$R/verif/vetx9"; hit "$R/verif/v1/run.out" y; hit "$R/verif/vetx9/run.out" y; echo '{}' > "$R/verif/vetx9/result.json"; touch -d '-10 minutes' "$R/verif/vetx9/result.json"
hit "$R/coders/solo.out" y
run >/dev/null; [ "$(ncalls)" = 0 ]; rc=$?; ok "x1-x3 in-flight run.out, lone .out, vetx dir: calls $(ncalls)" $rc
echo '{}' > "$R/verif/v1/result.json"; run >/dev/null; [ "$(ncalls)" = 0 ]; rc=$?; ok "x1b fresh result.json still in flight: calls $(ncalls)" $rc
touch -d '-10 minutes' "$R/verif/v1/result.json"; run >/dev/null; [ "$(ncalls)" = 1 ] && grep -q ' run.out ' "$R/calls"; rc=$?; ok "x4 settled verifier run.out fires: '$(cat "$R/calls")'" $rc

# etx2 (ctl 6152 cond. 2): fire key = (path, count of real ETX lines). hit() writes ONE real ETX line.
mkenv; hit "$R/coders/h.report.md" y; run >/dev/null   # seed: hits=1
# (g1) the hit file grows by non-ETX lines -> no fire
printf 'more output\nanother line\n' >> "$R/coders/h.report.md"; run >/dev/null; [ "$(ncalls)" = 0 ]; rc=$?; ok "etx2-g1 non-ETX growth silent: calls $(ncalls)" $rc
# (g2) a new real ETX line is appended -> exactly one fire, n increments, bell text names the count change
echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }' >> "$R/coders/h.report.md"; run >/dev/null
[ "$(ncalls)" = 1 ] && [ "$(cat "$R/calls")" = "rb ETX TRIGGER n=2 h.report.md pac_a=y new ETX line 1->2" ] && [ "$(cat "$R/state/fired")" = 2 ]; rc=$?; ok "etx2-g2 new ETX line fires once, n 1->2: '$(cat "$R/calls")'" $rc
# (g3) a third pass with no change -> no fire
run >/dev/null; [ "$(ncalls)" = 1 ]; rc=$?; ok "etx2-g3 unchanged third pass: calls $(ncalls)" $rc
# (g4) an appended QUOTED ETX line -> no fire
echo '> ETXTBSY quoted again' >> "$R/coders/h.report.md"; run >/dev/null; [ "$(ncalls)" = 1 ]; rc=$?; ok "etx2-g4 quoted ETX line silent: calls $(ncalls)" $rc
# (g5) a legacy 4-field seen record for a hit file with TWO real ETX lines -> no fire (adopts count 2), record rewritten to 5 fields in the same pass (a legacy record of a
#   vanished path too: the seen file never mixes formats across passes)
mkenv; hit "$R/coders/l.report.md" y; echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }' >> "$R/coders/l.report.md"; run >/dev/null
read -r li ls lm < <(stat -c '%i %s %Y' "$R/coders/l.report.md")
{ printf '%s\t%s\t%s\t%s\n' "$R/coders/l.report.md" "$li" "$ls" "$lm"; printf '%s\t1\t5\t5\n' "$R/coders/gone.report.md"; } > "$R/state/seen"
run >/dev/null; nf=$(awk -F'\t' '{ print NF }' "$R/state/seen" | sort -u | tr '\n' ' ')
[ "$(ncalls)" = 0 ] && [ "$nf" = "5 " ] && awk -F'\t' -v p="$R/coders/l.report.md" '$1 == p && $5 == 2 { ok = 1 } END { exit !ok }' "$R/state/seen"; rc=$?; ok "etx2-g5 legacy record adopts hits=2, no fire, all rows 5 fields (NF: $nf): calls $(ncalls)" $rc
# (g6) the count drops 2->1 by an in-place rewrite that does not shrink the file (silent; the record is rewritten to 1), then one new real ETX line -> exactly one fire.
#   ACCEPTED GAP (E5): an in-place rewrite with an EQUAL count and non-decreasing size is silent; this watcher does not catch it.
mkenv; hit "$R/coders/r.report.md" y; echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }' >> "$R/coders/r.report.md"; run >/dev/null   # seed: hits=2
{ echo "running 3 tests"; echo "thread 'pac_a_exit_code_passes_through' panicked at tests/pac_a_cargo_shim.rs:271:93:"; echo 'a rewritten line with no pattern but long enough to not shrink the file, padding padding padding padding padding padding'
  echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }'; } > "$R/coders/r.report.md"
run >/dev/null; c1=$(ncalls)
echo 'Os { code: 26, kind: ExecutableFileBusy, message: "Text file busy" }' >> "$R/coders/r.report.md"; run >/dev/null
[ "$c1" = 0 ] && [ "$(ncalls)" = 1 ] && grep -q 'new ETX line 1->2' "$R/calls"; rc=$?; ok "etx2-g6 count 2->1 silent then one new line fires once: calls $c1 -> $(ncalls)" $rc

# --- G9 mutation: (c) under ETX_MUTATE=seen-false must FAIL; this test exits non-zero if it does not
mkenv; hit "$R/coders/m.report.md" y; run >/dev/null; hit "$R/coders/mnew.report.md" y; run >/dev/null; c1=$(ncalls)
run ETX_MUTATE=seen-false >/dev/null; c2=$(ncalls)
if [ "$c1" = 1 ] && [ "$c2" -gt "$c1" ]; then echo "PASS: G9 mutation seen-false makes (c) FAIL (calls $c1 -> $c2)"; else echo "FAIL: G9 mutation did not break (c) (calls $c1 -> $c2)"; fail=$((fail+1)); fi

if [ "$fail" = 0 ]; then echo "PASS rb-etx-watch n=$n_ab"; exit 0; fi
echo "FAIL rb-etx-watch failures=$fail"; exit 1
