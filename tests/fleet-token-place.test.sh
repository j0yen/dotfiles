#!/usr/bin/env bash
# tests/fleet-token-place.test.sh -- fleet-token-place.sh refuses a blocked account before placing anything (ctl k1049).
# Throwaway HOME, canary token, fake ssh/systemctl on PATH that record any call; the real token file is never read.
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/home/.local/lib" "$t/home/.config/fleet-token/store" "$t/home/.local/state/fleet-token" "$t/bin"
cp "$root/.local/lib/fleet-token-lib.sh" "$t/home/.local/lib/"
for c in ssh systemctl claude; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$t" > "$t/bin/$c"; chmod +x "$t/bin/$c"; done
printf 'sk-ant-oat01-canary-tok-7f3e9a-blocked\n' > "$t/home/.config/fleet-token/store/jyen.pm"
printf 'sk-ant-oat01-canary-tok-7f3e9a-free\n' > "$t/home/.config/fleet-token/store/jyen.tech"
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$t/home/.local/state/fleet-token/blocked-until-jyen.pm"
echo "x | ts=1 account=jyen.pm until=2 until_iso=x why=weekly limit" > "$t/home/.local/state/fleet-token/blocks.log"
run() { env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t/home" bash "$root/.local/bin/fleet-token-place.sh" "$@" >"$t/out" 2>"$t/err"; }
cp "$t/home/.config/fleet-token/store/jyen.pm" "$t/tok1"
if run "$t/tok1"; then rc=0; else rc=$?; fi
[ "$rc" = 3 ] && grep -q 'REFUSED: account jyen.pm is blocked until' "$t/err" && [ ! -e "$t/calls" ] && [ ! -e "$t/home/.config/environment.d/90-claude-oauth.conf" ] && [ -e "$t/tok1" ] \
  && ok "token of a blocked account (matched by sha8): exit 3, REFUSED, no ssh/systemctl call, nothing written, file kept" || bad "blocked account by sha8 (rc=$rc)"
printf 'sk-ant-oat01-canary-tok-7f3e9a-other\n' > "$t/tok2"
if run --account jyen.pm --check-only "$t/tok2"; then rc=0; else rc=$?; fi
[ "$rc" = 3 ] && [ ! -e "$t/calls" ] && ok "--account names a blocked account: exit 3" || bad "--account blocked (rc=$rc)"
cp "$t/home/.config/fleet-token/store/jyen.tech" "$t/tok3"
if run --check-only "$t/tok3"; then rc=0; else rc=$?; fi
[ "$rc" = 0 ] && grep -q 'check-only: jyen.tech not blocked' "$t/out" && [ ! -e "$t/calls" ] && ok "unblocked account, --check-only: exit 0, nothing placed" || bad "unblocked check-only (rc=$rc)"
printf '1\n' > "$t/home/.local/state/fleet-token/blocked-until-jyen.pm"
if run --check-only "$t/tok1"; then rc=0; else rc=$?; fi
[ "$rc" = 0 ] && ok "expired block: allowed" || bad "expired block (rc=$rc)"
if run --check-only "$t/tok2"; then rc=0; else rc=$?; fi
[ "$rc" = 0 ] && grep -q 'WARN token matches no store entry' "$t/err" && ok "unknown token: WARN, not refused" || bad "unknown token (rc=$rc)"
! grep -rqF 'canary-tok-7f3e9a' "$t/out" "$t/err" && ok "no token text in stdout/stderr" || bad "token printed"
exit "$fail"
