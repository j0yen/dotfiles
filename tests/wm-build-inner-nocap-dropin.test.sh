#!/usr/bin/env bash
# wm-build-.service.d/90-get-well-no-worker-caps.conf: inner step units carry TasksMax=infinity, nothing else (A1296/W11).
set -u
D="$(cd "$(dirname "$0")/.." && pwd)/.config/systemd/user/wm-build-.service.d"
F="$D/90-get-well-no-worker-caps.conf"
fail=0; ck(){ [ "$1" = 0 ] && echo "PASS $2" || { echo "FAIL $2"; fail=1; }; }
[ -f "$F" ]; ck $? "drop-in exists"
grep -qx '\[Service\]' "$F"; ck $? "has [Service] section"
grep -qx 'TasksMax=infinity' "$F"; ck $? "TasksMax=infinity"
! grep -Eq '^TasksMax=[0-9]' "$F"; ck $? "no finite TasksMax"
! grep -Eq '^(MemoryMax|MemoryHigh|RuntimeMaxSec|CPUQuota)=' "$F"; ck $? "sets no other limit"
[ "$(grep -cvE '^(#|$|\[Service\]$)' "$F")" = 1 ]; ck $? "exactly one directive"
# systemd prefix drop-ins: <prefix>-.service.d applies to units whose name starts with <prefix>-
pre="$(basename "$D" .service.d)"
case "wm-build-inner546-a" in "$pre"*) r=0 ;; *) r=1 ;; esac; ck $r "matches wm-build-inner546-a"
case "wm-build" in "$pre"*) r=1 ;; *) r=0 ;; esac; ck $r "does not match the wm-build daemon"
exit $fail
