#!/usr/bin/env bash
# StartLimitIntervalSec/StartLimitBurst belong in [Unit]; systemd ignores them in
# [Service] (r7-mon-* bells 10-22: "Unknown key ... in section [Service], ignoring").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bad=0
for f in "$root"/.config/systemd/user/*.service; do
  [ -f "$f" ] || continue
  hits=$(awk '/^\[/{s=$0} /^StartLimit(IntervalSec|Burst)=/ && s!="[Unit]"{print FILENAME":"NR": "$0}' "$f")
  if [ -n "$hits" ]; then echo "FAIL $hits"; bad=1; fi
done
[ "$bad" = 0 ] && echo "PASS unit-startlimit-in-unit-section"
exit "$bad"
