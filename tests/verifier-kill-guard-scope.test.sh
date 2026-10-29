#!/usr/bin/env bash
# tests/verifier-kill-guard-scope.test.sh: the guard's scp/sftp/rsync deny reaches only aide-verifier units. Memory/vault sync and every other session never load it.
# The guard denies by input alone, so scope = registration: only aide-verifier.sh writes it into a unit's own settings.json. Run: bash tests/verifier-kill-guard-scope.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd); guard="$root/.local/bin/verifier-kill-guard.sh"
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
cd "$root" || exit 2
# 1. every tracked file that names the guard: the guard itself, its tests, and aide-verifier.sh (the unit-scoped registration). Nothing else.
refs=$(git grep -l 'verifier-kill-guard' -- . ':!tests' ':!.local/bin/verifier-kill-guard.sh' | sort | tr '\n' ' ')
[ "$refs" = ".local/bin/aide-verifier.sh " ] && pass "only aide-verifier.sh registers the guard (refs: $refs)" || bad "guard referenced outside the verifier unit: $refs"
# 2. no settings file any other session loads (global, seat, project) registers it
leak=$(git grep -l 'verifier-kill-guard' -- '*settings*.json' '.claude' '.config' 2>/dev/null | tr '\n' ' ')
[ -z "$leak" ] && pass "no tracked settings/hook config registers the guard" || bad "settings register the guard: $leak"
# 3. the unit registration is written to the unit's own $DIR/settings.json, never ~/.claude
grep -q 'verifier-kill-guard.sh" .*>"\$DIR/settings.json"' .local/bin/aide-verifier.sh && pass "registration goes to the unit's \$DIR/settings.json" || bad "registration target changed"
# 4. scripts/units that run scp/rsync (the grep the PRD names) are not guard consumers; memory/vault sync has no rsync line in tracked scripts or units
users=$(grep -rlE '(^|[;&|[:space:]])(rsync|scp|sftp)[[:space:]]' .local/bin .config/systemd 2>/dev/null | grep -v verifier-kill-guard.sh | sort | tr '\n' ' ')
for f in $users; do
  grep -q 'verifier-kill-guard' "$f" && [ "$f" != ".local/bin/aide-verifier.sh" ] && bad "$f runs scp/rsync AND loads the guard"
done
echo "INFO: scp/rsync users: $users"
sync_hits=$(grep -rlE '(memory|vault)[-_]?sync' .local/bin .config/systemd 2>/dev/null | xargs -r grep -lE '(^|[;&|[:space:]])(rsync|scp|sftp)[[:space:]]' 2>/dev/null | tr '\n' ' ')
[ -z "$sync_hits" ] && pass "no memory-sync/vault-sync script or unit uses rsync/scp/sftp" || bad "sync path uses rsync/scp: $sync_hits"
# 5. a hook payload from a non-verifier session never reaches the guard: the unit settings are the only registration, so a sync-style rsync line is not intercepted there.
#    Run the real registration text: a global-settings-shaped file must not contain the guard.
[ -s .claude/settings.json ] && ! grep -q 'verifier-kill-guard' .claude/settings.json && pass "global .claude/settings.json (non-verifier sessions) has no guard hook, so its rsync lines are allowed" || bad "global settings load the guard"
# 6. the deny itself still fires inside a verifier (guard input contract unchanged)
printf '%s' '{"tool_input":{"command":"rsync -a a b:c"}}' | bash "$guard" >/dev/null 2>&1; [ $? = 2 ] && pass "inside a verifier unit rsync is still denied" || bad "guard no longer denies rsync"
exit $fail
