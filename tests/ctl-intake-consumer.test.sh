#!/usr/bin/env bash
# named test: delivery acks the wake; a failing delivery leaves it pending and replays; unavailable ledger exits 66
set -u
# real prerequisite, no skip: a wm-decide that has the `intake` API (PATH, else the pinned tree staged beside the live trees)
WMB=""
for c in "${WM_DECIDE_PIN:-}" "$(command -v wm-decide 2>/dev/null)" "$HOME"/.local/share/swarm-decide/pinned-*/bin/wm-decide; do
  [ -n "$c" ] && [ -x "$c" ] && "$c" intake --help >/dev/null 2>&1 && { WMB="$c"; break; }
done
[ -n "$WMB" ] || { echo "FAIL prerequisite: no wm-decide with the intake API (set WM_DECIDE_PIN or stage ~/.local/share/swarm-decide/pinned-<tag>)"; exit 1; }
wm-decide() { "$WMB" "$@"; }; export ICON_WM="$WMB"
S="$(mktemp -d)"; export WM_DECIDE_STATE="$S/state"; mkdir -p "$S/state"
E='{"source_event_id":"tg:t1","source_ref":"t","text":"x","received_at":"2026-11-10T06:40:00","request_type":"new","authorized_by":"hermes"}'
C='{"owner":"ctl","due":"2026-11-10T09:00","what":"t","check":"test -n x","depends":[]}'
wm-decide intake submit --envelope "$E" --change "$C" >/dev/null || { echo FAIL submit; exit 1; }
printf '#!/bin/sh\nexit 1\n' > "$S/fail"; printf '#!/bin/sh\necho "$@" >> %s/log\necho "$EVENT_SOURCE" >> %s/src\n' "$S" "$S" > "$S/ok"; chmod +x "$S/fail" "$S/ok"
D="$(dirname "$0")/../.local/bin/ctl-intake-consumer.sh"
export ICON_STATE="$S/st"
ICON_NOTIFY="$S/fail" "$D" once >/dev/null; [ $? -ne 0 ] || { echo FAIL fail-delivery-rc; exit 1; }
ICON_NOTIFY="$S/ok" "$D" once >/dev/null || { echo FAIL ok-delivery; exit 1; }
grep -q "kind=task_ready ask=A1" "$S/log" || { echo FAIL not-delivered; exit 1; }
[ "$(head -n1 "$S/src")" = ctl-intake-consumer ] || { echo "FAIL event-source got '$(head -n1 "$S/src")'"; exit 1; }
[ "$(wm-decide intake pending --consumer ctl | grep -c task_ready)" = 1 ] || { echo FAIL acked-before-claim; exit 1; }
ICON_NOTIFY="$S/ok" "$D" once >/dev/null; [ "$(wc -l < "$S/log")" = 1 ] || { echo FAIL duplicate-delivery; exit 1; }
wm-decide intake claim --ask A1 --worker w --expect-rev 1 --by ctl >/dev/null || { echo FAIL claim; exit 1; }
ICON_NOTIFY="$S/ok" "$D" once >/dev/null || { echo FAIL after-claim; exit 1; }
[ "$(wm-decide intake pending --consumer ctl)" = "[]" ] || { echo FAIL not-acked-after-claim; exit 1; }
: > "$S/notadir"; WM_DECIDE_STATE="$S/notadir/x" ICON_NOTIFY="$S/ok" "$D" once >/dev/null 2>&1; rc=$?
[ "$rc" = 66 ] || { echo "FAIL unavailable-ledger rc=$rc want 66"; exit 1; }
echo "OK ctl-intake-consumer (unavailable-rc=$rc)"
