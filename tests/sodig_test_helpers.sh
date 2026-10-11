#!/usr/bin/env bash
# tests/sodig_test_helpers.sh — shared fixtures for tests/sodig_ac*.test.sh.
# Builds a throwaway PRD repo with commit times relative to now, a sessions dir
# of agent.activity ndjson, and an isolated cache/notices dir.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.local/bin/overlap-digest.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

# fx_commit <minutes-ago> <subject> <slug>... — touch each slug's PRD file and commit at that time.
fx_commit() {
  local ago=$1 subj=$2 ts s; shift 2
  ts=$(( $(date +%s) - ago * 60 ))
  for s in "$@"; do
    mkdir -p "$PRD_DIR/build-queue"
    echo "$subj $ts" >>"$PRD_DIR/build-queue/PRD-$s.md"
  done
  git -C "$PRD_DIR" add -A
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
    git -C "$PRD_DIR" commit -q --allow-empty -m "$subj"
  LAST=$(git -C "$PRD_DIR" log -1 --format=%h)
}

# fx_activity <sid> <text> [path] — one agent.activity event now.
fx_activity() {
  mkdir -p "$OVERLAP_SESSIONS_DIR"
  jq -nc --arg t "$2" --arg p "${3:-}" --argjson ts "$(date +%s)" \
    '{type:"agent.activity",ts:$ts,agent:"claude",status:"working",summary:$t,paths:(if $p=="" then [] else [$p] end)}' \
    >>"$OVERLAP_SESSIONS_DIR/$1.ndjson"
}

sodig_setup() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  export HOME="$work/home"; mkdir -p "$HOME"
  export PRD_DIR="$work/PRDs" OVERLAP_SESSIONS_DIR="$work/sessions" WM_STATE_DB="$work/state.db"
  export OPERATOR_CACHE_DIR="$work/cache" OPERATOR_NOTICES_DIR="$work/cache/notices"
  unset OVERLAP_WINDOW_MIN
  OUT="$work/cache/overlap-digest.md"
  mkdir -p "$PRD_DIR"
  git -C "$PRD_DIR" init -q
  git -C "$PRD_DIR" config user.email t@t; git -C "$PRD_DIR" config user.name t
}

notice_count() { find "$OPERATOR_NOTICES_DIR" -name '*-overlap.txt' 2>/dev/null | wc -l; }
run_digest() { "$SCRIPT" "$@" >/dev/null 2>&1; rc=$?; digest=$(cat "$OUT" 2>/dev/null); }
