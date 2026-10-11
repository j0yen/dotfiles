#!/usr/bin/env bash
# tests/hgen_test_helpers.sh — shared fixture builder for tests/hgen_ac*.test.sh
# (PRD dotfiles-handoff-generated). Reuses the ocard fixture (state.db, chain
# ledger, fake systemctl/agorabus), builds a real status.json with the real
# operator-status-gen.sh so the upstream shape cannot drift from what the
# generator reads, then adds the ended-run columns and a memory dir.
set -uo pipefail
here_h="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here_h/ocard_test_helpers.sh"
HGEN="$ROOT/.claude/scripts/handoff-gen.sh"
LINT="$ROOT/.claude/scripts/handoff-lint.sh"

# hgen_setup — ocard fixture + status.json + 2 ended runs + memory dir; points
# the generator at them. mcphost is unreachable unless a test overrides it.
hgen_setup() {
  ocard_setup
  sqlite3 "$work/state/state.db" "
    alter table runs add column outcome text;
    alter table runs add column close_cause text;
    insert into runs values (601,'ended-a','$(iso_ago 300)','$(iso_ago 200)','land','tick','daemon','Landed','landed');
    insert into runs values (602,'ended-b','$(iso_ago 120)','$(iso_ago 60)','inner','tick','daemon','Code','op-close');"
  export OPERATOR_CACHE_DIR="$work/cache"
  "$GEN" --out "$work/cache/status.json"
  export HANDOFF_MEMORY_DIR="$work/memory"; mkdir -p "$HANDOFF_MEMORY_DIR"
  export HANDOFF_MCPHOST_URL="http://127.0.0.1:9"
  export HANDOFF_SYNTHORG_REPO="$work/no-synthorg"
}
