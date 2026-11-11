#!/usr/bin/env bash
# named test: ctl-event-wait.sh treats the dedicated source ctl-intake-consumer as actionable (A1303); `bash` and look-alikes stay informational
set -u
W="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/ctl-event-wait.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$T/wake"; chmod +x "$T/wake"
printf 'id\tasked\towner\tdue\tdone_re\tcheck\twhat\n' > "$T/oa"
f=0
txt='intake wake seq=9 kind=task_ready ask=A9 rev=1: claim via wm-decide intake claim --ask A9 --expect-rev 1'
ew() { env -i HOME="$T" PATH="$PATH" EW_DIR="$T/ew" EVENTS_DIR="$T/ev" OPEN_ASKS="$T/oa" HOLD_FILE="$T/hold" AV_DIR="$T/av" FEEDBACK_DIR="$T/fb" STATUS_JSON="$T/sj" AIDE_WAKE_BIN="$T/wake" bash "$W" wait --max-sec 2 --poll 1; }
try() { # source want(inbox|timeout)
  rm -rf "$T/ew" "$T/ev"; mkdir -p "$T/ew" "$T/ev" "$T/av" "$T/fb"
  printf 't | ctl | own receipt\n' > "$T/ev/aide-events.log"
  ew >/dev/null   # baseline: the waiter starts at the current end of the log
  printf '2026-11-10T11:24:00 | %s | %s\n' "$1" "$txt" >> "$T/ev/aide-events.log"
  out="$(ew)"
  if printf '%s' "$out" | grep -q "\"event\":\"$2\""; then echo "PASS source=$1 -> $2"; else echo "FAIL source=$1 want $2 got: $out"; f=1; fi
}
try ctl-intake-consumer inbox
try bash timeout
try ctl-intake-consumerX timeout
try xctl-intake-consumer timeout
[ $f = 0 ] && echo "OK ctl-event-wait-source"; exit $f
