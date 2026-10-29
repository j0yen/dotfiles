#!/usr/bin/env bash
# hpld-remote-verify.sh <owner/name> <pr> <sha40> [--suite CMD]: run ON THE SUITE HOST (deployed there by its seat; nothing in it names a host).
# Fetches refs/pull/<pr>/head into a fresh per-run worktree, refuses (exit 4) when that ref is not <sha> at run time, checks out <sha> detached,
# and starts `wm-verify-run <suite>` as a detached transient unit hpld-verify-<name>-<pr>-<sha12> (MemoryMax, TMPDIR off tmpfs).
# The log is written ONCE (temp + mv, an existing path is refused with exit 3) at $HPLD_SUITE_LOGS/<unit>.log; its first line is
#   HPLD-VERIFY COMMIT=<sha> HEAD=<git rev-parse HEAD> DIRTY=<0|1> EXIT=<rc> HOST=<hostname>
# followed by the wm-verify-run output. Stdout: UNIT=<unit> and LOG=<path>. Exit: 0 started, 2 usage, 3 log path exists, 4 pull ref != sha.
# Env: HPLD_SUITE_WT (default /mnt/data/hpld/wt) HPLD_SUITE_TMP (/mnt/data/hpld/tmp) HPLD_SUITE_LOGS (/mnt/data/hpld/logs) HPLD_SUITE_MEMMAX (8G)
#      HPLD_SUITE_GIT_BASE (https://github.com/) HPLD_GIT HPLD_SYSTEMD_RUN HPLD_WM_VERIFY_RUN (stubs in tests)
set -euo pipefail
WT_ROOT="${HPLD_SUITE_WT:-/mnt/data/hpld/wt}"; TMP_ROOT="${HPLD_SUITE_TMP:-/mnt/data/hpld/tmp}"; LOGS="${HPLD_SUITE_LOGS:-/mnt/data/hpld/logs}"
MEMMAX="${HPLD_SUITE_MEMMAX:-8G}"; GIT_BASE="${HPLD_SUITE_GIT_BASE:-https://github.com/}"
GIT="${HPLD_GIT:-git}"; SDRUN="${HPLD_SYSTEMD_RUN:-systemd-run}"; WMV="${HPLD_WM_VERIFY_RUN:-$HOME/.local/bin/wm-verify-run}"
die() { echo "hpld-remote-verify: $2" >&2; exit "$1"; }

if [ "${1:-}" = --exec ]; then   # inside the unit: --exec <wt> <sha> <log> <suite>
  wt="$2"; sha="$3"; log="$4"; suite="$5"
  tmp="$(mktemp -p "$TMP_ROOT" hpld-body.XXXXXX)"
  rc=0; (cd "$wt" && "$WMV" "$suite") >"$tmp" 2>&1 || rc=$?
  head_now="$("$GIT" -C "$wt" rev-parse HEAD 2>/dev/null || echo unknown)"
  dirty=0; [ -z "$("$GIT" -C "$wt" status --porcelain 2>/dev/null)" ] || dirty=1
  { echo "HPLD-VERIFY COMMIT=$sha HEAD=$head_now DIRTY=$dirty EXIT=$rc HOST=$(hostname)"; cat "$tmp"; } >"$tmp.log"
  [ ! -e "$log" ] || die 3 "log $log appeared during the run; refusing to overwrite"
  mv -n "$tmp.log" "$log"; rm -f "$tmp"
  case "$wt" in "$WT_ROOT"/?*) rm -rf "$wt" ;; esac
  exit 0
fi

[ $# -ge 3 ] || die 2 "usage: hpld-remote-verify.sh <owner/name> <pr> <sha40> [--suite CMD]"
repo="$1"; pr="$2"; sha="$3"; shift 3
suite="uv run pytest -q -p no:cacheprovider"
[ "${1:-}" != --suite ] || { suite="${2:?--suite needs a command}"; }
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be a number"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die 2 "sha must be 40 lowercase hex"
case "$suite" in *$'\n'*) die 2 "suite must be one line" ;; esac
unit="hpld-verify-${repo##*/}-$pr-${sha:0:12}"; log="$LOGS/$unit.log"
echo "UNIT=$unit"; echo "LOG=$log"
mkdir -p "$WT_ROOT" "$TMP_ROOT" "$LOGS"
[ ! -e "$log" ] || die 3 "log path $log already exists; write-once"
wt="$WT_ROOT/$unit"; [ ! -e "$wt" ] || die 3 "worktree $wt already exists"
"$GIT" init -q "$wt"
"$GIT" -C "$wt" fetch -q "$GIT_BASE$repo.git" "refs/pull/$pr/head"
ref="$("$GIT" -C "$wt" rev-parse FETCH_HEAD)"
[ "$ref" = "$sha" ] || { rm -rf "$wt"; die 4 "refs/pull/$pr/head is $ref, not $sha"; }
"$GIT" -C "$wt" checkout -q --detach "$sha"
"$SDRUN" --user --unit="$unit" -p MemoryMax="$MEMMAX" --setenv=TMPDIR="$TMP_ROOT" --setenv=HPLD_SUITE_TMP="$TMP_ROOT" --setenv=HPLD_SUITE_WT="$WT_ROOT" \
  "$(readlink -f "${BASH_SOURCE[0]}")" --exec "$wt" "$sha" "$log" "$suite"
