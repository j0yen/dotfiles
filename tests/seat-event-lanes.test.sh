#!/usr/bin/env bash
# aide-lanes step 4: seat-event.sh aide:<lane> addressing. Temp SEATS_TABLE + EVENTS_DIR + HOME; nothing live is touched.
set -u
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
"$SE" aide:build "hello" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(grep -c 'hello' "$EVENTS_DIR/aide-build-events.log")" = 1 ] && [ ! -e "$EVENTS_DIR/aide-events.log" ] && [ ! -e "$EVENTS_DIR/aide:build-events.log" ] && ok "aide:build appends one line to aide-build-events.log, nothing to aide-events.log" || bad "lane append rc=$rc: $(ls "$EVENTS_DIR")"
[ -f "$EVENTS_DIR/aide-build-events.json" ] && [ "$(jq -r .inbox_only "$EVENTS_DIR/aide-build-events.json")" = 1 ] && ok "lane counters in aide-build-events.json (inbox_only=1, never woken)" || bad "lane json"
"$SE" aide "main hello" >/dev/null 2>&1
[ "$(grep -c 'main hello' "$EVENTS_DIR/aide-events.log")" = 1 ] && ! grep -q 'main hello' "$EVENTS_DIR/aide-build-events.log" && ok "aide appends to aide-events.log only" || bad "main append"
# --- self-registering lanes (no seats.tsv row) ---
"$SE" aide:nope "selfreg hello" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && grep -q 'selfreg hello' "$EVENTS_DIR/aide-nope-events.log" && [ "$(jq -r .inbox_only "$EVENTS_DIR/aide-nope-events.json")" = 1 ] && ok "unregistered valid lane aide:nope delivers to aide-nope-events.log (inbox_only, never woken)" || bad "selfreg rc=$rc"
for n in 'aide:Build' 'aide:abcdefghijklmnopq' 'aide:a/b' 'aide:..' 'aide:' 'aide:1x' 'aide:a_b' 'aide:-x'; do
  err="$("$SE" "$n" "x" 2>&1 >/dev/null)"; rc=$?
  [ $rc = 64 ] && printf '%s' "$err" | grep -q 'unknown seat' && ok "bad lane '$n': exit 64 with message" || bad "bad lane '$n' rc=$rc"
done
[ -z "$(ls "$EVENTS_DIR" | grep -E '^aide-(Build|abc|1x|a_b|-x)')" ] && ok "bad lanes wrote no files" || bad "bad lane left files"
# explicit row wins: a non-inbox row for aide:wake is NOT treated as inbox (would go down the wake path); dry-run prints the spawn
printf 'aide:wake\tseat\tsid-x\t5\t60\tgoal\t-\n' >>"$SEATS_TABLE"
out="$(SEAT_EVENT_DRY=1 "$SE" aide:wake "row wins" 2>&1)"; [ ! -e "$EVENTS_DIR/aide-wake-events.json" ] || [ "$(jq -r '.inbox_only // 0' "$EVENTS_DIR/aide-wake-events.json")" = 0 ] && ok "explicit non-inbox row still wins over self-registration (inbox_only not counted)" || bad "explicit row lost: $out"
# main / bare aide: byte-identical to origin/main on a fixture; aide:main with no row still refuses
mkdir -p "$T/bin" "$T/lib"; OM="$T/bin/seat-event.sh"; git -C "$(dirname "$SE")" show origin/main:.local/bin/seat-event.sh >"$OM" 2>/dev/null && chmod +x "$OM"
if [ -x "$OM" ]; then
  cp "$(dirname "$SE")/../lib/seat-time-stamp.sh" "$T/lib/"
  for who in new old; do
    X="$SE"; [ $who = old ] && X="$OM"
    d="$T/fx-$who"; mkdir -p "$d"
    printf '# t\n' >"$d/seats.tsv"; "$X" --inbox-row aide >>"$d/seats.tsv"; "$X" --inbox-row aide:main >>"$d/seats.tsv"
    ( export EVENTS_DIR="$d/ev" SEATS_TABLE="$d/seats.tsv" SEAT_TICK_SELFTEST=1 SEAT_STAMP_NOW="9:07 PM" SEAT_STAMP_LIB="$T/lib/seat-time-stamp.sh"
      "$X" aide "bare one" >"$d/o1" 2>&1; echo $? >>"$d/o1"; "$X" aide:main "main one" >>"$d/o1" 2>&1; echo $? >>"$d/o1"
      printf '# t\n' >"$d/seats2.tsv"; SEATS_TABLE="$d/seats2.tsv" "$X" aide:main "no row" >>"$d/o1" 2>&1; echo $? >>"$d/o1"
      SEATS_TABLE="$d/seats2.tsv" "$X" aide "no row" >>"$d/o1" 2>&1; echo $? >>"$d/o1" )
    sed -i "s#$d#FX#g" "$d/o1"
  done
  strip() { sed -E "s/^[^|]+\\| //" "$1"; }   # first column is a wall-clock ts
  cmp -s "$T/fx-new/o1" "$T/fx-old/o1" && [ "$(strip "$T/fx-new/ev/aide-events.log")" = "$(strip "$T/fx-old/ev/aide-events.log")" ] && [ "$(strip "$T/fx-new/ev/aide-main-events.log")" = "$(strip "$T/fx-old/ev/aide-main-events.log")" ] && [ -s "$T/fx-new/ev/aide-events.log" ] && ok "aide / aide:main output + logs byte-identical to origin/main (incl. no-row refusal)" || { bad "main/bare differ from origin/main"; diff "$T/fx-new/o1" "$T/fx-old/o1"; }
else bad "origin/main seat-event.sh unavailable for the byte-identity check"; fi
out="$("$SE" --selftest 2>&1)"; [ $? = 0 ] && ok "seat-event.sh --selftest" || bad "selftest: $(printf '%s' "$out" | grep FAIL)"
exit $fail
