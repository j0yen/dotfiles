#!/usr/bin/env bash
# tests/explorefirst_test_helpers.sh — shared setup for
# tests/explorefirst_ac*.test.sh (PRD-mcphost-explore-first-light). Puts
# fake mcphost/synthorg/curl/systemctl/agorabus on PATH ahead of the real
# ones, builds a throwaway git repo as the PRD workspace, and points
# .local/bin/mcphost-explore-run.sh at all of it via its EXPLOREFIRST_* env
# hooks — same convention as tests/buildpath_test_helpers.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/.local/bin/mcphost-explore-run.sh"
FIXTURES="$REPO_ROOT/tests/fixtures"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "NOT OK - $3: '$1' unexpectedly contains '$2'"; fail=1 ;; *) echo "ok - $3" ;; esac
}
assert_file_exists() { # $1=path $2=description
  if [ -e "$1" ]; then echo "ok - $2"
  else echo "NOT OK - $2: $1 does not exist"; fail=1; fi
}
assert_file_missing() { # $1=path $2=description
  if [ ! -e "$1" ]; then echo "ok - $2"
  else echo "NOT OK - $2: $1 unexpectedly exists"; fail=1; fi
}

explorefirst_setup() {
  work="$(mktemp -d)"
  trap 'explorefirst_teardown' EXIT

  bin="$work/bin"
  mkdir -p "$bin"
  ln -s "$FIXTURES/fake-mcphost" "$bin/mcphost"
  ln -s "$FIXTURES/fake-synthorg" "$bin/synthorg"
  ln -s "$FIXTURES/fake-curl" "$bin/curl"
  ln -s "$FIXTURES/fake-systemctl-explorefirst" "$bin/systemctl"
  ln -s "$FIXTURES/fake-agorabus" "$bin/agorabus"

  mcphost_calls="$work/mcphost-calls"; : > "$mcphost_calls"
  synthorg_calls="$work/synthorg-calls"; : > "$synthorg_calls"
  agorabus_calls="$work/agorabus-calls"; : > "$agorabus_calls"
  health_counter="$work/health-counter"

  export FAKE_MCPHOST_CALLS="$mcphost_calls"
  export FAKE_SYNTHORG_CALLS="$synthorg_calls"
  export FAKE_AGORABUS_CALLS="$agorabus_calls"
  export FAKE_CURL_HEALTH_COUNTER="$health_counter"
  unset FAKE_MCPHOST_MIGRATE_MODE FAKE_MCPHOST_SERVE_MODE
  unset FAKE_CURL_HEALTH_MODE FAKE_CURL_HEALTH_AFTER
  unset FAKE_SYNTHORG_EXPLORE_MODE FAKE_SYNTHORG_OBS_MODE FAKE_SYNTHORG_USECASES_MODE FAKE_SYNTHORG_EXPORT_MODE
  unset FAKE_USECASES_JSON FAKE_SYSTEMCTL_ACTIVE_UNIT

  prd_dir="$work/PRDs"
  mkdir -p "$prd_dir/notes" "$prd_dir/vibeloop"
  ( cd "$prd_dir" && git init -q && git -c user.email=test@test.local -c user.name=test commit -q --allow-empty -m init )
  : > "$prd_dir/notes/dream-log.md"

  syn_dir="$work/synthorg"
  mkdir -p "$syn_dir/corpora/mcphost"
  cat > "$syn_dir/corpora/mcphost/panel-composition.yaml" <<'YAML'
size: 3
segments:
  rapid_prototyper: {weight: 0.5}
  rag_indexer: {weight: 0.3}
  admin_agent: {weight: 0.2}
YAML

  crate_dir="$work/mcphost-crate"
  mkdir -p "$crate_dir"
  ( cd "$crate_dir" && git init -q && git commit -q --allow-empty -m init && git tag v1.2.3 )

  log_file="$work/journal.log"

  export EXPLOREFIRST_PRD_DIR="$prd_dir"
  export EXPLOREFIRST_LOG="$log_file"
  export EXPLOREFIRST_SYN="$syn_dir"
  export EXPLOREFIRST_CRATE="$crate_dir"
  export EXPLOREFIRST_MCPHOST_BIN="$bin/mcphost"
  export EXPLOREFIRST_SYNTHORG_BIN="$bin/synthorg"
  export EXPLOREFIRST_VIBELOOP_UNIT="claude-vibeloop-work.service"
  export EXPLOREFIRST_WORK="$work/scratch"
  export EXPLOREFIRST_HEALTH_TRIES=10
  export EXPLOREFIRST_HEALTH_INTERVAL=0
  export EXPLOREFIRST_NOW="2026-09-13T03:00:00Z"
  export EXPLOREFIRST_NO_PUSH=1
  export EXPLOREFIRST_BUDGET_ASSERT="calls<=3000,tokens_out<=600000"

  export EXPLOREFIRST_EXTRA_PATH="$bin"
}

explorefirst_teardown() {
  rm -rf "$work" 2>/dev/null
}
