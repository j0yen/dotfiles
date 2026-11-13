#!/bin/bash
# cargo-slot.sh (rb 10-17 2:4x pm, controller ruling): product hand-coder cargo.
# usage: cargo-slot.sh <cargo args...>   (e.g. cargo-slot.sh test --test suite_core_07)
# 10-18 1:58 AM controller (third hard freeze 10-17 11:36 PM, compile set admitted by COUNT): ONE slot only
#   (/mnt/data/hand/cargo.lock, -j 4; the scope carries no Memory* property by policy (Joe #195, no discretionary worker caps); CAP_G is the MemGate admission count only), granted only while MemAvailable >= 12G + the admission count (12G) = 24G;
#   below that it waits in 30 s polls up to CARGO_SLOT_MEM_MAXWAIT s (default 3600), then REFUSES (exit 76) — never runs anyway.
#   Slot 2 (cargo2.lock) is retired until the .59 MG memory-admission gate ships.
# -j goes BEFORE a "--" separator (after it, args belong to the test binary)
# 10-17 8:07 PM controller: default target on the SSD (sdb /mnt/data is a spinning disk); an explicit CARGO_TARGET_DIR wins
# 10-17 8:2x PM controller: IO gate: the slot waits (30 s polls) while IO PSI some avg60 > 80, capped at CARGO_SLOT_IO_MAXWAIT s
#   (default 1800), then runs anyway with a warning (memory is the hard gate, IO the soft one).
#   Test hooks: CARGO_SLOT_DRYRUN=1 prints the decision and runs nothing; CARGO_SLOT_IO_FILE overrides /proc/pressure/io;
#   CARGO_SLOT_MEM_FILE overrides /proc/meminfo; CARGO_SLOT_POLL overrides the 30 s poll.
# 10-21 rb SPLIT (design: Fable APPLY-WITH-FIXES; PREMISE: a hand `cargo test` holds the ONE cargo.lock slot for compile AND for the
#   whole test run, and the run phase is mostly waiting/low-CPU while the next call queues behind a lock it does not need):
#   with SPLIT=1 and the cargo subcommand `test`, the call runs as two phases with the SAME args and env.
#     phase=compile: the exact existing path (floor/IO wait -> flock cargo.lock -> cargo-jobs acquire -> scope) running
#       `cargo test <args before the first cargo-level "--"> -j 4 --no-run` (test-runner args after "--" are dropped here).
#       rc != 0 -> exit with it, no run phase. cargo.lock is released the moment `flock <lock> <cmd>` returns: the lock fd lives only
#       in flock's child, so the run phase (started by this shell) cannot inherit it.
#     phase=run: floor/IO wait again -> a NEW acquire (same class, same CARGO_SLOT_ACQ_WAIT_MIN) -> the same scope + `-p CPUWeight=50`
#       running the FULL original args (runner args included, no --no-run). NO flock, NO priority-waiter handling. Exit = cargo's rc.
#       Acquire timeout/refusal before cargo starts (detected by a marker the wrapper touches only when cargo is about to exec)
#       logs `phase=run acquire-timeout` and exits 76 (the live acquire-timeout convention: 75 -> 76 = "REFUSED, caller retries";
#       never 101/1, so it cannot read as a test failure). Cargo's own rc 75 or any rc with the marker present passes through as is.
#       Output guard (output unchanged, stdout/stderr kept on their own fds; both go through a line filter, so cargo sees pipes
#       not a tty in this phase): WARN once on a Compiling/Checking line (a rebuild outside the lock = the compile phase missed
#       something), INFO once on a Doc-tests line (doctest compilation is rustdoc work that only exists in the run phase).
#   SPLIT=0, any other subcommand, or a call that already has --no-run / --doc = exactly the old single-phase path.
#   EXPIRES: 10-28 (re-grade with the first week of `phase=run` WARN counts and the hand-queue wait times).
#   REVERSE: set CARGO_SLOT_SPLIT_DEFAULT=0 below (or CARGO_SLOT_SPLIT=0 per call), or restore the cargo-slot.sh.bak-* made at install.
#   Test hooks added: CARGO_SLOT_HAND_DIR (lock/priority dir, default /mnt/data/hand), CARGO_SLOT_WMBUILD and CARGO_SLOT_CARGO
#   (binary paths), CARGO_SLOT_SELFTEST_CHILD=1 (skips the hourly reap). `--selftest` = reap cases + split cases (fake binaries,
#   temp lock, no real cargo/acquire); `--selftest-split` = split cases only.
CARGO_SLOT_SPLIT_DEFAULT=1
SPLIT=${CARGO_SLOT_SPLIT:-$CARGO_SLOT_SPLIT_DEFAULT}
# rb 10-23 12:4x AM HAND-YIELD (row in wm-decide, 1039 land starved: each freed 5 G hand slot was re-granted before the 12.5 G land fit):
#   while <hand dir>/HAND-YIELD holds "<expiry-epoch> <reason>" with expiry in the future, a NEW call refuses with exit 76 (callers sleep
#   60 and retry) so running hand cargo drains and the waiting daemon step gets the hole. Running calls and SPLIT run phases are untouched.
#   Skipped for --selftest* and CARGO_SLOT_SELFTEST_CHILD=1. Cleared by the rb-hand-yield-clear unit or at expiry. REVERSE: rm the flag.
# 10-30 ctl c671 LAUNCH LOG: one append-only tab-separated line per admission decision (admitted|refused|waited-then-admitted) and one `end` line
#   per phase, in ${CARGO_SLOT_LAUNCH_LOG:-/mnt/data/hand/cargo-slot-launch.log}, so the MemGate sum + MemAvailable at a launch never depend on a caller's stderr.
#   sum_g = NEED_G = admitted cap + floor (what wait_gates compares MemAvailable to). SPLIT: compile and run each write their own decision line
#   (phase=compile / phase=run) from the same process, so both carry the same pid=$$. Skipped over 50 MiB. `cargo-slot.sh --last [N]` prints the last N lines.
#   REVERSE: restore cargo-slot.sh.bak-20261030-launchlog.
lg_file() { printf '%s' "${CARGO_SLOT_LAUNCH_LOG:-/mnt/data/hand/cargo-slot-launch.log}"; }
lg_write() { # $1 = tab-separated fields after the timestamp; a log failure never changes the exit code or stops the run
  local f sz; f=$(lg_file); sz=$(stat -c %s "$f" 2>/dev/null)
  [ "${sz:-0}" -gt 52428800 ] && return 0
  { printf '%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" >> "$f"; } 2>/dev/null || :   # the ONLY `|| :` in this file: a failed log append must not fail the call
}
lg_decision() { # $1 = admitted|refused|waited-then-admitted, $2 = MemAvailable G, $3 = io60
  lg_write "$(printf '%s\tavail_g=%s\tsum_g=%s\tfloor_g=%s\tio60=%s\tclass=%s\tphase=%s\ttree=%s\tpid=%s' "$1" "$2" "$NEED_G" "$FLOOR_G" "${3:-na}" "$CLS" "${lphase:-na}" "${csl_tree:-na}" "$$")"
}
lg_end() { lg_write "$(printf 'end\trc=%s\tavail_g=%s\tpid=%s' "$1" "$(availg)" "$$")"; }
if [ "${1:-}" = --last ]; then
  _n=${2:-5}; case "$_n" in ''|*[!0-9]*) _n=5;; esac
  tail -n "$_n" "$(lg_file)" 2>/dev/null; exit 0
fi
case "${1:-}" in --selftest*) ;; *) if [ "${CARGO_SLOT_SELFTEST_CHILD:-0}" != 1 ]; then
  _yf=${CARGO_SLOT_HAND_DIR:-/mnt/data/hand}/HAND-YIELD
  if [ -f "$_yf" ] && read -r _ye _yr < "$_yf" && [ "${_ye:-0}" -gt "$(date +%s)" ] 2>/dev/null; then
    echo "[cargo-slot] HAND-YIELD until $(date -d @"$_ye" +%H:%M) ($_yr): exit 76, sleep 60 and retry" >&2; exit 76; fi; fi ;; esac
