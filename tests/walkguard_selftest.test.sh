#!/usr/bin/env bash
# walk-guard case table: runs the hook's own --selftest (forms, hosts, wrappers, bypass cases,
# refusal rewrite passes the hook) under a throwaway HOME, then checks the post-apply state file.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
H="$ROOT/.claude/plugins/walk-guard/hooks/walk-guard.sh"
fail=0
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
export HOME="$t"
out="$("$H" --selftest --write-state 2>&1)"; rc=$?
echo "$out" | tail -5
[ "$rc" = 0 ] && echo "ok - selftest passes" || { echo "NOT OK - selftest rc=$rc"; fail=1; }
case "$out" in *"walk-guard selftest: "*"passed"*) echo "ok - summary line present" ;; *) echo "NOT OK - no summary"; fail=1 ;; esac
s="$HOME/.local/state/watchers/_walkhook.json"
if jq -e '.watcher=="walkhook" and .ok==true and .passed==.total and .total>0' "$s" >/dev/null 2>&1; then
  echo "ok - _walkhook.json written, ok=true"; else echo "NOT OK - _walkhook.json missing or not ok"; fail=1; fi
# install.sh wires the skills-dir link and the post-apply selftest (dry run shows the link)
dry="$("$ROOT/install.sh" --dry-run 2>&1)"
case "$dry" in *".claude/skills/walk-guard"*) echo "ok - install.sh links the skills-dir plugin" ;; *) echo "NOT OK - install.sh does not link skills/walk-guard"; fail=1 ;; esac
# a failing selftest must be recorded as an alarm: break the contract, expect ok=false
bad="$t/bad.json"; jq '.prune_dirs = []' "$ROOT/.claude/plugins/walk-guard/contracts/walk-guard.json" > "$bad"
WALK_GUARD_CONTRACT="$bad" "$H" --selftest --write-state >/dev/null 2>&1
if jq -e '.ok==false and .alarm=="walk-hook-selftest-failed"' "$s" >/dev/null 2>&1; then
  echo "ok - a broken contract writes ok=false + alarm"; else echo "NOT OK - broken contract not recorded"; fail=1; fi
exit $fail
