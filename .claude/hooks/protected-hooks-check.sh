#!/usr/bin/env bash
# protected-hooks-check.sh <settings.json> [list]  |  --selftest
# Every basename in the list (default: ../protected-hooks.txt next to this script) must appear in some hook command
# of the settings.json, else MISSING + exit 1 -- unless APPROVALS_LOG (default ~/.claude/state/approvals.log) has a line
# containing protected-hook:<name> (then "approved-off", exit stays 0). Any hook entry running summa-lookup-inject.sh
# must carry "timeout" >= 10 (a slow hook gets a longer timeout, never removal; Joe 10-23).
set -uo pipefail

MIN_TIMEOUT=10

check() {
  local settings="$1" list="$2" log="${APPROVALS_LOG:-$HOME/.claude/state/approvals.log}" rc=0 name cmds re v
  [ -r "$settings" ] && jq -e . "$settings" >/dev/null 2>&1 || { echo "unreadable-settings $settings" >&2; return 1; }
  [ -r "$list" ] || { echo "unreadable-list $list" >&2; return 1; }
  cmds="$(jq -r '.hooks[]?[]?.hooks[]?.command // empty' "$settings")"
  while IFS= read -r name || [ -n "$name" ]; do
    name="${name%%#*}"; name="${name//[[:space:]]/}"
    [ -n "$name" ] || continue
    if printf '%s\n' "$cmds" | grep -qF -- "$name"; then
      echo "ok $name"
    else
      re="protected-hook:$(printf '%s' "$name" | sed 's/[][\.*^$/]/\\&/g')([^A-Za-z0-9._-]|\$)"
      if [ -r "$log" ] && grep -Eq -- "$re" "$log"; then
        echo "approved-off $name"
      else
        echo "MISSING $name"; rc=1
      fi
    fi
  done < "$list"
  # every entry running summa-lookup-inject.sh needs timeout >= MIN_TIMEOUT
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
      ''|*[!0-9]*) echo "timeout-too-low summa-lookup-inject.sh $v"; rc=1 ;;
      *) if [ "$v" -lt "$MIN_TIMEOUT" ]; then echo "timeout-too-low summa-lookup-inject.sh $v"; rc=1; fi ;;
    esac
  done < <(jq -r '.hooks[]?[]?.hooks[]? | select((.command // "") | contains("summa-lookup-inject.sh")) | (.timeout // "unset")' "$settings")
  return $rc
}

selftest() {
  local d pass=0 total=0 out rc
  d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  printf '# c\nalpha.sh\nsumma-lookup-inject.sh  # inline\n' > "$d/list"
  mk() { # $1=file $2=timeout-json-fragment ('' = none) $3=include alpha (1/0)
    jq -n --arg a "$3" --argjson t "${2:-null}" '
      {hooks:{SessionStart:([{hooks:[{type:"command",command:"/x/hooks/lean.sh /x/scripts/summa-lookup-inject.sh"} + (if $t==null then {} else {timeout:$t} end)]}]
        + (if $a=="1" then [{hooks:[{type:"command",command:"/x/alpha.sh start"}]}] else [] end))}}' > "$1"
  }
  t() { # $1=label $2=want-rc $3=want-output-regex  (uses $out $rc)
    total=$((total+1))
    if [ "$rc" = "$2" ] && printf '%s\n' "$out" | grep -Eq "$3"; then pass=$((pass+1)); else echo "FAIL $1 (rc=$rc out=$out)" >&2; fi
  }
  mk "$d/ok.json" 10 1
  out="$(APPROVALS_LOG=/nonexistent check "$d/ok.json" "$d/list" 2>&1)"; rc=$?; t present 0 '^ok alpha.sh$'
  t present-no-failure 0 '^ok summa-lookup-inject.sh$'
  mk "$d/miss.json" 10 0
  out="$(APPROVALS_LOG=/nonexistent check "$d/miss.json" "$d/list" 2>&1)"; rc=$?; t missing 1 '^MISSING alpha.sh$'
  printf 'x protected-hook:alpha.sh-other\n' > "$d/log"
  out="$(APPROVALS_LOG="$d/log" check "$d/miss.json" "$d/list" 2>&1)"; rc=$?; t prefix-name-not-approval 1 '^MISSING alpha.sh$'
  printf '2026-10-23 joe approve protected-hook:alpha.sh\n' > "$d/log"
  out="$(APPROVALS_LOG="$d/log" check "$d/miss.json" "$d/list" 2>&1)"; rc=$?; t approved-off 0 '^approved-off alpha.sh$'
  mk "$d/low.json" 5 1
  out="$(APPROVALS_LOG=/nonexistent check "$d/low.json" "$d/list" 2>&1)"; rc=$?; t timeout-too-low 1 '^timeout-too-low summa-lookup-inject.sh 5$'
  mk "$d/none.json" "" 1
  out="$(APPROVALS_LOG=/nonexistent check "$d/none.json" "$d/list" 2>&1)"; rc=$?; t timeout-unset 1 '^timeout-too-low summa-lookup-inject.sh unset$'
  echo "protected-hooks-check selftest $pass/$total"
  [ "$pass" = "$total" ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  ""|-h|--help) echo "usage: $0 <settings.json> [list] | --selftest" >&2; exit 2 ;;
esac
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check "$1" "${2:-$here/../protected-hooks.txt}"