[ -n "${CARGO_TARGET_DIR:-}" ] || export CARGO_TARGET_DIR=${CARGO_SLOT_TARGETS_ROOT:-/mnt/data/hand-targets}/$(basename "$PWD") # CSL: root is the TARGETS_ROOT hook (default unchanged)
# CSL begin (rb 10-21 CSL: a cargo target dir belongs to exactly one tree; design d-20261021-100718-rb-8188, Fable 10:1x APPLY-WITH-EDITS, owner-inference amendment 10:18 AM)
# WHY: hand clones shared /mnt/data/hand-targets/wm-build-ghrf and -ghrv. Same crate + same version = colliding artifact hashes, cargo's
#   path-package fingerprint is mtime-based with dep-info paths RELATIVE to the package root (a .d file cannot name its tree), and the
#   SPLIT run phase holds no lock; so clone B's `cargo test` ran clone A's binary (RRQ coder saw a foreign 1323-test lib, its own has 1318).
#   wm-build has no CI, so these hand verdicts are the whole gate for merges and promotes.
# DESIGN: tree = realpath(git toplevel of the --manifest-path dir, else of $PWD; no git = the dir itself). Each target dir carries a
#   stamp `$D/.cargo-slot-tree` = its tree, claimed under ONE flock on $CARGO_SLOT_TARGETS_ROOT/.claim.lock (default /mnt/data/hand-targets;
#   the hold covers the stamp read+write only). Absent/empty D -> claim. D stamped == tree -> use. D stamped by another tree -> remap.
#   D UNSTAMPED and non-empty -> adopt+stamp iff basename(D) == basename(tree) and basename(D) is not wm-build-ghrf/-ghrv (the dedicated
#   per-clone targets created before this existed); else remap. Remap = canon `<TARGETS_ROOT>/<basename(tree)>-<sha1(tree)[:8]>`, the
#   same claim rules applied to canon ONCE; canon owned by another tree (or unstamped non-empty) = exit 2, never a second suffix.
#   --target-dir / --target-dir=... (before any `--`) or CARGO_BUILD_TARGET_DIR bypass the lock: exit 2. Nothing is ever deleted or moved.
#   Every call (single phase and both SPLIT phases) prints `[cargo-slot] tree=<t> target=<D> phase=<single|compile|run>` (+ remapped-from=<requested>);
#   the evidence rule keys on that line. CARGO_SLOT_DRYRUN=1 prints the same decision and writes nothing.
#   SPLIT same-tree race: single-phase and compile calls hold `flock -x $D/.phase.lock` for the whole cargo, the run phase holds
#   `flock -s $D/.phase.lock`, so a background `check` cannot rebuild a target while its own test run phase executes. The lock is taken
#   as a flock(1) command wrapper (OUTSIDE cargo.lock, so a waiter holds no global slot), never as a fd of this shell: this shell, the
#   other phase and the output guard filters hold no fd on it (selftest S16 proves it by scanning /proc/*/fd inside the fake cargo).
# PREMISE (documentation only): two clones of one repo build into one CARGO_TARGET_DIR under the same crate+version, and wm-build
#   hand verdicts are the only gate; if clones never share a target dir the stamp is inert (it only ever adds a remap or a refusal).
# NO EXPIRES: a correctness invariant (Fable 10-21), not a tunable.
# REVERSE: restore cargo-slot.sh.bak-1100 (the pre-CSL file made at install); stamps/.phase.lock files left in target dirs are inert.
# Test hook: CARGO_SLOT_TARGETS_ROOT (canon dir + .claim.lock root; the selftest points it at a temp dir). CARGO_SLOT_HANDTMP (default /mnt/data/hand-tmp): the TMPDIR-remap root; the selftest points it at its scratch root.
CSL_TR=${CARGO_SLOT_TARGETS_ROOT:-/mnt/data/hand-targets}
csl_main() { # skipped for --selftest*: a selftest must not claim (or create) anything under the real targets root
csl_bad=0; csl_mf=""; csl_prev=""
for csl_a in "$@"; do
  [ "$csl_a" = "--" ] && break
  [ "$csl_prev" = "--manifest-path" ] && csl_mf=$csl_a
  case "$csl_a" in --manifest-path=*) csl_mf=${csl_a#--manifest-path=};; --target-dir|--target-dir=*) csl_bad=1;; esac
  csl_prev=$csl_a
done
if [ "$csl_bad" = 1 ] || [ -n "${CARGO_BUILD_TARGET_DIR:-}" ]; then
  echo "[cargo-slot] refused: --target-dir/CARGO_BUILD_TARGET_DIR bypasses the tree lock; set CARGO_TARGET_DIR" >&2; exit 2
fi
csl_base=$PWD; [ -n "$csl_mf" ] && csl_base=$(dirname -- "$csl_mf")
csl_tree=$(git -C "$csl_base" rev-parse --show-toplevel 2>/dev/null) && csl_tree=$(realpath -- "$csl_tree" 2>/dev/null) \
  || csl_tree=$(realpath -- "$csl_base" 2>/dev/null || echo "$csl_base")
csl_canon=$CSL_TR/$(basename -- "$csl_tree")-$(printf %s "$csl_tree" | sha1sum | head -c 8)
csl_foreign=""; csl_remap=""; csl_req=$CARGO_TARGET_DIR
csl_stamp() { # $1 = dir; tmp file + mv; a no-op under DRYRUN
  [ "${CARGO_SLOT_DRYRUN:-0}" = 1 ] && return 0
  mkdir -p -- "$1" && printf '%s\n' "$csl_tree" > "$1/.cargo-slot-tree.tmp.$$" && mv -f -- "$1/.cargo-slot-tree.tmp.$$" "$1/.cargo-slot-tree"
}
csl_try() { # $1 = dir; 0 = ours (claimed/adopted/already stamped), 1 = not ours (csl_foreign = owner), 2 = cannot stamp
  local d=$1 o="" b
  if [ ! -e "$d" ] || { [ -d "$d" ] && [ -z "$(ls -A -- "$d" 2>/dev/null)" ]; }; then csl_stamp "$d" || return 2; return 0; fi
  [ -f "$d/.cargo-slot-tree" ] && o=$(head -n1 "$d/.cargo-slot-tree" 2>/dev/null)
  if [ -n "$o" ]; then [ "$o" = "$csl_tree" ] && return 0; csl_foreign=$o; return 1; fi
  b=$(basename -- "$d")
  if [ "$b" = "$(basename -- "$csl_tree")" ]; then
    case "$b" in wm-build-ghrf|wm-build-ghrv) ;; *) csl_stamp "$d" || return 2; return 0;; esac
  fi
  csl_foreign="<unstamped>"; return 1
}
csl_claim() { # runs under .claim.lock (fd 8); exits 2 on a refusal
  local r
  csl_try "$CARGO_TARGET_DIR"; r=$?
  [ "$r" = 2 ] && { echo "[cargo-slot] refused: cannot stamp target $CARGO_TARGET_DIR" >&2; exit 2; }
  [ "$r" = 0 ] && return 0
  if [ "$CARGO_TARGET_DIR" = "$csl_canon" ]; then echo "[cargo-slot] refused: canonical target $csl_canon owned by $csl_foreign" >&2; exit 2; fi
  csl_try "$csl_canon"; r=$?
  [ "$r" = 2 ] && { echo "[cargo-slot] refused: cannot stamp canonical target $csl_canon" >&2; exit 2; }
  [ "$r" = 1 ] && { echo "[cargo-slot] refused: canonical target $csl_canon owned by $csl_foreign" >&2; exit 2; }
  csl_remap=$CARGO_TARGET_DIR; export CARGO_TARGET_DIR=$csl_canon
}
if [ "${CARGO_SLOT_DRYRUN:-0}" = 1 ]; then csl_claim
else
  mkdir -p -- "$CSL_TR" && exec 8> "$CSL_TR/.claim.lock" || { echo "[cargo-slot] refused: cannot open $CSL_TR/.claim.lock" >&2; exit 2; }
  flock -x 8; csl_claim; exec 8>&-
fi
}
case "${1:-}" in --selftest|--selftest-split) ;; *) csl_main "$@";; esac
csl_line() { echo "[cargo-slot] tree=$csl_tree target=$CARGO_TARGET_DIR phase=$1${csl_remap:+ remapped-from=$csl_remap}" >&2; }
PL=$CARGO_TARGET_DIR/.phase.lock
# CSL end
# 10-20 5:5x PM rb (ACT lib 36+ min at 4 % CPU, its 17 test threads in jbd2_log_wait_commit): a throwaway TMPDIR on /mnt/data
#   (sda, spinning: 20x4k dsync 6889 ms vs 13-14 ms on sdb/nvme) puts every fixture sqlite fsync on the HDD journal. A TMPDIR
#   under /mnt/data is remapped to /mnt/data/hand-tmp/<target basename> (sdb, rot=0); HOME/XDG stay as given.
case "$(readlink -f "${TMPDIR:-/tmp}" 2>/dev/null)" in /mnt/data/*) export TMPDIR=${CARGO_SLOT_HANDTMP:-/mnt/data/hand-tmp}/$(basename "$CARGO_TARGET_DIR"); mkdir -p "$TMPDIR"; echo "[cargo-slot] TMPDIR remapped off the HDD: $TMPDIR" >&2;; esac
# 10-20 6:3x PM rb (RB /tmp tmpfs 7.6 G = RAM: 10 abandoned throwaway HOMEs each carried a 588 MB copied .rustup, because the
#   rustup proxy reads $HOME/.rustup): an unset RUSTUP_HOME defaults to the shared /home/jsy/.rustup (toolchains are read-only).
[ -n "${RUSTUP_HOME:-}" ] || export RUSTUP_HOME=/home/jsy/.rustup
# 10-20 6:0x PM rb (CTRL 5:52 + 5:58 PM CORRECT): reap /mnt/data/hand-tmp at depth 1 AND 2, at most once an hour, never under
#   CARGO_SLOT_DRYRUN. An entry goes only if: neither it nor its parent is a symlink, find -P never follows links, its realpath
#   is still under the root, nothing inside changed in 24 h, and no live process holds it or a path inside/above it (fd, cwd,
#   or TMPDIR/HOME/XDG_* in its environ, so a queued waiter's TMPDIR is held). `cargo-slot.sh --selftest` = scratch root only.
reap_hand_tmp() {
  local root=$1 rroot held e rp h keep
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  rroot=$(realpath -e -- "$root") || return 0
  held=$( { for l in /proc/[0-9]*/fd/* /proc/[0-9]*/cwd; do readlink "$l" 2>/dev/null; done
            for f in /proc/[0-9]*/environ; do tr '\0' '\n' 2>/dev/null < "$f" | sed -n -E 's/^(TMPDIR|HOME|XDG_STATE_HOME|XDG_CONFIG_HOME|XDG_CACHE_HOME|XDG_DATA_HOME)=//p'; done; } | grep -F "$rroot" | sort -u)
  while IFS= read -r -d '' e; do
    { [ -L "$e" ] || [ -L "$(dirname -- "$e")" ]; } && continue
    rp=$(realpath -e -- "$e" 2>/dev/null) || continue
    case "$rp" in "$rroot"/*) ;; *) continue;; esac
    [ -n "$(find -P "$e" -mmin -1440 -print -quit 2>/dev/null)" ] && continue
    keep=0
    while IFS= read -r h; do [ -n "$h" ] || continue
      case "$h/" in "$rp"/*) keep=1; break;; esac; case "$rp/" in "$h"/*) keep=1; break;; esac; done <<< "$held"
    [ "$keep" = 1 ] && continue
    rm -rf -- "$rp" && echo "[cargo-slot] reaped stale $rp" >&2
  done < <(find -P "$rroot" -mindepth 1 -maxdepth 2 ! -name .reap-stamp -print0 2>/dev/null)
}
reap_gate() { # $1 = root; once an hour unless CARGO_SLOT_REAP_FORCE=1; never under dry-run
  [ "${CARGO_SLOT_DRYRUN:-0}" = 1 ] && return 0
  [ "${CARGO_SLOT_SELFTEST_CHILD:-0}" = 1 ] && return 0
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  if [ "${CARGO_SLOT_REAP_FORCE:-0}" = 1 ] || [ -z "$(find "$1/.reap-stamp" -mmin -60 2>/dev/null)" ]; then touch "$1/.reap-stamp"; reap_hand_tmp "$1"; fi
}
split_selftest() { # fake wm-build/systemd-run/flock/cargo on a temp PATH, temp lock dir; never touches real locks or starts real cargo/acquire
  local T RF self; self=$(readlink -f "$0")
  T=$(mktemp -d /mnt/data/.slot-selftest-split.XXXX) || { echo "  FAIL setup mktemp"; sf=1; sfc="$sfc setup"; return; }
  export CARGO_SLOT_LAUNCH_LOG="$T/launch.default.log"   # never write the real launch log from a selftest; cases L* override per call
  RF=$(command -v flock); mkdir -p "$T/bin" "$T/tmp" "$T/ch/registry" "$T/wd" "$T/hand" "$T/targets"; git init -q "$T/wd" # CSL: wd is its own tree; targets = CARGO_SLOT_TARGETS_ROOT
  printf 'MemAvailable:   67108864 kB\n' > "$T/mem"; printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$T/io"
  printf '#!/bin/bash\necho "FLOCK $*" >> "$FAKE_LOG"\n[ "$1" = -s ] && sleep "${FAKE_S_DELAY:-0}"\nexec "$FAKE_REAL_FLOCK" "$@"\n' > "$T/bin/flock"
  printf '#!/bin/bash\necho "SR $*" >> "$FAKE_LOG"\nwhile [ $# -gt 0 ]; do case "$1" in -p) shift 2;; -*) shift;; *) break;; esac; done\nexec "$@"\n' > "$T/bin/systemd-run"
  cat > "$T/bin/wm-build" <<'FEOF'
#!/bin/bash
echo "ACQ $*" >> "$FAKE_LOG"
n=$(grep -c '^ACQ ' "$FAKE_LOG")
[ "${FAKE_ACQ_FAIL_N:-0}" = "$n" ] && exit 75
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
FEOF
  cat > "$T/bin/cargo" <<'FEOF'
#!/bin/bash
echo "CARGO $*" >> "$FAKE_LOG"
lk() { if "$FAKE_REAL_FLOCK" -n "$FAKE_LOCK" true; then echo free; else echo held; fi; }
holders() { local l p; for l in /proc/[0-9]*/fd/*; do [ "$(readlink "$l" 2>/dev/null)" = "$1" ] && { p=${l#/proc/}; echo "${p%%/*}"; }; done | sort -u; }
outside() { local p q c nf=0 o=""; for p in $(holders "$1"); do [ -r /proc/$p/status ] || continue; c=$(cat /proc/$p/comm 2>/dev/null); q=$p; while [ -n "$q" ] && [ "$q" != 1 ] && [ "$q" != "$$" ]; do q=$(awk '/^PPid/{print $2}' /proc/$q/status 2>/dev/null); done; [ "$q" = "$$" ] && continue; if [ "$c" = flock ]; then nf=$((nf + 1)); else o="$o$p:$c "; fi; done; echo "$o|$nf"; }  # holders that are neither the cargo's own subtree nor a flock(1) wrapper (flock forks and keeps its fd): "<leaks>|<n flock wrappers>"
fdchk() { [ -n "${FAKE_FDCHK:-}" ] && echo "FD $1 phase_lock_leaks_wrappers=[$(outside "$FAKE_FDCHK/.phase.lock")] claim_lock_leaks_wrappers=[$(outside "$FAKE_FDCHK_CL")] self_holds_phase=$(ls -l /proc/$$/fd | grep -cF "$FAKE_FDCHK/.phase.lock") self_holds_claim=$(ls -l /proc/$$/fd | grep -cF "$FAKE_FDCHK_CL")" >> "$FAKE_LOG"; }
case " $* " in *" --no-run "*) echo "C_LOCK $(lk)" >> "$FAKE_LOG"; echo "C_TS $(date +%s.%N)" >> "$FAKE_LOG"; fdchk compile
  [ -n "${FAKE_C_SLEEP:-}" ] && sleep "$FAKE_C_SLEEP"
  if [ -n "${FAKE_BG_HOLD:-}" ]; then # queue an exclusive holder on the phase lock (closing the inherited phase-lock fd so it does not hold the lock it waits for)
    ( for f in /proc/$BASHPID/fd/*; do [ "$(readlink "$f")" = "$FAKE_BG_HOLD" ] && eval "exec ${f##*/}>&-"; done
      "$FAKE_REAL_FLOCK" -x "$FAKE_BG_HOLD" bash -c 'date +%s.%N > "$0.start"; sleep 2; date +%s.%N > "$0.end"' "$FAKE_BG_OUT" ) > /dev/null 2>&1 &
    sleep 0.4
  fi
  exit "${FAKE_C_RC:-0}";; esac
