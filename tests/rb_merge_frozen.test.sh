#!/usr/bin/env bash
# tests/rb_merge_frozen.test.sh -- rb-merge.sh refuses a frozen PR before any gh call (gate proof P1). Run: bash tests/rb_merge_frozen.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; fail=0
printf '#!/bin/sh\ntouch "%s/gh-called"\nexit 99\n' "$tmp" > "$tmp/gh"; chmod +x "$tmp/gh"
printf '# c\nj0yen/mcphost#536\n' > "$tmp/frozen"
run() { RB_MERGE_FROZEN_FILE="$1" RB_MERGE_GH="$tmp/gh" WM_DECIDE_BIN=/bin/false RB_MERGE_LOG_DIR="$tmp/logs" PATH="$tmp:$PATH" bash "$here/.local/bin/rb-merge.sh" d-x "$2" "$3" 2>&1; }
frozen_pr_refused_before_gh_merge() {
  out="$(run "$tmp/frozen" 536 j0yen/mcphost)"; rc=$?
  [ $rc -eq 6 ] && echo "$out" | grep -q 'FROZEN-PR j0yen/mcphost#536' && [ ! -e "$tmp/gh-called" ] && echo "ok - frozen PR refused rc6, no gh" || { echo "NOT OK - frozen: rc=$rc $out"; fail=1; }
  out="$(run "$tmp/frozen" 537 j0yen/mcphost)"; echo "$out" | grep -q FROZEN-PR && { echo "NOT OK - unlisted PR refused as frozen"; fail=1; } || echo "ok - unlisted PR not frozen-refused"
  : > "$tmp/unreadable"; chmod 000 "$tmp/unreadable"; out="$(run "$tmp/unreadable" 537 j0yen/mcphost)"; echo "$out" | grep -q 'FROZEN-PR-UNREADABLE' && echo "ok - unreadable fails closed" || { echo "NOT OK - unreadable: $out"; fail=1; }
}
frozen_pr_refused_before_gh_merge; [ $fail = 0 ] && echo ALL PASS; exit $fail
