#!/usr/bin/env bash
# A1307: `ctl-event-bridge.sh ack` writes the handled receipt that event ledger rows use as their done-check
# (test -e $RT_DIR/handled/<id>). Temp HOME and RT_DIR only.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
B="$root/.local/bin/ctl-event-bridge.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
f=0; chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
mkdir -p "$T/br/queue" "$T/rt"
for id in e1 e2; do echo "{\"id\":\"$id\",\"event\":{\"event\":\"inbox\"},\"created\":1,\"attempts\":0,\"last_delivery\":0}" > "$T/br/queue/$id.json"; done
[ ! -d "$T/rt/handled" ]; chk "handled/ absent before any ack" $?
run() { env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" RT_DIR="$T/rt" bash "$B" "$@"; }
run ack e1 >/dev/null; chk "ack <id> exits 0" $?
[ -e "$T/rt/handled/e1" ] && [ ! -e "$T/rt/handled/e2" ]; chk "ack <id> writes only that receipt (handled/ created)" $?
run ack --all >/dev/null
[ -e "$T/rt/handled/e2" ]; chk "ack --all writes the receipt for the remaining id" $?
[ -z "$(ls -A "$T/rt/handled" | grep '^\.')" ]; chk "no temp files left behind" $?
run ack nope >/dev/null 2>&1; [ $? = 1 ] && [ ! -e "$T/rt/handled/nope" ]; chk "unknown id: exit 1, no receipt" $?
echo "ctl-event-bridge-handled test: $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
