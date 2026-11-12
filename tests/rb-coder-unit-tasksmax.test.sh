#!/usr/bin/env bash
# rb-coder-unit-tasksmax.test.sh - every line that creates an rb-coder unit passes TasksMax=infinity at creation and no Memory caps
# (ctl 1:51 PM 11-12, A1570/A1304: a transient unit otherwise starts on the user default 33183 until rb-coder-memcap.sh lifts it from inside).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); f=0; n=0
for s in rb-run-coder.sh rb-coder-launch.sh; do
  while IFS= read -r l; do
    n=$((n+1))
    [[ $l == *'-p TasksMax=infinity'* ]] || { echo "FAIL: $s no TasksMax=infinity: $l"; f=1; }
    [[ $l == *MemoryMax=* || $l == *MemoryHigh=* ]] && { echo "FAIL: $s passes a Memory cap: $l"; f=1; }
  done < <(grep -E '^[^#]*systemd-run --user --unit' "$here/.local/bin/$s")
done
[ "$n" -ge 2 ] || { echo "FAIL: expected >= 2 unit-creating lines, found $n"; f=1; }
[ $f -eq 0 ] && echo "PASS rb-coder-unit-tasksmax $n lines"; exit $f