echo "R_LOCK $(lk)" >> "$FAKE_LOG"; echo "R_TS $(date +%s.%N)" >> "$FAKE_LOG"; fdchk run
[ "${FAKE_R_COMPILE:-0}" = 1 ] && { echo "   Compiling foo v0.1.0 (/x)" >&2; echo "   Checking bar v0.1.0"; echo "   Compiling baz v0.1.0" >&2; }
[ "${FAKE_R_DOC:-0}" = 1 ] && { echo "   Doc-tests foo"; echo "   Doc-tests bar" >&2; }
echo "R_STDOUT_LINE"; echo "R_STDERR_LINE" >&2
exit "${FAKE_R_RC:-0}"
FEOF
  chmod +x "$T/bin/"*
  ok() { local c=$1 d=$2; shift 2; if "$@"; then echo "  ok   $c $d"; else echo "  FAIL $c $d"; sf=1; case " $sfc " in *" $c "*) ;; *) sfc="$sfc $c";; esac; fi; }
  cnt() { [ "$(grep -cE -- "$2" "$T/$1")" = "$3" ]; }               # file pattern n
  cl() { grep '^CARGO ' "$T/log" | sed -n "${1}p"; }                 # nth cargo argv line
  lhas() { cl "$1" | grep -qE -- "$2"; }
  lnot() { ! cl "$1" | grep -qE -- "$2"; }
  has() { grep -qE -- "$2" "$T/$1"; }
  nohas() { ! grep -qE -- "$2" "$T/$1"; }
  rcis() { [ "$(cat "$T/rc")" = "$1" ]; }
  tc() { # name [VAR=val ...] -- cargo-slot args ; leaves $T/{log,out,err,rc}
    shift; local ev=(); while [ "$1" != -- ]; do ev+=("$1"); shift; done; shift
    : > "$T/log"; ( cd "${TCWD:-$T/wd}" && env -u CARGO_SLOT_SPLIT -u CARGO_SLOT_DRYRUN -u CARGO_BUILD_TARGET_DIR CARGO_SLOT_TARGETS_ROOT="$T/targets" PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_LOCK="$T/hand/cargo.lock" FAKE_REAL_FLOCK="$RF" \
      CARGO_SLOT_SELFTEST_CHILD=1 CARGO_SLOT_HAND_DIR="$T/hand" CARGO_SLOT_WMBUILD="$T/bin/wm-build" CARGO_SLOT_CARGO="$T/bin/cargo" \
      CARGO_SLOT_MEM_FILE="$T/mem" CARGO_SLOT_IO_FILE="$T/io" CARGO_SLOT_CONFIG="$T/nocfg" CARGO_HOME="$T/ch" CARGO_TARGET_DIR="$T/target" TMPDIR="$T/tmp" "${ev[@]}" \
      bash "$self" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc" ); }
  echo "case (a) test --locked --tests: 2 acquires, --no-run only in compile, lock only around compile, CPUWeight only in run"
  tc a -- test --locked --tests; ok a "rc 0" rcis 0; ok a "2 acquires" cnt log '^ACQ ' 2; ok a "2 cargo calls" cnt log '^CARGO ' 2
  ok a "compile has --no-run" lhas 1 '--no-run'; ok a "run has no --no-run" lnot 2 '--no-run'
  ok a "one cargo.lock flock, around the --no-run call" cnt log '^FLOCK \S*cargo\.lock .*--no-run' 1; ok a "exactly one cargo.lock flock" cnt log '^FLOCK \S*cargo\.lock ' 1
  ok a "lock held during compile" has log '^C_LOCK held$'; ok a "lock FREE during run" has log '^R_LOCK free$'
  ok a "2 scopes" cnt log '^SR ' 2; ok a "CPUWeight=50 only on run scope" cnt log '^SR .*CPUWeight=50' 1
  ok a "acquires keep class/producer" cnt log '^ACQ .*--class land --producer cargo-slot .*--wait-minutes 60 --' 2
  ok a "phase logs" has err 'phase=compile'; ok a "phase=run log" has err 'phase=run \(lock released after compile [0-9]+s\)'
  ok a "no WARN" nohas err 'WARN phase-run'; ok a "run stdout intact" has out '^R_STDOUT_LINE$'; ok a "run stderr intact" has err '^R_STDERR_LINE$'
  echo "case (b) test -- foo --nocapture: runner args only in the run phase"
  tc b -- test -- foo --nocapture; ok b "rc 0" rcis 0; ok b "compile has no foo" lnot 1 'foo'; ok b "compile has no --nocapture" lnot 1 '--nocapture'
  ok b "compile has --no-run -j 4" lhas 1 '--no-run -j 4$'; ok b "run keeps -- foo --nocapture" lhas 2 '-- foo --nocapture$'; ok b "run has no --no-run" lnot 2 '--no-run'
  echo "case (c) check --all-targets: single phase"
  tc c -- check --all-targets; ok c "rc 0" rcis 0; ok c "1 acquire" cnt log '^ACQ ' 1; ok c "1 cargo" cnt log '^CARGO ' 1; ok c "no --no-run" nohas log '--no-run'
  ok c "no phase log" nohas err '^\[cargo-slot\] phase='; ok c "no CPUWeight" nohas log 'CPUWeight'; ok c "1 cargo.lock flock" cnt log '^FLOCK \S*cargo\.lock ' 1
  echo "case (d) CARGO_SLOT_SPLIT=0 with test: single phase"
  tc d CARGO_SLOT_SPLIT=0 -- test --locked -- foo; ok d "rc 0" rcis 0; ok d "1 acquire" cnt log '^ACQ ' 1; ok d "no --no-run" nohas log '--no-run'; ok d "args intact" lhas 1 'test --locked -j 4 -- foo$'; ok d "no phase log" nohas err '^\[cargo-slot\] phase='
  echo "case (e) compile fails 101: rc 101, no run acquire"
  tc e FAKE_C_RC=101 -- test; ok e "rc 101" rcis 101; ok e "1 acquire" cnt log '^ACQ ' 1; ok e "no phase=run" nohas err 'phase=run'; ok e "no run cargo" nohas log '^R_LOCK'
  echo "case (f) run-phase acquire refused: acquire-timeout + rc 76"
  tc f FAKE_ACQ_FAIL_N=2 -- test; ok f "rc 76" rcis 76; ok f "acquire-timeout log" has err 'phase=run acquire-timeout'; ok f "2 acquires" cnt log '^ACQ ' 2; ok f "run cargo never started" cnt log '^CARGO ' 1
  echo "case (g) run output with Compiling/Doc-tests: WARN once, INFO once, rc preserved, output intact"
  tc g FAKE_R_COMPILE=1 FAKE_R_DOC=1 FAKE_R_RC=101 -- test; ok g "rc 101 preserved" rcis 101; ok g "WARN exactly once" cnt err '^\[cargo-slot\] WARN phase-run rebuilt outside lock$' 1
  ok g "INFO exactly once" cnt err '^\[cargo-slot\] INFO phase-run doctest-compile$' 1; ok g "Compiling line passed through" has err '^   Compiling foo'; ok g "Checking line passed through" has out '^   Checking bar'; ok g "not mislabeled acquire-timeout" nohas err 'acquire-timeout'
  echo "case (h) --no-run / --doc / +toolchain / -j8"
  tc h1 -- test --no-run; ok h1 "--no-run call stays single phase" cnt log '^ACQ ' 1; tc h2 -- test --doc; ok h2 "--doc stays single phase" cnt log '^ACQ ' 1
  tc h3 -- +nightly test -j8 --lib; ok h3 "+nightly test splits" cnt log '^ACQ ' 2; ok h3 "-j8 dropped, -j 4 added" lhas 2 '^CARGO \+nightly test --lib -j 4$'
  echo "case (cslj) nextest takes --build-jobs, never -j"
  tc cs1 -- nextest archive --workspace --archive-file x.tar.zst; ok cs1 "rc 0" rcis 0; ok cs1 "archive has --build-jobs 4" lhas 1 '--build-jobs 4'; ok cs1 "archive has no -j" lnot 1 ' -j '
  tc cs2 -- nextest run --workspace; ok cs2 "rc 0" rcis 0; ok cs2 "run has --build-jobs 4" lhas 1 '--build-jobs 4'; ok cs2 "run has no -j 4" lnot 1 ' -j 4'
  echo "case (i) DRYRUN: both phases printed, nothing run"
  tc i CARGO_SLOT_DRYRUN=1 -- test; ok i "rc 0" rcis 0; ok i "no fake calls" cnt log '^(ACQ|CARGO|FLOCK|SR) ' 0; ok i "2 DRY lines" cnt err 'DRY would run' 2; ok i "no acquire-timeout" nohas err 'acquire-timeout'
  echo "case (j) mcphost clone: class hand (cap 9); a --release build stays class land"
  mkdir -p "$T/mcphost-j"; git init -q "$T/mcphost-j"
  TCWD="$T/mcphost-j" tc j -- check; ok j "rc 0" rcis 0; ok j "acquires class hand" cnt log '^ACQ .*--class hand ' 1; ok j "no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='
  TCWD="$T/mcphost-j" tc j2 -- build --release; ok j2 "release acquires class land" cnt log '^ACQ .*--class land ' 1
  tc j3 -- check; ok j3 "other repo stays class land" cnt log '^ACQ .*--class land ' 1
  echo "case (k) wm-build clone: class hand priced by --prefix wm-build ([cargo_jobs.mem_caps_gb.wm-build] first); --release drops the prefix"
  mkdir -p "$T/wm-build-k"; git init -q "$T/wm-build-k"
  printf '[cargo_jobs.mem_caps_gb.wm-build]\nhand = 5  # c\n\n[cargo_jobs.mem_caps_gb]\nhand = 9\nland = 12.5\n' > "$T/cfgk"  # prefix table FIRST: a last-table-wins read would give 9
  TCWD="$T/wm-build-k" tc k CARGO_SLOT_CONFIG="$T/cfgk" -- check; ok k "rc 0" rcis 0; ok k "acquires class hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1; ok k "no Memory* on the scope; prefix table count unchanged" nohas log '^SR .*Memory(High|Max)='
  TCWD="$T/wm-build-k" tc k2 -- check; ok k2 "no config: no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='; ok k2 "still --prefix wm-build" cnt log '^ACQ .*--prefix wm-build ' 1
  TCWD="$T/wm-build-k" tc k3 CARGO_SLOT_CONFIG="$T/cfgk" -- build --release; ok k3 "release: class land, no prefix" cnt log '^ACQ .*--class land --producer' 1; ok k3 "release: no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='
  TCWD="$T/mcphost-j" tc k4 CARGO_SLOT_CONFIG="$T/cfgk" -- check; ok k4 "mcphost: no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='; ok k4 "mcphost passes no --prefix" nohas log '--prefix'
  printf '[cargo_jobs.mem_caps_gb.wm-build]\nhand = 7\n\n[cargo_jobs.mem_caps_gb]\nhand = 9\nland = 12.5\n' > "$T/cfgk5"; TCWD="$T/wm-build-k" tc k5 CARGO_SLOT_CONFIG="$T/cfgk5" -- check; ok k5 "prefix table 7 overrides literal 5: admission count line" has err '^\[cargo-slot\] admission count 5G -> 7G = floor\(prefix wm-build class hand cap\)$'; ok k5 "no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='; ok k5 "acquires class hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1
  echo "case (w4) class by WHAT THE TREE IS (origin remote), not its dir name; no origin -> Cargo.toml name -> basename arm"
  mkcl() { mkdir -p "$1"; git init -q "$1"; [ -z "${2:-}" ] || git -C "$1" remote add origin "$2"; }
  mkcl "$T/qfix" https://github.com/j0yen/wm-build
  TCWD="$T/qfix" tc w1 -- check; ok w1 "rc 0" rcis 0; ok w1 "dir qfix + origin j0yen/wm-build: class hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1; ok w1 "no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='; ok w1 "class line via=remote" has err '^\[cargo-slot\] class=hand prefix=wm-build via=remote kind=wm-build$'
  mkcl "$T/x" https://github.com/j0yen/mcphost.git
  TCWD="$T/x" tc w2 -- check; ok w2 "dir x + origin j0yen/mcphost.git: class hand, no Memory*" nohas log '^SR .*Memory(High|Max)='; ok w2 "class hand, no --prefix" cnt log '^ACQ .*--class hand --producer' 1
  mkcl "$T/y" https://github.com/j0yen/other-repo
  TCWD="$T/y" tc w3 -- check; ok w3 "unrelated origin: class land" cnt log '^ACQ .*--class land --producer' 1; ok w3 "unrelated origin, no Cargo.toml, dir y: land via=basename" has err 'class=land via=basename$'
  mkcl "$T/wm-build-z" https://github.com/j0yen/some-fork
  TCWD="$T/wm-build-z" tc w3b -- check; ok w3b "dir wm-build-z + unrelated origin + no Cargo.toml: falls through to the basename arm -> hand" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1
  mkcl "$T/nm1" https://github.com/j0yen/wm-build-extras; TCWD="$T/nm1" tc w3c -- check; ok w3c "origin .../wm-build-extras is not wm-build: land" cnt log '^ACQ .*--class land --producer' 1
  mkcl "$T/nm2" https://github.com/j0yen/not-wm-build; TCWD="$T/nm2" tc w3d -- check; ok w3d "origin .../not-wm-build is not wm-build: land" cnt log '^ACQ .*--class land --producer' 1
  mkcl "$T/lp" /home/jsy/wintermute/wm-build
  TCWD="$T/lp" tc w4 -- check; ok w4 "local-path origin /home/jsy/wintermute/wm-build: hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1
  mkcl "$T/ssh1" git@github.com:j0yen/WM-Build.git; TCWD="$T/ssh1" tc w4b -- check; ok w4b "scp-style ssh origin, mixed case: hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1
  mkcl "$T/ssh2" ssh://git@github.com/j0yen/mcphost/; TCWD="$T/ssh2" tc w4c -- check; ok w4c "ssh:// origin with a trailing slash: mcphost -> hand, no Memory*" nohas log '^SR .*Memory(High|Max)='
  mkcl "$T/qrel" https://github.com/j0yen/wm-build; TCWD="$T/qrel" tc w5 -- build --release; ok w5 "--release on a remote-matched wm-build clone: class land, no prefix" cnt log '^ACQ .*--class land --producer' 1; ok w5 "release: no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='
  mkcl "$T/lq" /mnt/data/hand/wm-build-qfix-base; printf '[package]\nname = "wm-build"\n' > "$T/lq/Cargo.toml"
  TCWD="$T/lq" tc n1 -- check; ok n1 "origin /mnt/data/hand/wm-build-qfix-base (a local clone of a clone) + Cargo.toml wm-build: hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1; ok n1 "no Memory* on the scope" nohas log '^SR .*Memory(High|Max)='; ok n1 "via=cargo-toml" has err 'class=hand prefix=wm-build via=cargo-toml kind=wm-build$'
  mkcl "$T/x2" https://github.com/j0yen/other-repo; printf '[package]\nname = "other"\n' > "$T/x2/Cargo.toml"
  TCWD="$T/x2" tc n2 -- check; ok n2 "unrelated GitHub origin + Cargo.toml other + basename x2: land" cnt log '^ACQ .*--class land --producer' 1; ok n2 "via=basename, no kind" has err 'class=land via=basename$'
  mkcl "$T/y2" https://github.com/j0yen/other-repo; printf '[package]\nname = "mcphost"\n' > "$T/y2/Cargo.toml"
  TCWD="$T/y2" tc n3 -- check; ok n3 "unrelated origin + Cargo.toml mcphost: hand, no Memory*" nohas log '^SR .*Memory(High|Max)='
  mkcl "$T/x3" https://github.com/j0yen/wm-build; printf '[package]\nname = "other"\n' > "$T/x3/Cargo.toml"
  TCWD="$T/x3" tc n4 -- check; ok n4 "a matching origin still wins over Cargo.toml (origin wm-build, name other): hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1
  mkcl "$T/tmp.XyZ"; printf '[package]\nname = "wm-build"\nversion = "0.1.0"\n' > "$T/tmp.XyZ/Cargo.toml"
  TCWD="$T/tmp.XyZ" tc w6 -- check; ok w6 "no remote, Cargo.toml package wm-build under dir tmp.XyZ: hand --prefix wm-build" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1; ok w6 "via=cargo-toml" has err 'via=cargo-toml kind=wm-build$'
  mkcl "$T/tmp.Mh1"; printf '[workspace]\nmembers = []\n\n[package]\nname = "mcphost"\n' > "$T/tmp.Mh1/Cargo.toml"
  TCWD="$T/tmp.Mh1" tc w6b -- check; ok w6b "no remote, Cargo.toml package mcphost: hand, no Memory*" nohas log '^SR .*Memory(High|Max)='
  mkcl "$T/tmp.Ws1"; printf '[workspace]\nmembers = []\n\n[[bin]]\nname = "wm-build"\n' > "$T/tmp.Ws1/Cargo.toml"
  TCWD="$T/tmp.Ws1" tc w6c -- check; ok w6c "no remote, Cargo.toml without [package] (a [[bin]] named wm-build is not the package): land" cnt log '^ACQ .*--class land --producer' 1
  mkcl "$T/wm-build-nr"; printf '[package]\nname = "other"\n' > "$T/wm-build-nr/Cargo.toml"
  TCWD="$T/wm-build-nr" tc w7 -- check; ok w7 "no remote, Cargo.toml names another package, dir wm-build-nr: basename arm -> hand" cnt log '^ACQ .*--class hand --prefix wm-build --producer' 1; ok w7 "via=basename" has err 'via=basename kind=wm-build$'

  echo "CSL cases: a cargo target dir belongs to exactly one tree (S4/S5/S5b are the unstamped-target rule)"
  local R1 R2 R3 tg ca lnrx tr1 tr2 tr3 cn st
  csl_repo() { mkdir -p "$1"; git init -q "$1"; }
  stampof() { head -n1 "$1/.cargo-slot-tree" 2>/dev/null; }
  canonof() { echo "$T/targets/$(basename "$1")-$(printf %s "$1" | sha1sum | head -c 8)"; }
  tgt() { sed -n 's/^\[cargo-slot\] tree=.* target=\([^ ]*\) phase=.*/\1/p' "$T/err" | head -1; }
  csl_repo "$T/t1"; csl_repo "$T/t2"; tr1=$(realpath "$T/t1"); tr2=$(realpath "$T/t2")
  TCWD=$T/t1; tc s1 CARGO_TARGET_DIR="$T/d1" -- check
  ok S1 "claim an empty (absent) dir: rc 0, stamp == tree" rcis 0; ok S1 "stamp == tree1" test "$(stampof "$T/d1")" = "$tr1"; ok S1 "line names tree+target+phase=single" has err "^\[cargo-slot\] tree=$tr1 target=$T/d1 phase=single\$"
  tc s2 CARGO_TARGET_DIR="$T/d1" -- check
  ok S2 "same tree again: same D" test "$(tgt)" = "$T/d1"; ok S2 "no remap on the line" nohas err 'remapped-from'; ok S2 "stamp unchanged" test "$(stampof "$T/d1")" = "$tr1"
  TCWD=$T/t2; tc s3 CARGO_TARGET_DIR="$T/d1" -- check
  cn=$(canonof "$tr2")
  ok S3 "other tree, same requested D: remapped to canon" test "$(tgt)" = "$cn"; ok S3 "canon stamp == tree2" test "$(stampof "$cn")" = "$tr2"; ok S3 "remapped-from=requested" has err "phase=single remapped-from=$T/d1\$"
  ok S3 "original D keeps tree1" test "$(stampof "$T/d1")" = "$tr1"; ok S3 "rc 0" rcis 0
  tc s3b CARGO_TARGET_DIR="$T/d1" -- check; ok S3b "second call from tree2: canon reused (stamp == tree2), still remapped" test "$(tgt)" = "$cn"
  mkdir -p "$T/dd/X" "$T/x13"; csl_repo "$T/x13/X"; touch "$T/dd/X/old-artifact"; tr3=$(realpath "$T/x13/X")
  TCWD=$T/x13/X; tc s4 CARGO_TARGET_DIR="$T/dd/X" -- check
  ok S4 "unstamped non-empty X from tree /X: adopted" test "$(tgt)" = "$T/dd/X"; ok S4 "stamp written" test "$(stampof "$T/dd/X")" = "$tr3"; ok S4 "no remap" nohas err 'remapped-from'; ok S4 "warm artifact untouched" test -e "$T/dd/X/old-artifact"
  mkdir -p "$T/dd/wm-build-ghrf" "$T/y"; csl_repo "$T/y/wm-build-ghrf"; touch "$T/dd/wm-build-ghrf/old-artifact"; tr3=$(realpath "$T/y/wm-build-ghrf")
  TCWD=$T/y/wm-build-ghrf; tc s5 CARGO_TARGET_DIR="$T/dd/wm-build-ghrf" -- check
  ok S5 "unstamped wm-build-ghrf from tree /wm-build-ghrf: remapped" test "$(tgt)" = "$(canonof "$tr3")"; ok S5 "ghrf never stamped" test ! -e "$T/dd/wm-build-ghrf/.cargo-slot-tree"; ok S5 "remapped-from=ghrf" has err "remapped-from=$T/dd/wm-build-ghrf\$"
  mkdir -p "$T/dd/Y" "$T/z"; csl_repo "$T/z/Z"; touch "$T/dd/Y/old-artifact"; tr3=$(realpath "$T/z/Z"); tr3_z=$tr3
  TCWD=$T/z/Z; tc s5b CARGO_TARGET_DIR="$T/dd/Y" -- check
  ok S5b "unstamped Y from tree /Z: remapped" test "$(tgt)" = "$(canonof "$tr3")"; ok S5b "Y left unstamped" test ! -e "$T/dd/Y/.cargo-slot-tree"; ok S5b "canon stamped Z" test "$(stampof "$(canonof "$tr3")")" = "$tr3"
  mkdir -p "$T/dd/wm-build-ghrv" "$T/y2"; csl_repo "$T/y2/wm-build-ghrv"; touch "$T/dd/wm-build-ghrv/old-artifact"; tr3=$(realpath "$T/y2/wm-build-ghrv")
  TCWD=$T/y2/wm-build-ghrv; tc s5v CARGO_TARGET_DIR="$T/dd/wm-build-ghrv" -- check
  ok S5 "unstamped wm-build-ghrv from tree /wm-build-ghrv: remapped, never stamped" test "$(tgt)" = "$(canonof "$tr3")" -a ! -e "$T/dd/wm-build-ghrv/.cargo-slot-tree"
  # S5b, CARGO_TARGET_DIR UNSET: the per-basename default <TARGETS_ROOT>/<basename PWD> (PWD = Y, a subdir of tree Z) is unstamped+non-empty: remap, no adoption
  mkdir -p "$T/targets/Y" "$T/z/Z/Y"; touch "$T/targets/Y/old-artifact"
  TCWD=$T/z/Z/Y; tc s5u CARGO_TARGET_DIR= -- check
  ok S5b "UNSET target, default <root>/Y unstamped, tree Z: remapped to canon(Z)" test "$(tgt)" = "$(canonof "$tr3_z")" -a ! -e "$T/targets/Y/.cargo-slot-tree"
  ok S5b "UNSET: remapped-from= the default" has err "remapped-from=$T/targets/Y\$"
  mkdir -p "$T/targets/X5" "$T/x5"; csl_repo "$T/x5/X5"; touch "$T/targets/X5/old-artifact"
  TCWD=$T/x5/X5; tc s5w CARGO_TARGET_DIR= -- check
  ok S4 "UNSET target, default <root>/X5 unstamped, tree /X5: adopted (the unset state does not change the rule)" test "$(tgt)" = "$T/targets/X5" -a "$(stampof "$T/targets/X5")" = "$(realpath "$T/x5/X5")"
  TCWD=$T/wd
  csl_repo "$T/t6"; tr3=$(realpath "$T/t6"); cn=$(canonof "$tr3"); mkdir -p "$cn"; echo /elsewhere/tree > "$cn/.cargo-slot-tree"
  TCWD=$T/t6; tc s6 CARGO_TARGET_DIR="$T/d1" -- check
  ok S6 "canon foreign-stamped: exit 2" rcis 2; ok S6 "names the owner" has err "refused: canonical target $cn owned by /elsewhere/tree"; ok S6 "cargo never ran" nohas log '^CARGO '
  tc s6b CARGO_TARGET_DIR="$cn" -- check; ok S6 "requesting the foreign canon directly: exit 2" rcis 2
  TCWD=$T/wd
  tc s7a -- check --target-dir "$T/x"; ok S7 "--target-dir x: exit 2" rcis 2; ok S7 "refusal text" has err 'refused: --target-dir/CARGO_BUILD_TARGET_DIR bypasses the tree lock; set CARGO_TARGET_DIR'; ok S7 "cargo never ran" nohas log '^CARGO '
  tc s7b -- check "--target-dir=$T/x"; ok S7 "--target-dir=x: exit 2" rcis 2
  tc s7c CARGO_BUILD_TARGET_DIR="$T/x" -- check; ok S7 "CARGO_BUILD_TARGET_DIR: exit 2" rcis 2
  tc s7d -- test -- --target-dir foo; ok S7 "--target-dir after '--' belongs to the test binary: allowed" rcis 0
  TCWD=$T/t1; tc s8 CARGO_TARGET_DIR="$T/d8" -- check --manifest-path "$T/t2/Cargo.toml"
  ok S8 "--manifest-path other repo: tree = the other repo" has err "^\[cargo-slot\] tree=$tr2 target=$T/d8 phase=single\$"; ok S8 "stamp == other repo" test "$(stampof "$T/d8")" = "$tr2"
  tc s8b CARGO_TARGET_DIR="$T/d8b" -- check "--manifest-path=$T/t2/Cargo.toml"; ok S8 "--manifest-path=… form" has err "^\[cargo-slot\] tree=$tr2 target=$T/d8b "
  TCWD=$T/wd
  csl_repo "$T/t9"; tr3=$(realpath "$T/t9"); cn=$(canonof "$tr3"); mkdir -p "$T/d9"; echo /elsewhere/tree > "$T/d9/.cargo-slot-tree"
  st=$(mktemp -d /mnt/data/.csl-selftest-tmp.XXXX)
  TCWD=$T/t9; tc s9 CARGO_TARGET_DIR="$T/d9" TMPDIR="$st" CARGO_SLOT_HANDTMP="$T/handtmp" -- check
  ok S9 "remapped to canon" test "$(tgt)" = "$cn"; ok S9 "TMPDIR remap uses the FINAL D basename" has err "TMPDIR remapped off the HDD: $T/handtmp/$(basename "$cn")\$"; ok S9 "hermetic: the real /mnt/data/hand-tmp got no dir" test ! -e "/mnt/data/hand-tmp/$(basename "$cn")"
  rm -rf -- "$st"; TCWD=$T/wd
  tc s10a -- test; ok S10 "compile phase line" has err "^\[cargo-slot\] tree=.* target=$T/target phase=compile\$"; ok S10 "run phase line" has err "^\[cargo-slot\] tree=.* target=$T/target phase=run\$"
  tc s10b CARGO_TARGET_DIR="$T/d10" -- test; ok S10 "exactly one line per phase (compile+run)" cnt err '^\[cargo-slot\] tree=.* phase=(compile|run)( remapped-from=.*)?$' 2
  TCWD=$T/t1; tc s10c CARGO_TARGET_DIR="$T/d1" -- test; TCWD=$T/t2; tc s10d CARGO_TARGET_DIR="$T/d1" -- test
  ok S10 "remapped call prints remapped-from in BOTH phases" cnt err "phase=(compile|run) remapped-from=$T/d1\$" 2; TCWD=$T/wd
  rm -f "$T/go"; mkfifo "$T/go"; local n ok11=1 pa pb
  for n in 1 2 3 4 5; do
    mkdir -p "$T/r$n"; csl_repo "$T/r$n/ta"; csl_repo "$T/r$n/tb"
    ( read -r _ < "$T/go"; cd "$T/r$n/ta" && env PATH="$T/bin:$PATH" FAKE_LOG="$T/log11a" FAKE_LOCK="$T/hand/cargo.lock" FAKE_REAL_FLOCK="$RF" CARGO_SLOT_SELFTEST_CHILD=1 CARGO_SLOT_HAND_DIR="$T/hand" CARGO_SLOT_WMBUILD="$T/bin/wm-build" CARGO_SLOT_CARGO="$T/bin/cargo" CARGO_SLOT_MEM_FILE="$T/mem" CARGO_SLOT_IO_FILE="$T/io" CARGO_SLOT_CONFIG="$T/nocfg" CARGO_HOME="$T/ch" CARGO_TARGET_DIR="$T/shared$n" CARGO_SLOT_TARGETS_ROOT="$T/targets" TMPDIR="$T/tmp" bash "$self" check > /dev/null 2> "$T/e11a$n" ) & pa=$!
    ( read -r _ < "$T/go"; cd "$T/r$n/tb" && env PATH="$T/bin:$PATH" FAKE_LOG="$T/log11b" FAKE_LOCK="$T/hand/cargo.lock" FAKE_REAL_FLOCK="$RF" CARGO_SLOT_SELFTEST_CHILD=1 CARGO_SLOT_HAND_DIR="$T/hand" CARGO_SLOT_WMBUILD="$T/bin/wm-build" CARGO_SLOT_CARGO="$T/bin/cargo" CARGO_SLOT_MEM_FILE="$T/mem" CARGO_SLOT_IO_FILE="$T/io" CARGO_SLOT_CONFIG="$T/nocfg" CARGO_HOME="$T/ch" CARGO_TARGET_DIR="$T/shared$n" CARGO_SLOT_TARGETS_ROOT="$T/targets" TMPDIR="$T/tmp" bash "$self" check > /dev/null 2> "$T/e11b$n" ) & pb=$!
    sleep 0.3; { echo go; echo go; } > "$T/go"; wait "$pa" "$pb"
    # exactly one tree owns shared<n>; the other is remapped to its canon
    ta=$(realpath "$T/r$n/ta"); tb=$(realpath "$T/r$n/tb"); o=$(stampof "$T/shared$n")
    nrm=$(cat "$T/e11a$n" "$T/e11b$n" | grep -c "remapped-from=$T/shared$n\$")
    { [ "$o" = "$ta" ] || [ "$o" = "$tb" ]; } && [ "$nrm" = 1 ] || ok11=0
  done
  ok S11 "5 rounds of two concurrent first-claims of one empty D: exactly one owner, exactly one remap" test "$ok11" = 1
  rm -f "$T/go"
  # S12: .phase.lock — (a) an outside exclusive holder makes a call wait; (b) a compile that leaves an exclusive holder queued makes the RUN phase wait
  rm -rf "$T/pl"; mkdir -p "$T/pl"; realpath "$T/wd" > "$T/pl/.cargo-slot-tree"
  ( "$RF" -x "$T/pl/.phase.lock" bash -c 'date +%s.%N > "$0.start"; sleep 2; date +%s.%N > "$0.end"' "$T/pl/h" ) & pa=$!; sleep 0.3
  tc s12a CARGO_TARGET_DIR="$T/pl" -- check; wait "$pa"
  ok S12a "single/compile call waited for the exclusive holder (cargo ran after the holder ended)" test "$(awk -v e="$(cat "$T/pl/h.end")" -v s="$(grep -m1 '^C_TS\|^R_TS' "$T/log" | cut -d' ' -f2)" 'BEGIN{print (s>=e)?"1":"0"}')" = 1
  rm -rf "$T/pl"; mkdir -p "$T/pl"; realpath "$T/wd" > "$T/pl/.cargo-slot-tree"
  tc s12b CARGO_TARGET_DIR="$T/pl" FAKE_BG_HOLD="$T/pl/.phase.lock" FAKE_BG_OUT="$T/pl/h" FAKE_S_DELAY=0.6 FAKE_C_SLEEP=0.1 -- test; for _ in $(seq 60); do [ -s "$T/pl/h.end" ] && break; sleep 0.1; done
  ok S12b "the queued exclusive holder ran to completion" test -s "$T/pl/h.end"
  ok S12b "rc 0 (run phase completed after waiting)" rcis 0
  ok S12b "run-phase cargo started only after the queued exclusive holder ended" test "$(awk -v e="$(cat "$T/pl/h.end")" -v s="$(grep -m1 '^R_TS' "$T/log" | cut -d' ' -f2)" 'BEGIN{print (s>=e)?"1":"0"}')" = 1
  ok S12b "the holder really ran in between (start after the compile)" test "$(awk -v h="$(cat "$T/pl/h.start")" -v c="$(grep -m1 '^C_TS' "$T/log" | cut -d' ' -f2)" 'BEGIN{print (h>=c)?"1":"0"}')" = 1
  ok S12b "run phase took the lock shared (flock -s)" has log "^FLOCK -s $T/pl/.phase.lock "; ok S12b "compile took it exclusive (flock -x)" has log "^FLOCK -x $T/pl/.phase.lock "
  # S16: the lock fds do not leak: inside the fake cargo of each phase, no process outside the cargo's own subtree holds .phase.lock or .claim.lock
  rm -rf "$T/pl"; mkdir -p "$T/pl"
  tc s16 CARGO_TARGET_DIR="$T/pl" FAKE_FDCHK="$T/pl" FAKE_FDCHK_CL="$T/targets/.claim.lock" -- test
  ok S16 "compile cargo: .phase.lock held only by its own subtree + the 2 flock wrappers (-x phase, cargo.lock), nobody holds .claim.lock" has log '^FD compile phase_lock_leaks_wrappers=\[\|2\] claim_lock_leaks_wrappers=\[\|0\] self_holds_phase=1 self_holds_claim=0$'
  ok S16 "run cargo: .phase.lock held only by its own subtree + the ONE flock -s wrapper (no compile remnant, not the shell, not the guard filters)" has log '^FD run phase_lock_leaks_wrappers=\[\|1\] claim_lock_leaks_wrappers=\[\|0\] self_holds_phase=1 self_holds_claim=0$'
  grep '^FD ' "$T/log" | sed 's/^/    /'
  ok S16 ".phase.lock free once the call returned" "$RF" -n "$T/pl/.phase.lock" true
  ok S16 ".claim.lock free once the call returned" "$RF" -n "$T/targets/.claim.lock" true
  # L: launch log (ctl c671)
  rm -f "$T/ll"; tc l1 CARGO_SLOT_LAUNCH_LOG="$T/ll" -- check
  ok L1 "admitted single call: rc 0" rcis 0; ok L1 "exactly one decision line" cnt ll '[[:blank:]]admitted[[:blank:]]avail_g=' 1; ok L1 "exactly one end line" cnt ll '[[:blank:]]end[[:blank:]]rc=0[[:blank:]]' 1; ok L1 "2 lines total" cnt ll '' 2
  ok L1 "avail_g=64 (fake meminfo 64 G)" has ll '[[:blank:]]admitted[[:blank:]]avail_g=64[[:blank:]]sum_g=[0-9]+[[:blank:]]floor_g=[0-9]+[[:blank:]]io60=0[[:blank:]]class=[a-z]+[[:blank:]]phase=single[[:blank:]]tree=/.*[[:blank:]]pid=[0-9]+$'
  ok L1 "end line carries avail_g=64" has ll '[[:blank:]]end[[:blank:]]rc=0[[:blank:]]avail_g=64[[:blank:]]pid=[0-9]+$'; ok L1 "ISO-8601 local ts first" has ll '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4}[[:blank:]]'
  printf 'MemAvailable:   2097152 kB\n' > "$T/mem2"; rm -f "$T/ll"
  tc l2 CARGO_SLOT_LAUNCH_LOG="$T/ll" CARGO_SLOT_MEM_FILE="$T/mem2" CARGO_SLOT_MEM_MAXWAIT=1 CARGO_SLOT_POLL=1 -- check
  ok L2 "below the floor: rc 76" rcis 76; ok L2 "one refused line with avail_g=2" cnt ll '[[:blank:]]refused[[:blank:]]avail_g=2[[:blank:]]sum_g=' 1; ok L2 "no admitted line" nohas ll '[[:blank:]]admitted[[:blank:]]'; ok L2 "cargo never ran" nohas log '^CARGO '
  rm -f "$T/ll"; tc l3 CARGO_SLOT_LAUNCH_LOG="$T/ll" -- test
  ok L3 "SPLIT test: rc 0" rcis 0; ok L3 "compile decision line" cnt ll '[[:blank:]]admitted[[:blank:]].*[[:blank:]]phase=compile[[:blank:]]' 1; ok L3 "run decision line" cnt ll '[[:blank:]]admitted[[:blank:]].*[[:blank:]]phase=run[[:blank:]]' 1
  ok L3 "both decisions carry the SAME pid" test "$(grep -E '[[:blank:]]admitted[[:blank:]]' "$T/ll" | sed 's/.*pid=//' | sort -u | wc -l)" = 1; ok L3 "2 end lines" cnt ll '[[:blank:]]end[[:blank:]]rc=0[[:blank:]]' 2
  rm -f "$T/ll"; tc l4 CARGO_SLOT_LAUNCH_LOG="$T/ll" CARGO_SLOT_DRYRUN=1 -- check; ok L4 "DRYRUN call still logs one decision" cnt ll '[[:blank:]]admitted[[:blank:]]' 1
  tc l5 CARGO_SLOT_LAUNCH_LOG="$T/no/such/dir/ll" -- check; ok L5 "unwritable log path never changes the exit code" rcis 0
  printf 'one\ntwo\nthree\n' > "$T/ll"; tc l6 CARGO_SLOT_LAUNCH_LOG="$T/ll" -- --last 2
  ok L6 "--last 2 prints the last 2 lines" test "$(cat "$T/out")" = "$(printf 'two\nthree')"; ok L6 "rc 0" rcis 0; ok L6 "touches no gate/cargo/lock" nohas log '.'
  tc l7 CARGO_SLOT_LAUNCH_LOG="$T/ll" -- --last; ok L7 "--last default 5 prints all 3 here" test "$(wc -l < "$T/out")" = 3
  tc l8 CARGO_SLOT_LAUNCH_LOG="$T/absent" -- --last; ok L8 "--last on a missing log: rc 0, no output" rcis 0
  rm -rf -- "$T"
}
if [ "${1:-}" = --selftest ] || [ "${1:-}" = --selftest-split ]; then
  sf=0; sfc=""
  if [ "$1" = --selftest ]; then
  S=$(mktemp -d /mnt/data/.slot-selftest.XXXX); R=$S/root; O=$S/outside; fail=0; pids=()
  if [ -x "$0" ]; then echo "  ok   exec bit on $0"; else echo "  FAIL exec bit missing on $0 (install -m 0755)"; fail=1; fi
  if [ -d "${RUSTUP_HOME:-/home/jsy/.rustup}/toolchains" ]; then echo "  ok   RUSTUP_HOME=${RUSTUP_HOME:-unset} has toolchains"; else echo "  FAIL RUSTUP_HOME has no toolchains"; fail=1; fi
  mk() { mkdir -p "$R/a/old" "$R/a/new" "$R/a/held" "$R/b" "$R/envheld/x" "$R/real" "$O"; touch "$O/victim" "$R/b/f"
         ln -sfn "$O" "$R/link"; ln -sfn "$O" "$R/real/linkchild"
         touch -d "3 days ago" "$O/victim" "$R/a/old" "$R/a/held" "$R/b/f" "$R/b" "$R/envheld/x" "$R/envheld" "$O"
         touch -h -d "3 days ago" "$R/link" "$R/real/linkchild"; touch -d "3 days ago" "$R/real"; touch "$R/a/new"; }
  chk() { local want=$1 p=$2; if { [ "$want" = keep ] && [ -e "$p" -o -L "$p" ]; } || { [ "$want" = gone ] && [ ! -e "$p" ] && [ ! -L "$p" ]; }; then echo "  ok   $want ${p#$S/}"; else echo "  FAIL $want ${p#$S/}"; fail=1; fi; }
  mk; echo "case dry-run (CARGO_SLOT_DRYRUN=1, FORCE=1): deletes nothing"
  CARGO_SLOT_DRYRUN=1 CARGO_SLOT_REAP_FORCE=1 reap_gate "$R"; chk keep "$R/a/old"; chk keep "$R/b"; chk keep "$R/real"
  (cd "$R/a/held" && exec sleep 60) & pids+=($!); TMPDIR=$R/envheld/x sleep 60 & pids+=($!); sleep 1
  echo "case live reap (FORCE=1)"; CARGO_SLOT_REAP_FORCE=1 reap_gate "$R" 2>&1 | sed "s#$S/##; s/^/  /"
  chk gone "$R/a/old"; chk gone "$R/b"; chk keep "$R/a/new"; chk keep "$R/a/held"; chk keep "$R/envheld"
  echo "case symlinks never followed"; chk keep "$R/link"; chk keep "$O/victim"; chk keep "$O"
  kill "${pids[@]}" 2>/dev/null; rm -rf -- "$S"
  [ "$fail" = 0 ] && echo "  reap cases PASS" || { sf=1; sfc="$sfc reap"; }
  fi
  split_selftest
  [ "$sf" = 0 ] && { echo "SELFTEST OK"; exit 0; }; echo "SELFTEST FAIL$sfc"; exit 1
fi
reap_gate /mnt/data/hand-tmp
# 10-19 9:1x PM rb (1007 deadlock): a hand `cargo test` with CARGO_HOME=/home/jsy/.cargo held ~/.cargo/.package-cache-mutate
#   (WRITE, 10 min, 0 % CPU) while its fixture tests ran nested cargo waiting on the same lock: a self-deadlock that also froze the
#   daemon run-1007 inner and a canary (shared CARGO_HOME). The slot never runs on the shared CARGO_HOME: unset or /home/jsy/.cargo
#   gives a private home per target dir via mk-cargo-home.sh (own lock, own registry/src + git/checkouts; index/cache/git-db shared).
ch=$(readlink -f "${CARGO_HOME:-/home/jsy/.cargo}" 2>/dev/null || echo "${CARGO_HOME:-}")
if [ -z "$ch" ] || [ "$ch" = /home/jsy/.cargo ]; then
  # 9:2x PM controller correction: own registry/src + git/checkouts per home (cp -al seed), only index/cache/git-db shared
  ch=$(/mnt/data/hand/mk-cargo-home.sh /home/jsy/.cargo-hand/$(basename "$CARGO_TARGET_DIR")) || { echo "[cargo-slot] REFUSED: mk-cargo-home failed" >&2; exit 76; }
  echo "[cargo-slot] private CARGO_HOME=$ch (shared ~/.cargo refused for hand cargo)" >&2
elif [ -L "$ch/registry/src" ] || [ -L "$ch/registry" ]; then
  echo "[cargo-slot] REFUSED: CARGO_HOME=$ch shares registry/src by symlink; build it with /mnt/data/hand/mk-cargo-home.sh" >&2; exit 76
fi
export CARGO_HOME="$ch"
CAP_G=12; FLOOR_G=12
# rb 10-19 11:2x PM (CTRL 11:17, Fable 1008 ruling): a wm-build clone holds a MEASURED cap (6 MIG scopes, max memory.peak 2.8 G):
#   --prefix wm-build -> [cargo_jobs.mem_caps_gb.wm-build] hand = 5; CAP_G is the admission count only (the scope carries no Memory* property by policy (Joe #195, no discretionary worker caps)).
#   Physical floor = the daemon headroom_gb (4) instead of 12. Reverse: a wm-build scope peak > 5 G (run-peak.log hand.wm-build-*) -> cap = peak + 1.
# 11:2x PM correction: the binary stores no prefix on a hand row, so the Σ reads the CLASS cap. hand class default = 5 (config);
#   any non-wm-build hand cargo (mcphost) acquires as --class land (12.5 G count) so it is never undercounted.
CLS=land; PFX=
# rb 10-22 12:3x PM (Fable 12:28 + CTRL 12:33 on d-4acd): mcphost hand cargo MEASURED ws max 7.6 / anon 7.1 (run-peak.log, newest 10 hand mcphost)
#   -> class hand, [cargo_jobs.mem_caps_gb] hand = 9 (was class land 12.5). Reverse: any hand mcphost ws row > 9 -> drop the mcphost*) arm (back to land 12.5).
# rb 10-22 4:4x PM W4 D1 (correction f9de; 1039 refused 4:32 PM: two coder clones under a mktemp dir named `wm`/`tmp.*` were priced land 12.5, +7.5 G each): the class
#   comes from WHAT THE TREE IS, not what its directory is called. Order: (1) `git remote get-url origin`, case-insensitive, final path component only:
#   `[/:]wm-build(.git)?/?$` -> wm-build, `[/:]mcphost(.git)?/?$` -> mcphost (https, ssh and local-path origins all match) and a match WINS;
#   (2) no origin, or an origin that matches neither (rb 5:1x PM: hand clones are often made from a local clone, origin /mnt/data/hand/wm-build-qfix-base): the root Cargo.toml
#   `[package] name` (exactly wm-build | mcphost); (3) still unknown: the old basename arm (wm-build* | mcphost*); (4) else land. --release below is unchanged.
# PREMISE (W4): the 12.5 G land price on a wm-build coder clone falsely refuses product runs and blocks hand cargo (observed 1039); remote identity is the one property no clone path can fake by naming.
# EXPIRES: 2026-11-21 (documentation only, like SPLIT's; re-grade with the first month of `class=` lines). REVERSE: restore cargo-slot.sh.bak-756963d4 (the true pre-W4 file; cargo-slot.sh.bak-6039f9cc is the intermediate remote-wins version).
cls_top=$(git rev-parse --show-toplevel 2>/dev/null); cls_kind=; cls_via=
cls_url=$(git -C "${cls_top:-.}" remote get-url origin 2>/dev/null); cls_url=${cls_url,,}
if [ -n "$cls_url" ]; then
  cls_rx_wm='[/:]wm-build(\.git)?/?$'; cls_rx_mh='[/:]mcphost(\.git)?/?$'
  if [[ $cls_url =~ $cls_rx_wm ]]; then cls_kind=wm-build; cls_via=remote; elif [[ $cls_url =~ $cls_rx_mh ]]; then cls_kind=mcphost; cls_via=remote; fi
fi
if [ -z "$cls_kind" ]; then   # no origin, or an origin that is neither repo (e.g. a local clone of a clone, /mnt/data/hand/wm-build-qfix-base): what the tree IS, then what it is called
  cls_via=cargo-toml
  cls_name=$(awk '/^\[/{s=($0 ~ /^\[package\][ \t]*(#.*)?$/); next} s && /^[ \t]*name[ \t]*=/{v=$0; sub(/^[^=]*=[ \t]*"/,"",v); sub(/".*$/,"",v); print v; exit}' "${cls_top:-.}/Cargo.toml" 2>/dev/null)
  case "$cls_name" in wm-build) cls_kind=wm-build;; mcphost) cls_kind=mcphost;; esac
  if [ -z "$cls_kind" ]; then
    cls_via=basename
    case "$(basename "${cls_top:-$(pwd)}")" in wm-build*) cls_kind=wm-build;; mcphost*) cls_kind=mcphost;; esac
  fi
