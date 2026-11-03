#!/bin/bash
# wmb-verify-suite.sh --flags '<RUSTFLAGS>' <BASE-sha>: wm-build PR verify suite (ctl ruling d-20261101-024047-controller-ee0d).
# Run from the PR clone at HEAD. Head: RUSTFLAGS=<flags> cargo check --all-targets, then cargo test (both must pass).
# Base: check --all-targets (reported only). Clippy warning count on --lib --bins at BASE and HEAD,
# own target dir per side; "clippy delta=N" (N = new head warnings) is printed only when both sides compiled.
# Targets (A672, Joe 11-03 12:58 AM "Ryzen has an ssd"): every target dir of one invocation lives in one run dir
# under the target root, never under the PR clone on the root disk. Root = WMB_TARGET_ROOT, else <mnt>/cargo-target
# when <mnt> (WMB_TARGET_MNT, default /mnt/ssd) exists, which must then be a mounted filesystem (no fallback to the
# root disk), else the PR clone (hosts without that path). Before the first build the suite waits until the root has
# the measured size of the last run plus a floor free; the run dir is removed on exit, the measured size kept.
set -u
[ "${1:-}" = --flags ] || { echo "usage: $0 --flags '<RUSTFLAGS>' <BASE-sha>"; exit 64; }
flags=$2; base=${3:?base sha}
# slot = the host memory gate: redbaron /mnt/data/hand/cargo-slot.sh, ryzen7 wmb-slot-r7.sh (wraps r7-cargo-slot.sh -- cargo ...); WMB_SLOT overrides.
if [ -n "${WMB_SLOT:-}" ] && [ ! -x "$WMB_SLOT" ]; then echo "WMB_SLOT=$WMB_SLOT is not executable on $(hostname)"; exit 2; fi
slot=${WMB_SLOT:-/mnt/data/hand/cargo-slot.sh}
[ -x "$slot" ] || slot=$HOME/.local/bin/wmb-slot-r7.sh
[ -x "$slot" ] || { echo "no cargo slot gate on $(hostname) (WMB_SLOT unset, no cargo-slot.sh, no wmb-slot-r7.sh)"; exit 2; }
head=$(git rev-parse HEAD) || exit 2
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q origin "$base" || { echo "base $base not fetchable"; exit 2; }
base=$(git rev-parse "$base^{commit}")

# verdicts read exit codes, test names and warning text only, never backtrace line numbers: no debuginfo (A672 item 2)
export CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG:-0} CARGO_PROFILE_TEST_DEBUG=${CARGO_PROFILE_TEST_DEBUG:-0}
mnt=${WMB_TARGET_MNT:-/mnt/ssd}
if [ -n "${WMB_TARGET_ROOT:-}" ]; then troot=$WMB_TARGET_ROOT
elif [ -d "$mnt" ]; then
  # mounted = a different device from the root disk (WMB_ROOT_REF, default /)
  if [ "$(stat -c %d "$mnt")" = "$(stat -c %d "${WMB_ROOT_REF:-/}")" ]; then
    echo "TARGET-REFUSED $mnt is not mounted (same device as ${WMB_ROOT_REF:-/}); no fallback to the root disk"; exit 75
  fi
  troot=$mnt/cargo-target
else troot=$PWD; fi
mkdir -p "$troot" || { echo "TARGET-REFUSED cannot create $troot"; exit 75; }
avail_gb() { if [ -n "${WMB_FAKE_AVAIL_FILE:-}" ]; then tr -dc 0-9 < "$WMB_FAKE_AVAIL_FILE"; else df -BG --output=avail "$troot" | tail -n 1 | tr -dc 0-9; fi; }
sizef=$troot/.wmbvs-last-gb-debug$CARGO_PROFILE_DEV_DEBUG
est=$(tr -dc 0-9 < "$sizef" 2>/dev/null); est=${est:-${WMB_TARGET_EST_GB:-150}}
floor=${WMB_TARGET_FLOOR_GB:-50}; need=$((est + floor)); waited=0
# concurrent legs share the root (aide 1:09 AM amendment): each running leg holds a reservation of its estimate in
# <root>/.wmbvs-reserve/<pid>.gb; a leg starts only when free minus the live legs' reservations covers its own estimate
# plus the floor. A reservation whose pid is gone is dropped. Check and claim run under one flock.
resd=$troot/.wmbvs-reserve
{ mkdir -p "$resd" && exec 9>"$resd/.lock"; } || { echo "TARGET-REFUSED cannot create $resd"; exit 75; }
reserved_gb() { local s=0 f p v; for f in "$resd"/*.gb; do [ -f "$f" ] || continue; p=${f##*/}; p=${p%.gb}
  if kill -0 "$p" 2>/dev/null; then v=$(tr -dc 0-9 < "$f"); s=$((s + ${v:-0})); else rm -f -- "$f"; fi; done; echo "$s"; }
