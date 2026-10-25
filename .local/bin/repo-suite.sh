#!/bin/bash
# repo-suite.sh - the hermetic repo suite runner (lifted from r7's ~/.cache/r7-seat/v84-suite.sh; the 10-24 falsifier proved it discriminates:
# a clean origin/main is green, an inverted analysis-page-gate.sh or fable-skill-spawn-gate.sh turns exactly its own test red).
#   repo-suite.sh TREE LABEL OUTDIR [KIND]   run every test of TREE serially; output in OUTDIR/LABEL/{summary.txt,reds.txt,reds-tails.txt,rc.txt,h/*}
#   repo-suite.sh --selftest                  fake tree: one green test, one red test, one slow test, the SKIP list, the wall cap
# KIND: dotfiles = tests/*.test.sh (a test's name is the file minus .test.sh) | plain = tests/*.sh minus *_lib.sh / *helpers.sh (vibecode-kit)
#       default: dotfiles when the tree has a tests/*.test.sh, else plain.
# Hermetic: bwrap with / read-only, a private /tmp, only TREE + OUTDIR writable, a throwaway HOME/XDG tree per test, and exit-99 stubs for
# systemctl systemd-run gh ssh wm-build wm-decide synthorg agorabus tmux (a stub that is called is a test that reached for the host).
# Budget: PERTEST seconds per test (300, measured: the slowest passing test is 125 s), WALLCAP seconds for the whole run (1200); a test
# past either is RED, never skipped. SKIPN = the four tests that need a live seat/tmux and cannot run in a sandbox (v84 list).
# Exit: 0 all green, 1 any red, 2 refused (no bwrap / bwrap unusable: a sandbox that cannot be built never certifies a tree).
# Inside the sandbox REPO_SUITE_RUNNING=1 is set; a nested bwrap is impossible there (no user namespaces), so a test of this script skips its bwrap half.
set -u
PERTEST=${PERTEST:-300}; WALLCAP=${WALLCAP:-1200}
SKIPN=${REPO_SUITE_SKIP-'aide-inbox
seat-time-stamp
aide-verifier-gate-nodrift
vibeloop-ctl-claim'}
FLAKY=ledgerday_ac8_selftest_suite_green
STUBS="systemctl systemd-run gh ssh wm-build wm-decide synthorg agorabus tmux"

list_tests() {  # $1=tree $2=kind -> one "name<TAB>relative-file" per line
  local tree=$1 kind=$2 f b
  for f in "$tree"/tests/*.sh; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$kind" in
      dotfiles) case "$b" in *.test.sh) printf '%s\t%s\n' "${b%.test.sh}" "tests/$b" ;; esac ;;
      *) case "$b" in *_lib.sh|*helpers.sh|*_helpers.sh) ;; *) printf '%s\t%s\n' "${b%.sh}" "tests/$b" ;; esac ;;
    esac
  done
}

run_suite() {  # TREE LABEL OUTDIR [KIND]
  local TREE OUT LABEL KIND
  TREE=$(readlink -f "$1") || return 2; LABEL=$2; OUT=$3/$LABEL; KIND=${4:-}
  [ -d "$TREE/tests" ] || { echo "no tests/ in $TREE: refusing"; return 2; }
  if [ -z "$KIND" ]; then
    if ls "$TREE"/tests/*.test.sh >/dev/null 2>&1; then KIND=dotfiles; else KIND=plain; fi
  fi
  command -v bwrap >/dev/null || { echo "no bwrap: refusing"; return 2; }
  rm -rf "$OUT"; mkdir -p "$OUT/shim" "$OUT/h"
  local c
  for c in $STUBS; do printf '#!/bin/sh\nexit 99\n' > "$OUT/shim/$c"; chmod +x "$OUT/shim/$c"; done
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$OUT" "$OUT" true 2>/dev/null || { echo "bwrap unusable: refusing"; return 2; }
  : > "$OUT/reds-tails.txt"
  one() {  # $1=name $2=file $3=attempt -> rc
    local n=$1 f=$2 h="$OUT/h/$1.$3"; mkdir -p "$h/home/.cache" "$h/home/.config" "$h/home/.local/state" "$h/tmp"
    ( cd "$TREE" && bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$OUT" "$OUT" --bind "$TREE" "$TREE" --chdir "$TREE" \
        env PATH="$OUT/shim:$PATH" HOME="$h/home" XDG_STATE_HOME="$h/home/.local/state" XDG_CONFIG_HOME="$h/home/.config" XDG_CACHE_HOME="$h/home/.cache" TMPDIR="$h/tmp" REPO_SUITE_RUNNING=1 \
        timeout -k 10 "$PERTEST" bash "$f" > "$h/out.log" 2>&1 < /dev/null ); echo $?; }
  body() {
    local st t n f a b s0 s1 d att pass=0 fail=0 slow=0 skipped=0
    st=$(date +%s)
    : > "$OUT/rc.txt"; : > "$OUT/reds.txt"
    echo "TREE $TREE sha=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || echo none) label=$LABEL kind=$KIND pertest=${PERTEST}s wallcap=${WALLCAP}s"
    while IFS=$'\t' read -r n f; do
      [ -n "$n" ] || continue
      if printf '%s\n' "$SKIPN" | grep -qxF "$n"; then skipped=$((skipped+1)); continue; fi
      if [ $(( $(date +%s) - st )) -gt "$WALLCAP" ]; then echo "WALLCAP hit before $n"; echo "$n capped" >> "$OUT/rc.txt"; fail=$((fail+1)); echo "$n capped(wall)" >> "$OUT/reds.txt"; continue; fi
      s0=$(date +%s); a=$(one "$n" "$f" 1); b=$a; att=1
      if [ "$a" != 0 ] && [ "$n" = "$FLAKY" ]; then b=$(one "$n" "$f" 2); att=2; echo "RERUN $n first=RC$a second=RC$b"; fi
      s1=$(date +%s); d=$((s1-s0)); [ $d -gt 60 ] && slow=$((slow+1))
      echo "T $n RC$b ${d}s"; echo "$n $b" >> "$OUT/rc.txt"
      if [ "$b" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "$n RC$b" >> "$OUT/reds.txt"; { echo "=== $n RC$b"; tail -n 15 "$OUT/h/$n.$att/out.log"; } >> "$OUT/reds-tails.txt"; fi
    done < <(list_tests "$TREE" "$KIND")
    echo "SUMMARY label=$LABEL pass=$pass fail=$fail skipped=$skipped slow>60s=$slow wall=$(( $(date +%s) - st ))s"
    [ "$fail" = 0 ]
  }
  body 2>&1 | tee "$OUT/summary.txt" | tail -n "${REPO_SUITE_TAIL:-5}"
  return "${PIPESTATUS[0]}"
}

selftest() {
  local pass=0 fail=0 rc out
  T=$(mktemp -d "${TMPDIR:-/tmp}/repo-suite-st.XXXXXX") || exit 2
  trap 'rm -rf "${T:-/nonexistent}"' EXIT
  ck() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }
  # list_tests: dotfiles vs plain naming, helpers and libs excluded
  mkdir -p "$T/lt/tests"; : > "$T/lt/tests/a.test.sh"; : > "$T/lt/tests/b_test_helpers.sh"; : > "$T/lt/tests/c.sh"; : > "$T/lt/tests/x_lib.sh"; : > "$T/lt/tests/y_helpers.sh"
  [ "$(list_tests "$T/lt" dotfiles | cut -f1 | tr '\n' ,)" = "a," ]; ck "list_tests dotfiles: only *.test.sh, name minus .test.sh" $?
  [ "$(list_tests "$T/lt" plain | cut -f1 | sort | tr '\n' ,)" = "a.test,c," ]; ck "list_tests plain: *.sh minus *_lib.sh / *helpers.sh" $?
  if [ -n "${REPO_SUITE_RUNNING:-}" ]; then
    echo "SKIP: bwrap half (running inside the repo-suite sandbox: no nested user namespaces)"
  elif ! bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp true 2>/dev/null; then
    echo "FAIL: bwrap is unusable here, so the runner cannot run at all"; fail=$((fail+1))
  else
    local tr=$T/tree; mkdir -p "$tr/tests"
    printf '#!/bin/bash\necho ok\n' > "$tr/tests/green.test.sh"
    printf '#!/bin/bash\necho boom; exit 3\n' > "$tr/tests/red.test.sh"
    printf '#!/bin/bash\ngh pr list >/dev/null 2>&1; [ $? = 99 ] || exit 7\necho "HOME=$HOME" ; [ "$HOME" != "$REAL_HOME" ] || exit 8; [ -n "${REPO_SUITE_RUNNING:-}" ] || exit 9\n' > "$tr/tests/hermetic.test.sh"
    printf '#!/bin/bash\nsleep 30\n' > "$tr/tests/slow.test.sh"
    printf '#!/bin/bash\nexit 1\n' > "$tr/tests/aide-inbox.test.sh"   # on the SKIP list: must not run
    git -C "$tr" init -q 2>/dev/null
    out=$(REAL_HOME=$HOME PERTEST=3 WALLCAP=600 REPO_SUITE_TAIL=50 run_suite "$tr" st "$T/out" 2>&1); rc=$?
    [ "$rc" = 1 ]; ck "red test + per-test timeout -> exit 1 ($rc)" $?
    grep -q '^T green RC0' <<<"$out"; ck "green test RC0" $?
    grep -q '^T red RC3' <<<"$out"; ck "red test RC3 reported" $?
    grep -q '^T slow RC124' <<<"$out"; ck "slow test killed at PERTEST (RC124), not skipped" $?
    grep -q '^T hermetic RC0' <<<"$out"; ck "gh stub exits 99, HOME is throwaway, REPO_SUITE_RUNNING set" $?
    ! grep -q '^T aide-inbox' <<<"$out"; ck "SKIP-list test did not run" $?
    grep -q 'pass=2 fail=2 skipped=1' <<<"$out"; ck "summary counts pass=2 fail=2 skipped=1" $?
    [ "$(sort "$T/out/st/reds.txt" | tr '\n' ,)" = "red RC3,slow RC124," ]; ck "reds.txt names exactly the red tests" $?
    # all green -> exit 0
    rm -f "$tr/tests/red.test.sh" "$tr/tests/slow.test.sh"
    out=$(REAL_HOME=$HOME PERTEST=3 WALLCAP=600 REPO_SUITE_TAIL=50 run_suite "$tr" st2 "$T/out" 2>&1); rc=$?
    [ "$rc" = 0 ]; ck "all green -> exit 0 ($rc)" $?
    # wall cap: the second test is capped (red) once the wall passes
    printf '#!/bin/bash\nsleep 2\n' > "$tr/tests/a_first.test.sh"
    out=$(REAL_HOME=$HOME PERTEST=5 WALLCAP=1 REPO_SUITE_TAIL=50 run_suite "$tr" st3 "$T/out" 2>&1); rc=$?
    [ "$rc" = 1 ] && grep -q 'WALLCAP hit before' <<<"$out"; ck "wall cap marks the remaining tests red ($rc)" $?
    # a tree with no tests/ is refused
    out=$(run_suite "$T/lt/tests" nt "$T/out" 2>&1); rc=$?
    [ "$rc" = 2 ]; ck "no tests/ dir -> exit 2" $?
  fi
  echo "repo-suite selftest: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  ""|-h|--help) sed -n '2,17p' "$0"; [ -n "${1:-}" ] && exit 0 || exit 64 ;;
esac
[ $# -ge 3 ] || { echo "usage: repo-suite.sh TREE LABEL OUTDIR [dotfiles|plain]" >&2; exit 64; }
run_suite "$@"
exit $?
