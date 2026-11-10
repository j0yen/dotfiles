#!/usr/bin/env bash
# agorabus-lock-refresh.sh: weekly RedBaron check of j0yen/agorabus main with cargo deny (A1487 lock-refresh).
# Deny red -> cargo update, re-run deny + tests, commit Cargo.lock locally on chore/lock-refresh-<date>.
# DETECTS and STAGES only: nothing leaves this host; the rb seat gates and sends the staged branch (A1485 rule).
# Env: LOCK_REFRESH_ROOT (default /mnt/data/jsy/tmp/lock-refresh), LOCK_REFRESH_STATE (default ~/.cache/rb-seat/lock-refresh),
#      LOCK_REFRESH_REPO (default https://github.com/j0yen/agorabus.git), LOCK_REFRESH_TIMEOUT (whole run, default 2700 s).
set -u
h="$(hostname -s 2>/dev/null)"
if [ "$h" != redbaron ]; then echo "skip: not redbaron"; exit 0; fi
if [ -z "${LOCKREF_INNER:-}" ]; then
  LOCKREF_INNER=1 exec nice -n 10 timeout "${LOCK_REFRESH_TIMEOUT:-2700}" bash "$0" "$@"
fi
ROOT="${LOCK_REFRESH_ROOT:-/mnt/data/jsy/tmp/lock-refresh}"
STATE="${LOCK_REFRESH_STATE:-$HOME/.cache/rb-seat/lock-refresh}"
REPO="${LOCK_REFRESH_REPO:-https://github.com/j0yen/agorabus.git}"
DATE="$(date +%Y%m%d)"
DIR="$ROOT/$DATE"
export CARGO_BUILD_JOBS=3
mkdir -p "$ROOT" "$STATE" || exit 1

# prune dated dirs older than 14 days, directly under ROOT only
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -mtime +14 -exec rm -rf {} + 2>/dev/null

deny=red refreshed=no tests=skip head=none
finish() {
  local line
  line="$(date -Is) deny=$deny refreshed=$refreshed tests=$tests dir=$DIR head=$head"
  printf '%s\n' "$line" > "$STATE/last.txt"
  if [ "$refreshed" = yes ] || [ "$deny" = red ] || [ "$tests" = fail ]; then printf '%s\n' "$line" >> "$STATE/pending.txt"; fi
  echo "$line"
  exit 0
}

rm -rf "$DIR"; mkdir -p "$DIR"
if ! git clone -q --depth 1 --branch main "$REPO" "$DIR/agorabus"; then echo "clone failed" >&2; finish; fi
cd "$DIR/agorabus" || finish
if cargo deny --locked check advisories bans >"$DIR/deny1.log" 2>&1; then deny=green; finish; fi
cargo update >"$DIR/update.log" 2>&1
if ! cargo deny --locked check advisories bans >"$DIR/deny2.log" 2>&1; then deny=red; finish; fi
deny=green
if cargo test --locked -j 3 >"$DIR/test.log" 2>&1; then tests=pass; else tests=fail; finish; fi
git checkout -q -b "chore/lock-refresh-$DATE" || finish
git add Cargo.lock
if git -c user.name=j0yen -c user.email=j0yen@users.noreply.github.com commit -q -m "chore: refresh Cargo.lock ($DATE) so cargo deny is green"; then
  refreshed=yes; head="$(git rev-parse --short HEAD)"
fi
finish
