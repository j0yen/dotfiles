#!/usr/bin/env bash
# r7-gate-leg.sh [--dry-run] <sdgate|dfgate|aggate> <pr> <head40>: the one launcher for exact-head gate legs on ryzen7 (A1299/W11, Hermes 11-10 continuation).
# PREMISE: a gate leg runs a full suite whose peak is unknown in advance; a finite MemoryMax/TasksMax killed or starved legs (r7-sdgate-71 15 GB / 2000 tasks, r7-dfgate-386 5 GB / 32432 tasks).
# So the unit is created with MemoryMax=infinity TasksMax=infinity RuntimeMaxSec=infinity (same posture as aide-verifier r7 units, A1483) and no caller can pass a finite cap.
# EXPIRES: 2026-12-10 (re-read the premise then).
set -uo pipefail
DRY=; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
kind=${1:?usage: r7-gate-leg.sh [--dry-run] <sdgate|dfgate|aggate> <pr> <head40>}; pr=${2:?pr}; head=${3:?head40}
case "$kind" in sdgate|dfgate|aggate) ;; *) echo "r7-gate-leg: kind must be sdgate|dfgate|aggate" >&2; exit 2;; esac
case "$pr" in ''|*[!0-9]*) echo "r7-gate-leg: pr must be digits" >&2; exit 2;; esac
printf '%s' "$head" | grep -Eq '^[0-9a-f]{40}$' || { echo "r7-gate-leg: head must be 40 hex" >&2; exit 2; }
unit=r7-$kind-$pr
remote="systemd-run --user --unit=$unit --collect -p MemoryMax=infinity -p TasksMax=infinity -p RuntimeMaxSec=infinity nice -n 10 bash -c '/home/jsy/.local/state/r7-$kind.sh $pr $head > /home/jsy/.local/state/$unit.out 2>&1'"
if [ -n "$DRY" ]; then echo "$remote"; exit 0; fi
exec ssh -o BatchMode=yes ryzen7 "$remote"