fi
case "$cls_kind" in wm-build) CAP_G=5; FLOOR_G=4; CLS=hand; PFX=wm-build;; mcphost) CAP_G=9; CLS=hand;; esac
# CTRL 11:23 PM rider (D28): a wm-build RELEASE build has no measured peak yet -> class land 12.5 admission count.
#   Reverse: one release scope measured with memory.peak sampled to the end <= 4 G -> release may use class hand.
case " $* " in *" --release "*|*" -r "*) [ "$CLS" = hand ] && { CAP_G=12; FLOOR_G=12; CLS=land; PFX=; };; esac
echo "[cargo-slot] class=$CLS${PFX:+ prefix=$PFX} via=$cls_via${cls_kind:+ kind=$cls_kind}" >&2   # W4: the decision, once per call (a verifier reads this line)
# rb 10-20 12:4x AM (CTRL caps-drift ask): CAP_G is the admission count only, DERIVED from the class cap the Σ counts (floor of [cargo_jobs.mem_caps_gb].<class>); the scope carries no Memory* property by policy (Joe #195, no discretionary worker caps),
#   and a cap change needs no edit here. Unreadable config = the literals above.
# rb 10-22 1:0x PM (CTRL seat note 1): a wm-build clone acquires with --prefix wm-build (the binary prices a hand row by the prefix recorded on
#   the row since 0.77.59, run_prefix), so the admission count CAP_G = floor([cargo_jobs.mem_caps_gb.wm-build].<class>) first, the class table second.
CFG_CAP=$(awk -v c="$CLS" -v pt="${PFX:+[cargo_jobs.mem_caps_gb.$PFX]}" '/^\[/{s=$0; next} s=="[cargo_jobs.mem_caps_gb]" || (pt!="" && s==pt){sub(/#.*/,""); n=split($0,kv,"="); gsub(/ /,"",kv[1]); gsub(/ /,"",kv[2]); if(n==2 && kv[1]==c){ if(s==pt) p=int(kv[2]); else b=int(kv[2]) }} END{if(p!="") print p; else if(b!="") print b}' "${CARGO_SLOT_CONFIG:-$HOME/.config/wm-build/config.toml}" 2>/dev/null)
if [ -n "$CFG_CAP" ] && [ "$CFG_CAP" -gt 0 ] 2>/dev/null && [ "$CFG_CAP" != "$CAP_G" ]; then
  echo "[cargo-slot] admission count ${CAP_G}G -> ${CFG_CAP}G = floor(${PFX:+prefix $PFX }class $CLS cap)" >&2; CAP_G=$CFG_CAP
