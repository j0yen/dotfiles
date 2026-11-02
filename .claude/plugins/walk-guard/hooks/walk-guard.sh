#!/usr/bin/env bash
# walk-guard.sh -- PreToolUse(Bash) hook: refuse an unbounded filesystem walk (grep -r, rg, find, du,
# ls -R) of a guarded root (/mnt/data, /mnt/ssd, ~) on a build host unless it runs under
# `ionice -c3 nice -n19 timeout <= 600`. Everything it knows comes from ../contracts/walk-guard.json;
# the engine is walk_guard.py. 10-22: three orphan walks read 12 GB and held the IO queue.
#
#   walk-guard.sh                    hook mode (Bash tool JSON on stdin): exit 0 pass, exit 2 refuse
#   walk-guard.sh --selftest [--write-state]   run the case table; --write-state writes
#                                    ~/.local/state/watchers/_walkhook.json (fleet-sync post-apply)
#   walk-guard.sh --pgrep-pattern    ERE for `pgrep -af` generated from the contract
#   walk-guard.sh --template         the generic refusal template
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
engine="$here/walk_guard.py"
export PYTHONDONTWRITEBYTECODE=1

case "${1:-}" in
  --selftest)       shift; exec python3 "$engine" selftest "$@" ;;
  --pgrep-pattern)  exec python3 "$engine" pgrep-pattern ;;
  --template)       exec python3 "$engine" template ;;
  "")               ;;
  *)                echo "usage: walk-guard.sh [--selftest [--write-state]|--pgrep-pattern|--template]" >&2; exit 64 ;;
esac

# Fallback when the engine itself breaks: the ssh hosts it would have guarded. Allowlisted copy of
# contract hosts.ssh_targets; tests/walkguard_drift.test.sh fails if the two differ.
FALLBACK_SSH_HOSTS="redbaron ryzen7"

input="$(cat)"
rc=0
out="$(printf '%s' "$input" | python3 "$engine" hook 2>"${TMPDIR:-/tmp}/.walk-guard-err.$$")" || rc=$?
err="$(cat "${TMPDIR:-/tmp}/.walk-guard-err.$$" 2>/dev/null || true)"
rm -f "${TMPDIR:-/tmp}/.walk-guard-err.$$"

case "$rc" in
  0) [[ -n "$out" ]] && printf '%s\n' "$out"
     [[ -n "$err" ]] && printf '%s\n' "$err" >&2
     exit 0 ;;
  2) printf '%s\n' "$err" >&2; exit 2 ;;
  *) # internal error: block only a command that names a guarded ssh host
     alt="${FALLBACK_SSH_HOSTS// /|}"
     if printf '%s' "$input" | grep -Eq "ssh[^|;&]*[ @]($alt)\\b"; then
       echo "walk-hook internal error (engine exit $rc): refusing an ssh to a build host because the walk guard cannot vet it. ${err}" >&2
       exit 2
     fi
     exit 0 ;;
esac
