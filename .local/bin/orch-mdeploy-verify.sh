#!/usr/bin/env bash
# orch-mdeploy-verify.sh <sha> [--pr N] [--log PATH]: mcphost-deploy verify on orch, the release gate host (Joe approval #52, 10-27 "move to orch").
# Called by seats as `ssh orch orch-mdeploy-verify.sh <sha> --pr N`. Private clone under ~/.cache/mdeploy-verify/<sha>/src; the live ~/repos/mcphost-deploy is read only (origin URL).
# Command = the orch release gate argv plus report-only -rA, under env -i with the gate allowlist. Exits with pytest's rc.
set -u
sha=${1:-}; [ $# -gt 0 ] && shift
pr=""; logarg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr=${2:-}; shift 2 ;;
    --log) logarg=${2:-}; shift 2 ;;
    *) echo "usage: orch-mdeploy-verify.sh <sha> [--pr N] [--log PATH]" >&2; exit 2 ;;
  esac
done
case "$sha" in *[!0-9a-f]*|"") echo "refused: sha must be 40 hex" >&2; exit 2 ;; esac
[ "${#sha}" = 40 ] || { echo "refused: sha must be 40 hex" >&2; exit 2; }
case "$pr" in *[!0-9]*) echo "refused: --pr must be a number" >&2; exit 2 ;; esac
host=$(hostname)
case "$host" in orch|orch.*) ;; *) [ "${ORCH_MDV_ALLOW_HOST:-}" = 1 ] || { echo "refused: host $host is not orch (verifies run on the release gate host)" >&2; exit 2; } ;; esac

d=$HOME/.cache/mdeploy-verify/$sha
log=${logarg:-$d/verify.log}
mkdir -p "$d/tmp" || exit 2
exec 9>"$d/.lock"
flock -n 9 || { echo "refused: another orch-mdeploy-verify holds the lock for $sha" >&2; exit 2; }

url=$(git -C "$HOME/repos/mcphost-deploy" remote get-url origin) || { echo "no origin url in ~/repos/mcphost-deploy" >&2; exit 2; }
[ -d "$d/src/.git" ] || git clone -q "$url" "$d/src" || exit 2
if ! git -C "$d/src" fetch -q origin "$sha"; then
  if [ -z "$pr" ] || ! git -C "$d/src" fetch -q origin "pull/$pr/head"; then echo "cannot fetch $sha" >&2; exit 2; fi
fi
git -C "$d/src" checkout -q --detach "$sha" || exit 2
cd "$d/src" || exit 2

cmd='uv run --locked pytest -q -m "not live and not slow and not www_pin" --durations=15 -p no:cacheprovider -rA'
env -i \
  PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  HOME="$HOME" LANG="${LANG:-C.UTF-8}" USER="${USER:-jsy}" LOGNAME="${USER:-jsy}" SHELL=/bin/bash \
  TMPDIR="$d/tmp" TMP="$d/tmp" TEMP="$d/tmp" \
  MCPHOST_DEPLOY_GATE_HERMETIC=1 \
  bash -c "$cmd" > "$log" 2>&1
rc=$?
dirty=0; [ -n "$(git status --porcelain)" ] && dirty=1
{
  echo "WM-VERIFY HOST=$host"
  echo "WM-VERIFY HEAD=$(git rev-parse HEAD)"
  echo "WM-VERIFY CMD=$cmd"
  echo "WM-VERIFY DIRTY=$dirty"
  echo "WM-VERIFY EXIT=$rc"
} >> "$log"
echo "log: $log"
echo "sha256: $(sha256sum "$log" | cut -d' ' -f1)"
exit "$rc"
