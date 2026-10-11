#!/usr/bin/env bash
# tests/pfact_test_helpers.sh — shared fixtures for tests/pfact_ac*.test.sh.
# Builds a throwaway PRD repo whose commit times are relative to now, plus a
# state.db with the verbatim runs/decisions columns the hook reads.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/park-fresh-fact.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

# fx_commit <minutes-ago> <subject> — commit whatever is staged at a time.
fx_commit() {
  local ts; ts=$(( $(date +%s) - $1 * 60 ))
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
    git -C "$PRD_DIR" commit -q --allow-empty -m "$2"
}

pfact_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  export HOME="$work/home"; mkdir -p "$HOME"
  export PRD_DIR="$work/PRDs" WM_STATE_DB="$work/state.db"
  export PARK_AUDIT_FILE="$work/audit.jsonl"
  unset PARK_FRESH_FACT PARK_FRESH_WINDOW_MIN
  mkdir -p "$PRD_DIR/build-queue" "$PRD_DIR/parked"
  git -C "$PRD_DIR" init -q
  git -C "$PRD_DIR" config user.email t@t; git -C "$PRD_DIR" config user.name t
  echo "# PRD x" >"$PRD_DIR/build-queue/PRD-x.md"; : >"$PRD_DIR/MANIFEST.md"
  git -C "$PRD_DIR" add -A
  fx_commit 600 "seed: x queued"          # old, outside any window
  sqlite3 "$WM_STATE_DB" "
    CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, slug TEXT NOT NULL, started TEXT, ended TEXT, outcome TEXT);
    CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, question TEXT NOT NULL, opened TEXT NOT NULL, closed TEXT);"
}

# iso_ago <minutes> — ISO-8601 UTC string that long ago.
iso_ago() { date -u -d "@$(( $(date +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%S+00:00; }

# bash_payload <command> — PreToolUse JSON for a Bash call.
bash_payload() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
# edit_payload <tool> <path> <new_string>
edit_payload() { jq -nc --arg t "$1" --arg p "$2" --arg s "$3" '{tool_name:$t,tool_input:{file_path:$p,new_string:$s}}'; }

# run_hook <json> — sets out, rc.
run_hook() { out=$(printf '%s' "$1" | "$HOOK" 2>/dev/null); rc=$?; }
