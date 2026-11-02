#!/usr/bin/env bash
# event-act.sh <seat> "<line>": L2 event table (A236). Classifies one event line against gen/event-actions.json and, for a KNOWN class, executes the
# class action by code instead of waking the receiving seat's turn:
#   action route: delivers the line to the class owner's inbox with seat-event.sh (EVENT_SOURCE=event-act, SEAT_EVENT_ACT=0 so it is not classified twice),
#   then writes one kind=action row (no verdict requested unless the class is product, Fable amendment 5) to $EVENTS_DIR/event-act-actions.tsv and, when
#   EVENT_ACT_RECORD_CMD is set, calls `$EVENT_ACT_RECORD_CMD <class> <owner> <from-seat> <line>` so the DECISION row lands in the ledger.
# Owner = the class `owner`, else the first capture group of `owner_re` on the line; an owner outside the table `seats` list (a gone coder id) maps to `owner_fallback`.
# Loop guard: owner == the receiving seat -> the line is already at its owner, exit 10 (a seat turn handles it).
# Exit: 0 handled by code (caller drops the line from <seat>) / 10 unknown class or already at owner (caller delivers as before) / 64 usage / 1 table unreadable or route failed.
# Env: EVENT_ACT_TABLE (default ../../.config/fleet/gen/event-actions.json next to this script, else ~/.config/fleet/gen/event-actions.json) EVENTS_DIR
#      SEAT_EVENT_BIN EVENT_ACT_RECORD_CMD EVENT_ACT_DRY=1 (classify and print `CLASS <name> OWNER <owner>`, change nothing). `event-act.sh --classify <seat> "<line>"` = same dry print.
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")"; HERE="$(dirname "$SELF")"
DRY="${EVENT_ACT_DRY:-}"
if [ "${1:-}" = "--classify" ]; then DRY=1; shift; fi
[ $# -ge 2 ] || { echo 'usage: event-act.sh [--classify] <seat> "<line>"' >&2; exit 64; }
SEAT="$1"; shift; LINE="$*"
TABLE="${EVENT_ACT_TABLE:-}"
if [ -z "$TABLE" ]; then
  for t in "$HERE/../../.config/fleet/gen/event-actions.json" "$HOME/.config/fleet/gen/event-actions.json"; do [ -r "$t" ] && { TABLE="$t"; break; }; done
fi
[ -n "$TABLE" ] && [ -r "$TABLE" ] || { echo "event-act: table not found (EVENT_ACT_TABLE)" >&2; exit 1; }
jq -e '.classes|type=="array"' "$TABLE" >/dev/null 2>&1 || { echo "event-act: table $TABLE unparseable" >&2; exit 1; }
DIR="${EVENTS_DIR:-${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}}"

cls="" owner="" product=false action=""
while IFS=$'\t' read -r name from match fixed ownre fallback act prod; do
  [ -n "$name" ] || continue
  if [ "$from" != "-" ]; then case ",$from," in *",$SEAT,"*) ;; *) continue;; esac; fi
  [[ "$LINE" =~ $match ]] || continue
  o="$fixed"
  if [ "$o" = "-" ]; then
    o=""
    if [ "$ownre" != "-" ] && [[ "$LINE" =~ $ownre ]]; then o="${BASH_REMATCH[1]}"; fi
  fi
  [ -n "$o" ] || o="$fallback"
  [ "$o" = "-" ] && continue
  if ! jq -e --arg o "$o" '.seats|index($o)' "$TABLE" >/dev/null 2>&1; then o="$fallback"; fi
  [ "$o" = "-" ] && continue
  cls="$name"; owner="$o"; action="$act"; product="$prod"; break
done < <(jq -r '.classes[] | [.name, ((.from_seats // [])|if length==0 then "-" else join(",") end), .match, (.owner // "-"), (.owner_re // "-"), (.owner_fallback // "-"), (.action // "route"), ((.product // false)|tostring)] | @tsv' "$TABLE")

[ -n "$cls" ] || exit 10
[ "$owner" = "$SEAT" ] && exit 10
if [ -n "$DRY" ]; then echo "CLASS $cls OWNER $owner"; exit 0; fi
[ "$action" = route ] || { echo "event-act: class $cls has unknown action '$action'" >&2; exit 1; }

SE="${SEAT_EVENT_BIN:-$HERE/seat-event.sh}"
SEAT_EVENT_ACT=0 EVENT_SOURCE=event-act "$SE" "$owner" "$LINE" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] || { echo "event-act: route to $owner failed rc=$rc (class $cls)" >&2; exit 1; }

( umask 077; mkdir -p "$DIR" ) || exit 1
verdict=none; [ "$product" = true ] && verdict=requested
flat="$(printf '%s' "$LINE" | tr '\r\n\t' '   ')"
{ flock 7; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" action "$cls" "$SEAT" "$owner" "$verdict" "$flat" >>"$DIR/event-act-actions.tsv"; chmod 600 "$DIR/event-act-actions.tsv"; } 7>>"$DIR/event-act.lock"
if [ -n "${EVENT_ACT_RECORD_CMD:-}" ]; then
  $EVENT_ACT_RECORD_CMD "$cls" "$owner" "$SEAT" "$LINE" >/dev/null 2>&1 || echo "event-act: record cmd failed (class $cls); action row kept in event-act-actions.tsv" >&2
fi
exit 0
