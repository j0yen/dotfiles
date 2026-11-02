#!/usr/bin/env bash
# tests/watcher-premise-cli.test.sh -- .local/bin/watcher-premise.sh CLI: gate honours premise + expiry, status prints the line, selftest passes.
# Run from the repo root:  bash tests/watcher-premise-cli.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cli="$here/../.local/bin/watcher-premise.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WP_STATE="$T/state" HOME="$T/home"; mkdir -p "$HOME"
fail=0
chk() { if [ "$2" = 0 ]; then echo "ok - watcher-premise-cli: $1"; else echo "FAIL - watcher-premise-cli: $1"; fail=1; fi; }
future=$(date -d '+1 hour' -Is); past=$(date -d '-1 hour' -Is)

bash "$cli" gate t-hold 'exit 0' "$future" 2>/dev/null; chk "premise holds, not expired -> rc 0" $?
bash "$cli" gate t-gone 'exit 1' "$future" 2>/dev/null; [ $? = 1 ]; chk "premise gone -> rc 1" $?
bash "$cli" gate t-exp 'exit 0' "$past" 2>/dev/null; [ $? = 1 ]; chk "past expiry disarms -> rc 1" $?
bash "$cli" status t-exp | grep -q 'expired'; chk "status shows defect expired" $?
bash "$cli" status t-hold | grep -q "HOLDS"; chk "status shows HOLDS" $?
bash "$cli" status nope 2>/dev/null; [ $? = 1 ]; chk "status of unknown watcher -> rc 1" $?
bash "$cli" gate 'bad name' 'exit 0' "$future" 2>/dev/null; [ $? = 2 ]; chk "invalid name -> rc 2" $?
bash "$cli" gate t-x 'exit 0' notadate 2>/dev/null; [ $? = 2 ]; chk "invalid expiry -> rc 2" $?
bash "$cli" --selftest | tail -1 | grep -q '^selftest ok'; chk "--selftest passes" $?
exit $fail