fi
NEED_G=$((CAP_G + FLOOR_G))
iopsi60() { awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg60=/){split($i,a,"="); print int(a[2]); exit}}' "${CARGO_SLOT_IO_FILE:-/proc/pressure/io}"; }
availg() { awk '/MemAvailable/{print int($2/1048576)}' "${CARGO_SLOT_MEM_FILE:-/proc/meminfo}"; }
run() { if [ "${CARGO_SLOT_DRYRUN:-0}" = 1 ]; then echo "[cargo-slot] DRY would run: $*" >&2; return 0; fi; "$@"; }
pre=(); post=(); seen=0; for a in "$@"; do if [ $seen = 0 ] && [ "$a" = "--" ]; then seen=1; post+=("--"); continue; fi; if [ $seen = 0 ]; then case "$a" in -j[0-9]*) ;; *) pre+=("$a");; esac; else post+=("$a"); fi; done
# cslj 11-01: csub = the cargo subcommand (first pre-"--" arg that is not a +toolchain); `nextest` has no -j (build jobs = --build-jobs, -j means test threads on run)
csub=""; for a in "${pre[@]}"; do case "$a" in +*) ;; *) csub=$a; break;; esac; done
JFLAG=(-j 4); [ "$csub" = nextest ] && JFLAG=(--build-jobs 4)
# split decision: the subcommand is the first pre-"--" arg that is not a +toolchain; only a plain `test` (no --no-run/--doc) splits
split=0
if [ "$SPLIT" = 1 ]; then
  sub=""; for a in "${pre[@]}"; do case "$a" in +*) ;; *) sub=$a; break;; esac; done
  if [ "$sub" = test ]; then split=1; for a in "${pre[@]}"; do case "$a" in --no-run|--doc) split=0;; esac; done; fi
