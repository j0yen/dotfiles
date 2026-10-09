#!/usr/bin/env bash
# tests/agorabus-overlap-warning-hook_test_helpers.sh — shared setup for
# tests/agorabus-overlap-warning-hook_ac*.test.sh. Puts the fake agorabus
# (canned `intent list` / `claim list`) on PATH, pins the sid, and isolates
# the state dir (which also holds sessions/<sid>.ndjson).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/agorabus-overlap.sh"
FIXTURES="$ROOT/tests/fixtures"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

overlap_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/state/sessions"
  ln -s "$FIXTURES/fake-agorabus-overlap" "$work/bin/agorabus"
  export FAKE_AGORABUS_CALLS="$work/calls"; : >"$FAKE_AGORABUS_CALLS"
  export FAKE_INTENT_JSON="$work/intent.json" FAKE_CLAIM_JSON="$work/claim.json"
  echo '[]' >"$FAKE_INTENT_JSON"; echo '[]' >"$FAKE_CLAIM_JSON"
  export CLAUDE_AGORABUS_SID="claude-self"
  export AGORABUS_INTENT_STATE_DIR="$work/state"
  export PATH="$work/bin:$PATH"
  sid="$CLAUDE_AGORABUS_SID"
  cwd="$work/proj"; mkdir -p "$cwd"
}

# run_hook [hook args…] — feeds a UserPromptSubmit payload with our cwd.
run_hook() { printf '{"cwd":"%s","prompt":"hi"}' "$cwd" | "$HOOK" "$@"; }
