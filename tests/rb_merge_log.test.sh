#!/usr/bin/env bash
# rb-merge.sh writes one log per call under RB_MERGE_LOG_DIR (a merge-done row cites it).
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf -- "${T:?}"' EXIT
RB_MERGE_LOG_DIR="$T/logs" bash "$here/rb_merge_wrapper.test.sh" >/dev/null 2>&1 || { echo "not ok - wrapper test failed"; exit 1; }
n=$(ls "$T/logs"/rb-merge-*.log 2>/dev/null | wc -l)
[ "$n" -ge 1 ] || { echo "not ok - no rb-merge log written"; exit 1; }
grep -q '^rb-merge.sh v=' "$(ls "$T/logs"/rb-merge-*.log | head -1)" || { echo "not ok - log has no header line"; exit 1; }
echo "ok - rb-merge: $n log(s) written under RB_MERGE_LOG_DIR"
