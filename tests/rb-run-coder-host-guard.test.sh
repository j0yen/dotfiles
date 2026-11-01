#!/usr/bin/env bash
# rb-run-coder.sh refuses to start a coder session off redbaron/ryzen7 (aide A25; Joe 10-27 "Nothing should be built nor coded on carbon").
# carbon -> rc 79 with REFUSED host=carbon; redbaron/ryzen7 pass the host gate and stop at the empty-prompt gate (rc 74) inside a scratch HOME.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
R="$here/.local/bin/rb-run-coder.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
for h in carbon redbaron ryzen7 ""; do
  mkdir -p "$tmp/bin-$h"
  printf '#!/bin/sh\necho "%s"\n' "$h" > "$tmp/bin-$h/hostname"; chmod +x "$tmp/bin-$h/hostname"
  out=$(HOME="$tmp/home" PATH="$tmp/bin-$h:$PATH" bash "$R" t /dev/null 2>&1); rc=$?
  case "$h" in
    redbaron|ryzen7) want=74 ;;
    *) want=79 ;;
  esac
  if [ "$rc" = "$want" ]; then echo "ok - host '${h}' rc=$rc"; else echo "NOT OK - host '${h}' rc=$rc want $want ($out)"; fail=1; fi
  if [ "$want" = 79 ]; then
    if printf '%s\n' "$out" | grep -q "REFUSED host=${h:-unknown}"; then echo "ok - host '${h}' names itself in the refusal"; else echo "NOT OK - host '${h}' refusal text ($out)"; fail=1; fi
  fi
done
# the gate sits before the OAuth source line and before claude -p
g=$(grep -n 'redbaron|ryzen7) ;;' "$R" | head -n1 | cut -d: -f1); o=$(grep -n '90-claude-oauth.conf' "$R" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f1); c=$(grep -n '^claude -p ' "$R" | head -n1 | cut -d: -f1)
if [ -n "$g" ] && [ -n "$o" ] && [ -n "$c" ] && [ "$g" -lt "$o" ] && [ "$g" -lt "$c" ]; then echo "ok - host gate (line $g) precedes the OAuth source ($o) and claude -p ($c)"; else echo "NOT OK - host gate order g=$g o=$o c=$c"; fail=1; fi
exit $fail