fi
poll=${CARGO_SLOT_POLL:-30}
wait_gates() { # memory floor (hard, exit 76) then IO PSI <= 80 (soft); also re-run before the run phase
  local waited=0 memw=0 max=${CARGO_SLOT_MEM_MAXWAIT:-3600} maxio=${CARGO_SLOT_IO_MAXWAIT:-1800} av
  while av=$(availg); [ -z "$av" ] || [ "$av" -lt "$NEED_G" ]; do
    [ -z "$av" ] && { lg_decision refused na "$(iopsi60)"; echo "[cargo-slot] REFUSED: cannot read MemAvailable" >&2; exit 76; }
    [ "$waited" -ge "$max" ] && { lg_decision refused "$av" "$(iopsi60)"; echo "[cargo-slot] REFUSED: MemAvailable ${av}G < ${NEED_G}G for ${max}s" >&2; exit 76; }
    echo "[cargo-slot] waiting: MemAvailable ${av}G < ${NEED_G}G (waited ${waited}s)" >&2
    sleep "$poll"; waited=$((waited + poll))
  done
  memw=$waited; waited=0
  while io=$(iopsi60); [ "$io" -gt 80 ]; do
    [ "$waited" -ge "$maxio" ] && { echo "[cargo-slot] IO wait cap ${maxio}s reached (avg60=${io}); running anyway" >&2; break; }
    echo "[cargo-slot] waiting: IO PSI avg60=${io} > 80 (waited ${waited}s)" >&2
    sleep "$poll"; waited=$((waited + poll))
  done
  if [ "$memw" -gt 0 ]; then lg_decision waited-then-admitted "$av" "$io"; else lg_decision admitted "$av" "$io"; fi
}
# CSL begin
if [ "$split" = 1 ]; then csl_line compile; else csl_line single; fi
# CSL end
if [ "$split" = 1 ]; then lphase=compile; else lphase=single; fi
wait_gates
# 10-19 9:3x PM CTRL (MGC, true Σ 36 > 26 on an MGA grant: this scope was invisible to the gate): the slot registers a `hand`
#   cargo-jobs row (cap 12 G = the admission count; the scope carries no Memory* property) through the live binary, so the tick admission and every acquire count it;
#   it waits for Σ room (CARGO_SLOT_ACQ_WAIT_MIN, default 60) and maps acquire exit 75 (no slot) to 76. Real paths: HOME may be a throwaway.
# 10-19 9:4x PM CTRL (front of queue: MGC must not wait FIFO behind older hand calls): a target basename listed in
#   /mnt/data/hand/cargo.priority jumps the hand queue WHILE IT WAITS. It drops /mnt/data/hand/cargo.prio-waiting.<pid>,
#   SIGSTOPs the flock processes queued on cargo.lock (never the holder; a stopped flock(2) waiter leaves the wait queue and
#   restarts the syscall on SIGCONT), and SIGCONTs them the instant it holds the lock (or on any exit). A non-priority call
#   waits before flock while a live priority waiter exists. One holder at a time is unchanged.
H=${CARGO_SLOT_HAND_DIR:-/mnt/data/hand}; PRIO=$H/cargo.priority; LK=$H/cargo.lock; WF=$H/cargo.prio-waiting; me=$(basename "$CARGO_TARGET_DIR")
lkholder() { local ino; ino=$(stat -c %i "$LK"); awk -v i=":$ino " 'index($0, i) && $2 != "->" {print $5}' /proc/locks | head -1; }
prio_waiting() { local f; for f in "$WF".*; do [ -e "$f" ] || continue; if kill -0 "${f##*.}" 2>/dev/null; then return 0; fi; rm -f "$f"; done; return 1; }
WRAP=(); stopped=()
if grep -qx "$me" "$PRIO" 2>/dev/null && [ "${CARGO_SLOT_DRYRUN:-0}" != 1 ]; then
  touch "$WF.$$"
  trap 'for p in "${stopped[@]}"; do kill -CONT "$p" 2>/dev/null; done; rm -f "$WF.$$"' EXIT
  h=$(lkholder)
  for p in $(pgrep -f "^flock $LK "); do [ "$p" = "$h" ] && continue; kill -STOP "$p" 2>/dev/null && stopped+=("$p"); done
  echo "[cargo-slot] PRIORITY $me: holder=${h:-none}; queued waiters held: ${stopped[*]:-none}" >&2
  WRAP=(bash -c 'rm -f "$0"; for p in $1; do kill -CONT "$p" 2>/dev/null; done; shift; exec "$@"' "$WF.$$" "${stopped[*]}")
