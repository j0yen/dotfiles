#!/usr/bin/env bash
# orch-mcphost-test.sh: refusals, capped invocation, chain yield, rc passthrough. Every host tool is faked.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
S=$here/.local/bin/orch-mcphost-test.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home; mkdir -p "$HOME" "$T/bin"
fail=0; ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; fail=1; }
cat >"$T/bin/fake-nextest" <<'F'
#!/bin/bash
echo "nextest $*"; echo "     Summary [0.1s] 3 tests run: 3 passed"; exit "$(cat "$HOME/rc" 2>/dev/null || echo 0)"
F
cat >"$T/bin/fake-sdrun" <<'F'
#!/bin/bash
echo "sdrun $*" >> "$HOME/sd.log"
while [ "${1:-}" != nice ] && [ $# -gt 0 ]; do shift; done
shift 3; [ "$1" = ionice ] && shift 2
exec "$@"
F
chmod +x "$T/bin/"*
echo x >"$T/a.tar.zst"
export ORCH_MCT_ALLOW_HOST=1 ORCH_MCT_NEXTEST=$T/bin/fake-nextest ORCH_MCT_SYSTEMD_RUN=$T/bin/fake-sdrun ORCH_MCT_BUSY_CMD=false ORCH_MCT_POLL_S=1

"$S" "$T/a.txt" >/dev/null 2>&1; [ $? = 2 ] && ok refuses-non-archive || bad refuses-non-archive
"$S" "$T/missing.tar.zst" >/dev/null 2>&1; [ $? = 2 ] && ok refuses-missing || bad refuses-missing
"$S" "$T/a.tar.zst" --sha 'zz;' >/dev/null 2>&1; [ $? = 2 ] && ok refuses-bad-sha || bad refuses-bad-sha
ORCH_MCT_ALLOW_HOST= "$S" "$T/a.tar.zst" >/dev/null 2>&1; [ $? = 2 ] && ok refuses-non-orch || bad refuses-non-orch

out=$("$S" "$T/a.tar.zst" --sha abc123 --filter 'test(foo)'); rc=$?
log=$HOME/.cache/mcphost-test/abc123/test.log
[ $rc = 0 ] && ok rc0 || bad rc0
grep -q -- '--archive-file' "$log" && grep -q -- "-E test(foo)" "$log" && ok nextest-args || bad nextest-args
grep -q 'MemoryMax=4G' "$HOME/sd.log" && grep -q 'CPUQuota=150%' "$HOME/sd.log" && grep -q 'MemorySwapMax=0' "$HOME/sd.log" && ok capped || bad capped
grep -q 'WM-VERIFY EXIT=0' "$log" && grep -q 'WM-VERIFY SHA=abc123' "$log" && grep -q 'ARCHIVE_SHA256=' "$log" && ok receipt || bad receipt

echo 100 >"$HOME/rc"; "$S" "$T/a.tar.zst" --sha def456 >/dev/null; rc=$?
[ $rc = 100 ] && grep -q 'WM-VERIFY EXIT=100' "$HOME/.cache/mcphost-test/def456/test.log" && ok rc-passthrough || bad rc-passthrough

: >"$HOME/sd.log"
ORCH_MCT_BUSY_CMD=true ORCH_MCT_YIELD_WAIT_S=2 "$S" "$T/a.tar.zst" --sha ccc111 >/dev/null 2>&1; rc=$?
[ $rc = 75 ] && [ ! -s "$HOME/sd.log" ] && ok yields-busy || bad yields-busy

echo 0 >"$HOME/rc"
# busy at first, clears after 2 s: runs
( sleep 2; touch "$T/clear" ) &
ORCH_MCT_BUSY_CMD="[ ! -e $T/clear ]" ORCH_MCT_YIELD_WAIT_S=20 "$S" "$T/a.tar.zst" --sha ddd222 >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && ok runs-after-clear || bad runs-after-clear
exit $fail
