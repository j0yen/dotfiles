#!/usr/bin/env bash
# A388 round 3: the grader unit contract in source. The 99z drop-in runs the wrapper with --drain, carries no overall batch ceiling, lifts the
# runtime ceiling, wins over every other drop-in by name, and its arguments pass the wrapper's own refusals. SD_HEAD=<swarm-decide tree> also
# checks the engine's base unit. Static reads only.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
dir="$D/.config/systemd/user/swarm-decide-regrade.service.d"; f="$dir/99z-grader-release-f8fe.conf"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
body="$(grep -v '^[[:space:]]*#' "$f")"
want='ExecStart=%h/.local/bin/grader-jyenpm-run.sh regrade --backlog --include-tooling --limit 50 --drain'
[ "$(printf '%s\n' "$body" | grep -c '^ExecStart=')" = 2 ] && [ "$(printf '%s\n' "$body" | grep '^ExecStart=' | head -1)" = "ExecStart=" ] \
  && [ "$(printf '%s\n' "$body" | grep '^ExecStart=' | tail -1)" = "$want" ] && ok "99z: ExecStart reset, then the wrapper with --drain" || bad "99z ExecStart: $(printf '%s\n' "$body" | grep '^ExecStart=')"
printf '%s\n' "$body" | grep -q -- '--max-batches' && bad "99z carries --max-batches" || ok "99z: no --max-batches (no overall batch ceiling)"
printf '%s\n' "$body" | grep -qi 'fable' && bad "99z names Fable outside comments" || ok "99z: no Fable outside comments"
[ "$(printf '%s\n' "$body" | grep '^TimeoutStartSec=')" = "TimeoutStartSec=infinity" ] && ok "99z: TimeoutStartSec=infinity" || bad "99z TimeoutStartSec: $(printf '%s\n' "$body" | grep '^TimeoutStartSec=')"
last="$(printf '%s\n' 80-include-tooling-joe-20261101.conf 85-max-output-tokens-aide-20261102.conf 90-batch-size-joe-20261102.conf 99-joe-quota-conservation.conf 99z-grader-release-f8fe.conf | LC_ALL=C sort | tail -1)"
[ "$last" = 99z-grader-release-f8fe.conf ] && ok "99z sorts after every carbon drop-in (its ExecStart/TimeoutStartSec win)" || bad "sort order: $last"
args="${want#ExecStart=%h/.local/bin/grader-jyenpm-run.sh }"; refused=0
for a in $args; do case "${a,,}" in *fable*) refused=1;; esac; case "$a" in --max-batches|--max-batches=*|--model|--model=*) refused=1;; esac; done
[ "$refused" = 0 ] && ok "99z arguments pass the wrapper's refusals (no Fable, --model, --max-batches)" || bad "99z arguments would be refused by the wrapper"
grep -q -- '--drain' "$D/.local/bin/grader-jyenpm-run.sh" && grep -q '"drain":true' "$D/.local/bin/grader-jyenpm-run.sh" && ok "wrapper pins a binding with drain support" || bad "wrapper binding lacks drain"
if [ -n "${SD_HEAD:-}" ]; then
  u="$SD_HEAD/units/swarm-decide-regrade.service"
  grep -q '^ExecStart=.*wm-decide regrade .*--drain' "$u" && ! grep -v '^#' "$u" | grep -q -- '--max-batches' && grep -qx 'TimeoutStartSec=infinity' "$u" \
    && ok "engine base unit: --drain, no --max-batches, TimeoutStartSec=infinity" || bad "engine base unit: $(grep -E '^(ExecStart|TimeoutStartSec)=' "$u" | tr '\n' '|')"
else
  echo "NOTE engine base unit not checked: SD_HEAD unset"
fi
echo "COUNTS: pass=$pass fail=$fail"
[ "$fail" = 0 ]
