#!/usr/bin/env bash
# aide-lanes step 4: seat-event.sh aide:<lane> addressing. Temp SEATS_TABLE + EVENTS_DIR + HOME; nothing live is touched.
set -u
# capability probe (first executable block): no systemd user bus -> SKIP (exit 77, counted as skip= by tests/run.sh), never a pass
for _p in "systemctl --user show-environment" "systemd-run --user --quiet true"; do
  $_p >/dev/null 2>&1 || { _rc=$?; echo "SKIP $(basename "$0"): no systemd user bus (probe '$_p' rc=$_rc)"; exit 77; }
done
SE="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/seat-event.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
export HOME="$T/home" EVENTS_DIR="$T/ev" SEATS_TABLE="$T/seats.tsv" EVENT_SOURCE=tester; mkdir -p "$HOME"
printf '# t\n' >"$SEATS_TABLE"
"$SE" --inbox-row aide >>"$SEATS_TABLE"
row="$("$SE" --inbox-row aide:build)"
[ "$row" = "$(printf 'aide:build\tinbox\t-\t0\t0\t-\t-')" ] && ok "--inbox-row aide:build prints the tab row" || bad "inbox-row output: $row"
"$SE" --inbox-row 'bad name' >/dev/null 2>&1; [ $? = 64 ] && ok "--inbox-row still refuses a bad name" || bad "bad name accepted"
"$SE" --inbox-row aide:build >>"$SEATS_TABLE"
"$SE" aide:nope "x" >/dev/null 2>&1; [ $? = 64 ] && ok "aide:nope (no row): exit 64" || bad "unknown lane"
"$SE" aide:build "hello" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(grep -c 'hello' "$EVENTS_DIR/aide-build-events.log")" = 1 ] && [ ! -e "$EVENTS_DIR/aide-events.log" ] && [ ! -e "$EVENTS_DIR/aide:build-events.log" ] && ok "aide:build appends one line to aide-build-events.log, nothing to aide-events.log" || bad "lane append rc=$rc: $(ls "$EVENTS_DIR")"
[ -f "$EVENTS_DIR/aide-build-events.json" ] && [ "$(jq -r .inbox_only "$EVENTS_DIR/aide-build-events.json")" = 1 ] && ok "lane counters in aide-build-events.json (inbox_only=1, never woken)" || bad "lane json"
"$SE" aide "main hello" >/dev/null 2>&1
[ "$(grep -c 'main hello' "$EVENTS_DIR/aide-events.log")" = 1 ] && ! grep -q 'main hello' "$EVENTS_DIR/aide-build-events.log" && ok "aide appends to aide-events.log only" || bad "main append"
out="$("$SE" --selftest 2>&1)"; [ $? = 0 ] && ok "seat-event.sh --selftest" || bad "selftest: $(printf '%s' "$out" | grep FAIL)"
exit $fail
