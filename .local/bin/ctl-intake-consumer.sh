#!/usr/bin/env bash
# ctl-intake-consumer.sh once   (A1303 W8: production drain of the canonical intake wake outbox)
# Reads `wm-decide intake pending --consumer ctl`, delivers each wake to the ctl seat through seat-event.sh, and ACKs a wake
# only after delivery returned 0. A failed delivery leaves the wake un-ACKed, so the next run replays it. It never claims,
# starts or verifies a task: the ctl seat (or its worker) does that through the intake API. Exit 66 = ledger unavailable.
# Env (tests): ICON_NOTIFY (default seat-event.sh) ICON_WM (default wm-decide) ICON_CONSUMER (default ctl)
set -uo pipefail
WM="${ICON_WM:-wm-decide}"; NOTIFY="${ICON_NOTIFY:-$HOME/.local/bin/seat-event.sh}"; CONS="${ICON_CONSUMER:-ctl}"
[ "${1:-once}" = once ] || { echo "usage: $0 once" >&2; exit 64; }
out="$("$WM" intake pending --consumer "$CONS" 2>&1)"; rc=$?
[ $rc -eq 0 ] || { echo "ledger unavailable rc=$rc: ${out:0:200}" >&2; exit 66; }
lines="$(printf '%s' "$out" | python3 -I -c 'import json,sys
for w in json.load(sys.stdin): print(w["seq"], w["kind"], w["ask_id"], w.get("rev"))')" || { echo "unparseable pending output" >&2; exit 65; }
ST="${ICON_STATE:-$HOME/.cache/aide/intake-consumer}"; REMIND="${ICON_REMIND_S:-900}"; mkdir -p "$ST"
n=0; bad=0
while read -r seq kind ask rev; do
  [ -n "${seq:-}" ] || continue
  # ACK is refused by the ledger until the ask has a durable claim or outcome, so a wake stays pending until the ctl seat
  # claims it: deliver once, remind every REMIND seconds, and try the ACK each run (it lands as soon as the claim exists).
  f="$ST/$CONS.$seq"; now=$(date +%s)
  if [ ! -e "$f" ] || [ $((now - $(cat "$f" 2>/dev/null || echo 0))) -ge "$REMIND" ]; then
    if "$NOTIFY" aide "intake wake seq=$seq kind=$kind ask=$ask rev=$rev: claim via wm-decide intake claim --ask $ask --expect-rev $rev" --due "$(date -d '+20 min' +%H:%M)" --done-check "wm-asks asks query --ids $ask --json" >/dev/null 2>&1; then
      echo "$now" > "$f"; n=$((n+1))
    else bad=$((bad+1)); continue; fi
  fi
  "$WM" intake ack --consumer "$CONS" --seq "$seq" >/dev/null 2>&1 && rm -f "$f"
done <<<"$lines"
echo "delivered=$n failed=$bad"; [ $bad -eq 0 ]
