#!/bin/bash
# wmb-verify-suite.sh --flags '<RUSTFLAGS>' <BASE-sha>: wm-build PR verify suite (ctl ruling d-20261101-024047-controller-ee0d).
# Run from the PR clone at HEAD. Head: RUSTFLAGS=<flags> cargo check --all-targets, then cargo test (both must pass).
# Base: check --all-targets (reported only). Clippy warning count on --lib --bins at BASE and HEAD,
# own target dir per side; "clippy delta=N" (N = new head warnings) is printed only when both sides compiled.
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
work=$(mktemp -d -p "${TMPDIR:-/tmp}" wmbvs.XXXX)
trap 'git worktree remove --force "$work/base" >/dev/null 2>&1; rm -rf -- "${work:?}"' EXIT
echo "head=$head base=$base"

RUSTFLAGS="$flags" CARGO_TARGET_DIR="$PWD/target-head" "$slot" check --all-targets; hrc=$?
echo "head RUSTFLAGS=$flags check --all-targets rc=$hrc"
[ $hrc -eq 0 ] || { echo "HEAD FAILED check --all-targets"; exit $hrc; }
RUSTFLAGS="$flags" CARGO_TARGET_DIR="$PWD/target-head" "$slot" test --no-fail-fast; trc=$?
echo "cargo test EXIT=$trc"
[ $trc -eq 0 ] || { echo "HEAD FAILED cargo test"; exit $trc; }

git worktree add -q --detach "$work/base" "$base" || { echo "base worktree failed"; exit 2; }
( cd "$work/base" && CARGO_TARGET_DIR="$work/target-base" "$slot" check --all-targets >"$work/base-all.log" 2>&1 ); brc=$?
if [ $brc -eq 0 ]; then echo "base check --all-targets rc=0"; else echo "base check --all-targets: base-could-not-compile rc=$brc"; tail -3 "$work/base-all.log"; fi

clip() { # dir target log -> prints count, returns cargo rc
  ( cd "$1" && CARGO_TARGET_DIR="$2" "$slot" clippy --lib --bins --message-format short >"$3" 2>&1 ); local rc=$?
  grep -c ': warning: ' "$3"; return $rc
}
hn=$(clip "$PWD" "$PWD/target-clip" "$work/clip-head.log"); hcr=$?
bn=$(clip "$work/base" "$work/target-base" "$work/clip-base.log"); bcr=$?
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