while flock 9 || { echo "TARGET-REFUSED flock $resd/.lock"; exit 75; }; a=$(avail_gb); r=$(reserved_gb); [ $(( ${a:-0} - r )) -lt "$need" ]; do
  flock -u 9
  [ "$waited" -ge "${WMB_TARGET_WAIT_S:-7200}" ] && { echo "TARGET-WAIT-TIMEOUT root=$troot free=${a}G reserved=${r}G need=${need}G after ${waited}s"; exit 75; }
  echo "target-wait root=$troot free=${a}G reserved=${r}G need=${need}G (estimate ${est}G + floor ${floor}G) waited=${waited}s"
  sleep "${WMB_TARGET_POLL_S:-60}"; waited=$((waited + ${WMB_TARGET_POLL_S:-60}))
done
echo "$est" > "$resd/$$.gb"; flock -u 9
run=$(mktemp -d -p "$troot" "wmbvs-${head:0:12}.XXXX") || { rm -f -- "$resd/$$.gb"; echo "TARGET-REFUSED mktemp in $troot"; exit 75; }
echo "targets=$run free=${a}G reserved=${r}G need=${need}G"
work=$(mktemp -d -p "${TMPDIR:-/tmp}" wmbvs.XXXX)
cleanup() {
  git worktree remove --force "$work/base" >/dev/null 2>&1; rm -rf -- "${work:?}"
  gb=$(du -s --block-size=1G "$run" 2>/dev/null | cut -f1); [ "${gb:-0}" -gt 0 ] && echo "$gb" > "$sizef"
  rm -rf -- "${run:?}"; rm -f -- "$resd/$$.gb"
}
trap cleanup EXIT
echo "head=$head base=$base"

RUSTFLAGS="$flags" CARGO_TARGET_DIR="$run/head" "$slot" check --all-targets; hrc=$?
echo "head RUSTFLAGS=$flags check --all-targets rc=$hrc"
[ $hrc -eq 0 ] || { echo "HEAD FAILED check --all-targets"; exit $hrc; }
RUSTFLAGS="$flags" CARGO_TARGET_DIR="$run/head" "$slot" test --no-fail-fast; trc=$?
echo "cargo test EXIT=$trc"
[ $trc -eq 0 ] || { echo "HEAD FAILED cargo test"; exit $trc; }

git worktree add -q --detach "$work/base" "$base" || { echo "base worktree failed"; exit 2; }
( cd "$work/base" && CARGO_TARGET_DIR="$run/base" "$slot" check --all-targets >"$work/base-all.log" 2>&1 ); brc=$?
if [ $brc -eq 0 ]; then echo "base check --all-targets rc=0"; else echo "base check --all-targets: base-could-not-compile rc=$brc"; tail -3 "$work/base-all.log"; fi

clip() { # dir target log -> prints count, returns cargo rc
  ( cd "$1" && CARGO_TARGET_DIR="$2" "$slot" clippy --lib --bins --message-format short >"$3" 2>&1 ); local rc=$?
  grep -c ': warning: ' "$3"; return $rc
}
hn=$(clip "$PWD" "$run/clip" "$work/clip-head.log"); hcr=$?
bn=$(clip "$work/base" "$run/base" "$work/clip-base.log"); bcr=$?
echo "clippy --lib --bins head rc=$hcr warnings=$hn"
echo "clippy --lib --bins base rc=$bcr warnings=$bn"
if [ $hcr -ne 0 ]; then echo "head clippy could-not-compile"; tail -5 "$work/clip-head.log"; exit 1; fi
if [ $bcr -ne 0 ]; then echo "base clippy could-not-compile; no delta printed"; tail -5 "$work/clip-base.log"; exit 1; fi
# delta = head warnings with no base counterpart (file + message, line:col stripped; multiset via sorted comm)
norm() { grep ': warning: ' "$1" | sed -E 's/^([^:]+):[0-9]+:[0-9]+: /\1: /' | sort; }
norm "$work/clip-head.log" > "$work/h.w"; norm "$work/clip-base.log" > "$work/b.w"
d=$(comm -23 "$work/h.w" "$work/b.w" | wc -l)
echo "clippy delta=$d"
[ "$d" -eq 0 ] || { echo "new warnings (head-only):"; comm -23 "$work/h.w" "$work/b.w" | head -20; exit 1; }
exit 0
