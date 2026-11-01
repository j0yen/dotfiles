#!/usr/bin/env bash
# slot-admit-inodes.sh [PATH] [--max PCT] - inode floor for parallel-slot admission.
# df -iP PATH use% >= max (default 70) -> "REFUSE inodes N%", exit 1; else "OK inodes N%", exit 0.
# A filesystem with no inode counts (df prints "-", e.g. btrfs) -> "OK inodes n/a", exit 0.
# Launchers call it as: slot-admit-inodes.sh || exit 75
set -u
path=/tmp
max=70
while [ $# -gt 0 ]; do
  case $1 in
    --max) [ $# -ge 2 ] || { echo "usage: $0 [PATH] [--max PCT]" >&2; exit 2; }; max=$2; shift 2 ;;
    -h|--help) echo "usage: $0 [PATH] [--max PCT]"; exit 0 ;;
    *) path=$1; shift ;;
  esac
done
case $max in ''|*[!0-9]*) echo "bad --max: $max" >&2; exit 2 ;; esac
use=$(df -iP "$path" 2>/dev/null | awk 'NR==2 {print $5}')
if [ -z "$use" ]; then echo "slot-admit-inodes: cannot read df -i for $path" >&2; exit 2; fi
if [ "$use" = "-" ]; then echo "OK inodes n/a"; exit 0; fi
pct=${use%\%}
case $pct in ''|*[!0-9]*) echo "OK inodes n/a"; exit 0 ;; esac
if [ "$pct" -ge "$max" ]; then echo "REFUSE inodes ${pct}%"; exit 1; fi
echo "OK inodes ${pct}%"
