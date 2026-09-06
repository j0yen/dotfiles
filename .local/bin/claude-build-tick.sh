#!/usr/bin/env bash
# One /build tick, run inside the claude-build-work transient unit.
# Wraps `claude -p /build` so quota saturation and recovery leave markers
# in the build state dir for claude-quota-watch.sh to act on.
#
# Markers (in $STATE):
#   quota-saturated   first-seen timestamp + last limit message; present while saturated
#   quota-recovered   written when a tick succeeds after saturation; consumed by the watcher
#   quota-events.log  append-only history of saturation/recovery events
set -uo pipefail
STATE="${STATE:-$HOME/.claude/skills/build/state}"
LOG="${LOG:-$HOME/brain/journal/build-auto.log}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
LIMIT_RE="${LIMIT_RE:-You.ve hit your [a-z ]*limit}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
bus_event() { # best-effort: local agorabus topic build.quota + fleet NATS subject wm.build.quota (carbon/ryzen7 monitor via the hub)
  local payload="{\"host\":\"$(hostname)\",\"state\":\"$1\",\"ts\":\"$(ts)\",\"detail\":$(printf '%s' "$2" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}"
  command -v agorabus >/dev/null 2>&1 && timeout 5 agorabus publish build.quota "$payload" --session-id claude-quota-watch >/dev/null 2>&1
  command -v nats >/dev/null 2>&1 && timeout 5 nats --server "${NATS_URL:-nats://127.0.0.1:4222}" pub wm.build.quota "$payload" >/dev/null 2>&1
  return 0
}
mkdir -p "$STATE"
tmp=$(mktemp "${TMPDIR:-/tmp}/claude-build-tick.XXXXXX")
trap 'rm -f "$tmp"' EXIT

"$CLAUDE_BIN" -p "/build" --model sonnet --dangerously-skip-permissions --output-format text 2>&1 \
  | tee -a "$LOG" > "$tmp"
rc=${PIPESTATUS[0]}

limit_msg=$(grep -aoE "$LIMIT_RE.*" "$tmp" | head -1 | tr -d '\r')
if [ -n "$limit_msg" ]; then
  if [ ! -f "$STATE/quota-saturated" ]; then
    printf 'since=%s\n' "$(ts)" > "$STATE/quota-saturated"
    echo "$(ts) saturated: $limit_msg" >> "$STATE/quota-events.log"
    bus_event saturated "$limit_msg"
  fi
  # keep the latest message; the reset time in it moves as limits roll over
  grep -vE '^(message|last_seen)=' "$STATE/quota-saturated" > "$STATE/quota-saturated.tmp" 2>/dev/null || true
  printf 'message=%s\nlast_seen=%s\n' "$limit_msg" "$(ts)" >> "$STATE/quota-saturated.tmp"
  mv "$STATE/quota-saturated.tmp" "$STATE/quota-saturated"
  echo "$(ts) tick: quota saturated (rc=$rc): $limit_msg" >> "$LOG"
  exit "$rc"
fi

if [ "$rc" -eq 0 ] && [ -f "$STATE/quota-saturated" ]; then
  since=$(sed -n 's/^since=//p' "$STATE/quota-saturated")
  msg=$(sed -n 's/^message=//p' "$STATE/quota-saturated")
  { echo "since=$since"; echo "recovered=$(ts)"; echo "message=$msg"; } > "$STATE/quota-recovered"
  rm -f "$STATE/quota-saturated"
  echo "$(ts) recovered (saturated since $since): $msg" >> "$STATE/quota-events.log"
  echo "$(ts) tick: quota recovered, saturated since $since" >> "$LOG"
  bus_event recovered "saturated since $since: $msg"
fi
if [ "$rc" -eq 0 ]; then echo "$(ts) tick: ok" >> "$LOG"; else echo "$(ts) tick: failed (rc=$rc, not a quota limit)" >> "$LOG"; fi
exit "$rc"
