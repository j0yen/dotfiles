#!/usr/bin/env bash
# tests/hetzner-guard-carbon.test.sh: hermetic test of .local/bin/hetzner-fixed-fleet-guard-carbon.sh (A44). Stub curl on PATH, throwaway state, no API, no real token.
set -u
here=$(cd "$(dirname "$0")" && pwd)
G="$here/../.local/bin/hetzner-fixed-fleet-guard-carbon.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/hzg-test.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
fail=0; n=0
ok() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
mkdir -p "$BASE/bin"
cat > "$BASE/bin/curl" <<'STUB'
#!/bin/bash
case " $* " in
*" DELETE "*) printf '%s\n' "$*" >> "$STUB_DIR/deletes"; printf '200' ;;
*) [ -e "$STUB_DIR/fail" ] && exit 22
   printf '%s' '{"servers":[{"id":1,"name":"hub","server_type":{"name":"cx"}},{"id":2,"name":"orch","server_type":{"name":"cx"}},{"id":3,"name":"mcphost-1","server_type":{"name":"cx"}},{"id":99,"name":"leased-99","server_type":{"name":"cx"}}]}' ;;
esac
STUB
chmod +x "$BASE/bin/curl"
printf 'PERMANENT HETZNER BOXES ONLY\n' > "$BASE/claude.md"; printf 'dummy' > "$BASE/tok"
nenv=0
mk() { nenv=$((nenv+1)); R="$BASE/e$nenv"; mkdir -p "$R"; : > "$R/deletes"; }
run() { env -i HOME="$R" PATH="$BASE/bin:$PATH" STUB_DIR="$R" HZG_STATE="$R/s" HZG_TOKEN="${TOK:-$BASE/tok}" HZG_PREMISE_FILE="${PF:-$BASE/claude.md}" \
  WP_LIB="$here/../.local/lib/watcher-premise.sh" WP_STATE="$R/wp" WP_DECIDE_BIN=none-here ${EXP:+HZG_EXPIRES=$EXP} bash "$G" "$@" 2>&1; }

mk; out=$(run); rc=$?
[ $rc = 0 ] && [ "$(wc -l < "$R/deletes")" = 1 ] && grep -q '/v1/servers/99$' "$R/deletes" && ! grep -qE '/v1/servers/[123]( |$)' "$R/deletes"; ok "deletes only the non-fleet server" $?
ls "$R"/wp/outbox-*.jsonl >/dev/null 2>&1; ok "decision outbox row written for the delete" $?
run --staleness >/dev/null; ok "staleness ok right after a good run" $?

mk; PF="$BASE/missing.md" run >/dev/null; [ "$(wc -l < "$R/deletes")" = 1 ]; ok "premise UNKNOWN (unreadable file) stays armed per wp lib: delete proceeds" $?
mk; printf 'nothing here\n' > "$R/c.md"; PF="$R/c.md" run >/dev/null; [ "$(wc -l < "$R/deletes")" = 0 ]; ok "premise GONE: no delete" $?
mk; EXP=2020-01-01T00:00:00 run >/dev/null; [ "$(wc -l < "$R/deletes")" = 0 ]; ok "expired premise: no delete" $?
mk; : > "$R/fail"; run >/dev/null; rc=$?; [ $rc != 0 ] && [ "$(wc -l < "$R/deletes")" = 0 ]; ok "list failure: rc!=0 and no delete" $?
mk; TOK="$R/none" run >/dev/null; rc=$?; [ $rc = 0 ] && [ "$(wc -l < "$R/deletes")" = 0 ]; ok "no token: rc 0, no delete" $?
out=$(run --staleness); rc=$?; [ $rc = 1 ] && printf '%s' "$out" | grep -q '"hetzner_guard_carbon_alarm":true' && printf '%s' "$out" | grep -q '"status":"no-token"'; ok "no token -> staleness alarm true, status no-token ($out)" $?
mk; run >/dev/null; echo $(( $(date +%s) - 3600 )) > "$R/s/last_ok"; run --staleness >/dev/null; [ $? = 1 ]; ok "old last_ok -> staleness alarm" $?
mk; run --staleness >/dev/null; [ $? = 1 ]; ok "never ran -> staleness alarm" $?
bash "$G" --selftest | grep -q 'SELFTEST ok'; ok "--selftest" $?
u="$here/../.config/systemd/user"; grep -q 'hetzner-fixed-fleet-guard-carbon.sh' "$u/hetzner-fixed-fleet-guard.service" && grep -q 'OnUnitActiveSec=5min' "$u/hetzner-fixed-fleet-guard.timer" && grep -q 'WantedBy=timers.target' "$u/hetzner-fixed-fleet-guard.timer"; ok "units wired" $?
echo "hetzner-guard-carbon: $((n-fail))/$n passed"; [ "$fail" = 0 ]
