#!/usr/bin/env bash
# tests/agorabus-intent-auto-from-skill_test_helpers.sh — shared setup for
# tests/agorabus-intent-auto-from-skill_ac*.test.sh. Puts the recording
# fake-agorabus on PATH, pins the sid, and isolates the state dir.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/agorabus-intent.sh"
FIXTURES="$ROOT/tests/fixtures"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

intent_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/state"
  ln -s "$FIXTURES/fake-agorabus" "$work/bin/agorabus"
  calls="$work/calls"; : >"$calls"
  export FAKE_AGORABUS_CALLS="$calls"
  export CLAUDE_AGORABUS_SID="claude-test-sid"
  export AGORABUS_INTENT_STATE_DIR="$work/state"
  export PATH="$work/bin:$PATH"
  sid="$CLAUDE_AGORABUS_SID"
  cwd="$work/proj"; mkdir -p "$cwd"
}

# run_hook <json> [hook args…] — feeds json on stdin.
run_hook() { local j="$1"; shift; printf '%s' "$j" | "$HOOK" "$@"; }
