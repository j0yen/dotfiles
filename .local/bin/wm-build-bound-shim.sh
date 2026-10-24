#!/usr/bin/env bash
# wm-build-bound-shim.sh (marker: wm-build-bound-shim) -- installed at ~/.cargo/bin/wm-build, the real binary beside it as wm-build.real.
# PURPOSE: top-level `wm-build status` and `wm-build runs` read the whole user journal (~12 G) into memory; one call from an r7 timer froze
#   ryzen7 10-24 2:38 PM and a Claude-Bash hook cannot see timers, scripts or subprocesses. This shim bounds those two subcommands host-side:
#   they run in a transient scope with MemoryMax=2G, MemorySwapMax=0, and are REFUSED (exit 2) when no memory bound is available.
# PREMISE: until the wm-build status/runs whole-journal fix is promoted (rb hand PR 1e3f).   EXPIRES: 2026-10-31 (enforced by wm-build-shim-ctl.sh).
# CLASSIFIER: walk argv, skip the wm-build GLOBAL options (src/cli.rs top-level struct: --config --prd-dir --state-dir --max-runs --set, each
#   takes a value, also as --opt=value) and stop at the first non-option word = the subcommand. Bound iff it is `status` or `runs`. An option
#   not in that list before any subcommand -> fallback: bound iff some word equals `status` or `runs`. Over-matching only bounds a call.
# `--selftest` as $1 is answered by the shim itself (classifier table, never execs REAL).
# Seams (tests): WM_BUILD_REAL (real binary), WM_BUILD_SHIM_RUNDIR (default /run/user/$(id -u)).
set -u

# wmb_classify <argv...>: prints "bound" or "pass".
wmb_classify() {
  local args=("$@") n=$# idx=0 w
  while [ "$idx" -lt "$n" ]; do
    w=${args[$idx]}
    case $w in
      --config|--prd-dir|--state-dir|--max-runs|--set) idx=$((idx + 2)) ;;
      --config=*|--prd-dir=*|--state-dir=*|--max-runs=*|--set=*) idx=$((idx + 1)) ;;
      -*)  # unknown option before any subcommand: fallback, bound iff some word is status/runs
        for w in "${args[@]}"; do
          case $w in status|runs) echo bound; return 0 ;; esac
        done
        echo pass; return 0 ;;
      status|runs) echo bound; return 0 ;;
      *) echo pass; return 0 ;;   # first non-option word = another subcommand
    esac
  done
  echo pass
}

wmb_selftest() {
  local n=0 bad=0 want got line
  # <want> <argv...>
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    set -- $line
    want=$1; shift
    got=$(wmb_classify "$@")
    n=$((n + 1))
    if [ "$got" != "$want" ]; then echo "selftest FAIL: [$*] want $want got $got" >&2; bad=1; fi
  done <<'CASES'
bound status
bound runs
bound status --json
bound status --brief
bound status --flakes --days 3
bound --state-dir /x status --brief
bound --config /c runs
bound --prd-dir /p --state-dir /s status
bound --max-runs 2 status
bound --set a.b=status status
bound --state-dir=/x runs
bound -j4 status
bound --json status
pass --set status=1 queue
pass --config status queue
pass run close 5 --reason status
pass run redrive 5 --from land
pass run show 5
pass drive --run 1042
pass daemon
pass --version
pass -V
pass --help
pass builder probe
pass queue
pass scan
pass
pass --state-dir /x
pass --config
CASES
  if [ "$bad" -ne 0 ]; then exit 1; fi
  echo "selftest OK n=$n"
  exit 0
}

if [ "${1:-}" = "--selftest" ]; then wmb_selftest; fi

REAL=${WM_BUILD_REAL:-$(dirname "$(readlink -f "$0")")/wm-build.real}

if [ "$(wmb_classify "$@")" = bound ]; then
  rundir=${WM_BUILD_SHIM_RUNDIR:-/run/user/$(id -u)}
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -e "$rundir/bus" ]; then
    export XDG_RUNTIME_DIR=$rundir
  fi
  if command -v systemd-run >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "$XDG_RUNTIME_DIR/bus" ]; then
    exec systemd-run --user --scope --quiet --collect -p MemoryMax=2G -p MemorySwapMax=0 -- "$REAL" "$@"
  fi
  echo "wm-build-bound-shim: status/runs refused, no memory bound available; read ~/.cache/fleet-dash/status.json" >&2
  exit 2
fi
exec "$REAL" "$@"
