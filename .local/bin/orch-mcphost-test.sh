#!/usr/bin/env bash
# orch-mcphost-test.sh <archive.tar.zst> [--sha SHA] [--log PATH] [--filter EXPR]: mcphost test EXECUTION on orch from a RedBaron-built nextest archive (Joe approval #54, 10-27 "and use orch for mcphost testing").
# Called by seats as `ssh orch orch-mcphost-test.sh <archive> --sha S`. Nothing is compiled here: the archive carries the test binaries; orch only extracts and runs them.
# Capped: systemd-run --user --scope with MemoryMax/CPUQuota, nice 19, ionice idle. Yields to the chain: while a chain job (release-gate verify, daemon land suite) runs, wait up to ORCH_MCT_YIELD_WAIT_S, then exit 75 (busy) without running.
# Exits with nextest's rc. Log ends with WM-VERIFY lines (HOST, ARCHIVE sha256, SHA, CMD, EXIT).
set -u
archive=${1:-}; [ $# -gt 0 ] && shift
sha=""; logarg=""; filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) sha=${2:-}; shift 2 ;;
    --log) logarg=${2:-}; shift 2 ;;
    --filter) filter=${2:-}; shift 2 ;;
    *) echo "usage: orch-mcphost-test.sh <archive.tar.zst> [--sha SHA] [--log PATH] [--filter EXPR]" >&2; exit 2 ;;
  esac
done
case "$archive" in *.tar.zst) ;; *) echo "refused: archive must be a nextest *.tar.zst" >&2; exit 2 ;; esac
[ -f "$archive" ] || { echo "refused: archive not found: $archive" >&2; exit 2; }
case "$sha" in *[!0-9a-f]*) echo "refused: --sha must be hex" >&2; exit 2 ;; esac
host=$(hostname)
case "$host" in orch|orch.*) ;; *) [ "${ORCH_MCT_ALLOW_HOST:-}" = 1 ] || { echo "refused: host $host is not orch (mcphost tests execute on orch)" >&2; exit 2; } ;; esac

mem=${ORCH_MCT_MEM_MAX:-4G}; cpu=${ORCH_MCT_CPU_QUOTA:-150%}; jobs=${ORCH_MCT_JOBS:-2}
case "$jobs" in *[!0-9]*|"") echo "refused: ORCH_MCT_JOBS must be a number" >&2; exit 2 ;; esac
nextest=${ORCH_MCT_NEXTEST:-cargo-nextest}
sdrun=${ORCH_MCT_SYSTEMD_RUN:-systemd-run}
# Chain-busy probe: exit 0 = a chain job is running. Default looks for the release-gate verify and the daemon land suite.
busy=${ORCH_MCT_BUSY_CMD:-pgrep -f "orch-mdeploy-verify.sh|wm-build.* land"}
wait_s=${ORCH_MCT_YIELD_WAIT_S:-600}
waited=0
while bash -c "$busy" >/dev/null 2>&1; do
  if [ "$waited" -ge "$wait_s" ]; then echo "busy: chain job still running after ${waited}s; not started" >&2; exit 75; fi
  sleep "${ORCH_MCT_POLL_S:-10}"; waited=$((waited + ${ORCH_MCT_POLL_S:-10}))
done

key=${sha:-$(sha256sum "$archive" | cut -c1-12)}
d=$HOME/.cache/mcphost-test/$key
log=${logarg:-$d/test.log}
mkdir -p "$d/tmp" "$d/x" || exit 2
exec 9>"$d/.lock"
flock -n 9 || { echo "refused: another orch-mcphost-test holds the lock for $key" >&2; exit 2; }

args=(run --archive-file "$archive" --extract-to "$d/x" --extract-overwrite --no-fail-fast -j "$jobs")
[ -n "$filter" ] && args+=(-E "$filter")
cmd="$nextest ${args[*]}"
env -i PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  HOME="$HOME" LANG="${LANG:-C.UTF-8}" USER="${USER:-jsy}" LOGNAME="${USER:-jsy}" SHELL=/bin/bash \
  TMPDIR="$d/tmp" TMP="$d/tmp" TEMP="$d/tmp" \
  "$sdrun" --user --scope --quiet -p MemoryMax="$mem" -p MemorySwapMax=0 -p CPUQuota="$cpu" \
  nice -n 19 ionice -c3 "$nextest" "${args[@]}" > "$log" 2>&1
rc=$?
{
  echo "WM-VERIFY HOST=$host"
  echo "WM-VERIFY ARCHIVE_SHA256=$(sha256sum "$archive" | cut -d' ' -f1)"
  echo "WM-VERIFY SHA=${sha:-unknown}"
  echo "WM-VERIFY CMD=$cmd"
  echo "WM-VERIFY EXIT=$rc"
} >> "$log"
echo "log: $log"
echo "sha256: $(sha256sum "$log" | cut -d' ' -f1)"
exit "$rc"
