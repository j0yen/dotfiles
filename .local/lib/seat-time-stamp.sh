# seat-time-stamp.sh: shared helper for seat-event.sh and seat-ask.sh (controller correction row d335: seats typed their own
# time labels such as "rb 6:1x AM:" into asks and replies, and mislabelled them). Source it; it defines functions only.
#
# RULE: the helper stamps the label itself; a reply never carries a typed time.
#   stamp = "<SOURCE> <H:MM AM/PM>" from the local clock (`date`), SOURCE = $EVENT_SOURCE, else $WM_SEAT, else the caller's comm.
#   A leading typed label (seat name + clock with digits or x placeholders + optional AM/PM + optional "re <something>" + optional colon)
#   is STRIPPED and the real stamp prepended; the "re ..." part is kept after the stamp:
#       "rb 6:1x AM: body"                    -> "aide 6:41 AM: body"
#       "r7 2:19 AM re ctl 2:1x regrade: body" -> "r7 2:20 AM re ctl 2:1x regrade: body"
#       "plain body"                          -> "aide 6:41 AM: plain body"
#   A label in the MIDDLE of the text is untouched. NOT idempotent by design: a line that already looks stamped
#   ("aide 6:41 AM: ...", exactly what this function emits) is indistinguishable from a typed REAL time, which may be wrong, so any
#   leading label is always replaced and re-stamped. Callers stamp once, at the edge (the script that receives argv), never in a chain.
# Test clock: SEAT_STAMP_NOW="<H:MM AM/PM>" is honoured ONLY when SEAT_TICK_SELFTEST=1 (the scripts' selftests export it).
#
# API (no subshell, results in globals so counters can be bumped by the caller):
#   seat_stamp_source                -> prints the source token (no '|', trimmed; "unknown" if nothing)
#   seat_stamp_parse <text>          -> sets SSP_RE (the "re ..." part, trimmed, may be empty), SSP_BODY (text without the label), SSP_TYPED (1 if a label was stripped)
#   seat_stamp_apply <source> <text> -> sets SEAT_STAMPED (the stamped line) and SSP_TYPED
#   seat_stamp_bump <json> <key>     -> +1 on a counter in a <seat>-events.json style file (tmp+mv, caller holds the lock)

_SSP_WS='[[:space:]]'
_SSP_RE="^${_SSP_WS}*[A-Za-z0-9_-]+${_SSP_WS}+[0-9]{1,2}:[0-9x]{2}${_SSP_WS}*([AaPp][Mm])?${_SSP_WS}*((re${_SSP_WS}+(([^:]|:[0-9x]{2})*)):|:)?${_SSP_WS}*"

seat_stamp_source() {
  local s="${EVENT_SOURCE:-${WM_SEAT:-$(ps -o comm= -p "$PPID" 2>/dev/null)}}"
  s="$(printf '%s' "${s:-unknown}" | tr -d '|\n' | sed -E 's/^ +//; s/ +$//')"
  printf '%s' "${s:-unknown}"
}

seat_stamp_parse() {
  local t="$1" re
  SSP_RE=""; SSP_BODY="$t"; SSP_TYPED=0
  if [[ "$t" =~ $_SSP_RE ]]; then
    SSP_TYPED=1
    re="${BASH_REMATCH[3]}"
    SSP_BODY="${t:${#BASH_REMATCH[0]}}"
    # "re ctl 2:1x regrade" (everything between the clock and the colon that ends the label), trailing blanks trimmed
    re="${re%"${re##*[![:space:]]}"}"
    SSP_RE="$re"
  fi
}

seat_stamp_apply() {
  local src="$1" now
  if [ "${SEAT_TICK_SELFTEST:-}" = 1 ] && [ -n "${SEAT_STAMP_NOW:-}" ]; then now="$SEAT_STAMP_NOW"; else now="$(LC_ALL=C date '+%-I:%M %p')"; fi
  seat_stamp_parse "$2"
  SEAT_STAMPED="$src $now${SSP_RE:+ $SSP_RE}:${SSP_BODY:+ $SSP_BODY}"
}

seat_stamp_bump() {
  local json="$1" key="$2" tmp
  tmp="$(mktemp "$(dirname "$json")/.stampcnt.XXXXXX")" || return 1
  jq --arg k "$key" '({stamped:0,typed_label_replaced:0} + (. // {})) | .[$k] += 1' "$json" >"$tmp" 2>/dev/null \
    || jq -n --arg k "$key" '{stamped:0,typed_label_replaced:0} | .[$k] += 1' >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$json"
}
