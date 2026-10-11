#!/usr/bin/env bash
# tests/crchk_test_helpers.sh — shared setup for tests/crchk_ac*.test.sh
# (PRD dotfiles-config-edit-reload-check). Isolates config path, journal,
# operator cache and PATH (fake wm-build printing a canned `config effective`,
# fake systemctl answering is-active) so the hook never touches the real daemon.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/config-reload-check.sh"

fail=0
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then echo "ok - $3"
  else echo "NOT OK - $3: got '$1', want '$2'"; fail=1; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) echo "ok - $3" ;; *) echo "NOT OK - $3: '$1' does not contain '$2'"; fail=1 ;; esac
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%S.%N+00:00; }

# crchk_setup — creates $work; exports the env the hook reads.
crchk_setup() {
  work="$(mktemp -d)"
  trap 'pkill -f "config-reload-check.sh --wait $work" 2>/dev/null; rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/cache"
  export WM_BUILD_CONFIG="$work/config.toml"; : >"$WM_BUILD_CONFIG"
  export WM_BUILD_JOURNAL="$work/journal.jsonl"
  export OPERATOR_CACHE_DIR="$work/cache"; unset OPERATOR_NOTICES_DIR
  export CRCHK_POLL=1
  export FAKE_EFFECTIVE="$work/effective.txt"
  cat >"$FAKE_EFFECTIVE" <<'TXT'
tick_interval_secs 180
max_runs 3 → 4 (reloadable)
state_dir /old/state → /new/state (restart-required)
gates 2
TXT
  cat >"$work/bin/wm-build" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "config effective" ] && cat "$FAKE_EFFECTIVE"
SH
  cat >"$work/bin/systemctl" <<'SH'
#!/usr/bin/env bash
echo "${FAKE_ACTIVE:-active}"; [ "${FAKE_ACTIVE:-active}" = active ]
SH
  chmod +x "$work/bin/wm-build" "$work/bin/systemctl"
  export PATH="$work/bin:$PATH"
  # an old tick that predates any edit: must be ignored by the waiter
  printf '{"op":"tick","row":{"admitted":[],"skipped":[],"config_loaded_at":"2020-01-01T00:00:00.000000000+00:00"},"table":"daemon","ts":"2020-01-01T00:00:00+00:00"}\n' >"$WM_BUILD_JOURNAL"
}

# append_tick ADMITTED SKIPPED — a tick row loaded just now, preceded by the
# reload rows for max_runs (the daemon logs them in the same tick).
append_tick() {
  local n=$(now_iso) a="" s="" i
  for ((i=0;i<${1:-0};i++)); do a+="${a:+,}\"a$i\""; done
  for ((i=0;i<${2:-0};i++)); do s+="${s:+,}{\"reason\":\"cap=max_runs\",\"slug\":\"s$i\"}"; done
  {
    printf '{"op":"config-reloaded","row":{"key":"max_runs","new":4,"old":3},"table":"daemon","ts":"%s"}\n' "$n"
    printf '{"op":"tick","row":{"admitted":[%s],"skipped":[%s],"config_loaded_at":"%s"},"table":"daemon","ts":"%s"}\n' "$a" "$s" "$n" "$n"
  } >>"$WM_BUILD_JOURNAL"
}

edit_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "${1:-$WM_BUILD_CONFIG}"; }
run_hook() { "$HOOK" "$@"; }

# wait_notice SECS — echoes the path of the first notices/*-config-reload.txt.
wait_notice() {
  local i f
  for ((i=0;i<${1:-30}*2;i++)); do
    f=$(ls "$OPERATOR_CACHE_DIR"/notices/*-config-reload.txt 2>/dev/null | head -n 1)
    [ -n "$f" ] && { echo "$f"; return 0; }
    sleep 0.5
  done
  return 1
}