else
  waited=0; while prio_waiting; do [ $((waited % 120)) = 0 ] && echo "[cargo-slot] waiting: a priority hand call is queued (waited ${waited}s)" >&2; sleep 10; waited=$((waited + 10)); done
fi
CARGO_BIN=${CARGO_SLOT_CARGO:-/home/jsy/.cargo/bin/cargo}
ACQ=("${CARGO_SLOT_WMBUILD:-/home/jsy/.cargo/bin/wm-build}" builder cargo-jobs acquire --class "$CLS" ${PFX:+--prefix "$PFX"} --producer cargo-slot --config /home/jsy/.config/wm-build/config.toml --state-dir /home/jsy/.local/state/wm-build --wait-minutes "${CARGO_SLOT_ACQ_WAIT_MIN:-60}" --)
if [ "$split" = 1 ]; then # phase=compile: args before the first cargo-level "--" + --no-run; the runner args wait for phase=run
  echo "[cargo-slot] phase=compile" >&2; cargs=("${pre[@]}" --no-run); cpost=(); t0=$SECONDS
else cargs=("${pre[@]}"); cpost=("${post[@]}"); fi
# CSL begin: single-phase and compile hold the target's phase lock exclusive for the whole cargo (taken OUTSIDE cargo.lock)
run flock -x "$PL" flock "$LK" "${WRAP[@]}" "${ACQ[@]}" systemd-run --user --scope --slice=app.slice --quiet nice -n 10 ionice -c2 -n7 env CARGO_SHIM_INNER=1 CARGO_HOME="$CARGO_HOME" "$CARGO_BIN" "${cargs[@]}" "${JFLAG[@]}" "${cpost[@]}"
# CSL end
rc=$?; [ "$rc" = 75 ] && { lg_decision refused "$(availg)" "$io"; echo "[cargo-slot] REFUSED: no memory-admission slot (acquire exit 75)" >&2; rc=76; }; echo "[cargo-slot] slot avail=$(availg)G io60=${io} rc=$rc" >&2; lg_end "$rc"
{ [ "$split" != 1 ] || [ "$rc" != 0 ]; } && exit $rc
# phase=run: flock has returned, so cargo.lock is free (its fd only ever lived in flock's child); nothing below takes it again.
echo "[cargo-slot] phase=run (lock released after compile $((SECONDS - t0))s)" >&2
# CSL begin
csl_line run
# CSL end
lphase=run
wait_gates
guard() { # $1 = state dir shared by the two stream filters; every line passes through unchanged, each notice is logged once (`set -C; : > flag` = O_EXCL is the atomic once-gate: uutils mkdir on RB is NOT atomic and mawk's system() return is unreliable with two concurrent filters)
  awk -v st="$1" '
    { print; fflush(); t = $0; gsub(/\033\[[0-9;]*m/, "", t) }
    !w && t ~ /^[ \t]+(Compiling|Checking) / { w = 1; system("(set -C; : > \"" st "/warn\") 2>/dev/null && echo \"[cargo-slot] WARN phase-run rebuilt outside lock\" >&2") }
    !d && t ~ /^[ \t]*Doc-tests / { d = 1; system("(set -C; : > \"" st "/doc\") 2>/dev/null && echo \"[cargo-slot] INFO phase-run doctest-compile\" >&2") }'
}
mk=$(mktemp -u "${TMPDIR:-/tmp}/cargo-slot-run.XXXXXX"); gd=$(mktemp -d "${TMPDIR:-/tmp}/cargo-slot-guard.XXXXXX")
mkfifo "$gd/o" "$gd/e"
guard "$gd" < "$gd/o" & po=$!
guard "$gd" < "$gd/e" >&2 & pe=$!
# $mk is touched only by the wrapper that execs cargo, i.e. after the acquire granted and the scope started
# CSL begin: the run phase holds the phase lock SHARED around its cargo (waits for a same-target compile/check, taken before the acquire)
run flock -s "$PL" "${ACQ[@]}" systemd-run --user --scope --slice=app.slice --quiet -p CPUWeight=50 nice -n 10 ionice -c2 -n7 env CARGO_SHIM_INNER=1 CARGO_HOME="$CARGO_HOME" bash -c 'touch "$0"; exec "$@"' "$mk" "$CARGO_BIN" "${pre[@]}" -j 4 "${post[@]}" > "$gd/o" 2> "$gd/e"
# CSL end
rc=$?
# the filters end at EOF; a daemonized grandchild holding the fifo must not hang the call, so give them 10 s then stop our own two pids
for _ in $(seq 50); do kill -0 "$po" 2>/dev/null || kill -0 "$pe" 2>/dev/null || break; sleep 0.2; done
kill "$po" "$pe" 2>/dev/null; wait "$po" "$pe" 2>/dev/null
if [ "$rc" != 0 ] && [ ! -e "$mk" ]; then echo "[cargo-slot] phase=run acquire-timeout (acquire/scope rc=$rc before cargo started; retry)" >&2; rc=76; fi
rm -f "$mk"; [ -n "$gd" ] && rm -rf "$gd"
echo "[cargo-slot] slot avail=$(availg)G io60=${io} rc=$rc" >&2; lg_end "$rc"; exit $rc
