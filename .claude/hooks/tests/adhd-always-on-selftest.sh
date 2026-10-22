#!/usr/bin/env bash
# adhd-always-on-selftest.sh — FAILS LOUDLY unless the dotfiles ADHD injector is wired and the plugin cache is clean.
# Checks: (1) hook registered in dotfiles settings.json SessionStart, (2) the ~/.claude/settings.json the harness reads
# is that file, (3) hook script exists + executable, (4) lean/compact emit exactly the one-liner, non-lean emits the
# full ruleset, (5) the plugin cache hooks are pristine (no "Local patch" text) and the plugin flag is not left behind.
# Run: ~/.claude/hooks/tests/adhd-always-on-selftest.sh
set -uo pipefail
HOOK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/adhd-always-on.sh"
SETTINGS_SRC="${ADHD_SELFTEST_SETTINGS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/settings.json}"
HOOK_LIVE="$HOME/.claude/hooks/adhd-always-on.sh"
fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

[ -x "$HOOK_SRC" ] && ok "hook script exists and is executable" || bad "hook script missing/not executable: $HOOK_SRC"
n=$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(test("adhd-always-on[.]sh"))] | length' "$SETTINGS_SRC" 2>/dev/null)
[ "$n" = 1 ] && ok "adhd-always-on.sh registered once in SessionStart ($SETTINGS_SRC)" \
             || bad "adhd-always-on.sh NOT registered exactly once in SessionStart of $SETTINGS_SRC (found: ${n:-parse error})"
# Installed-tree checks: only meaningful when THIS tree is the one $HOME links to (a clean clone under a verify
# gate is not installed, and must not fail for that).
if [ "$(readlink -f "$HOOK_LIVE" 2>/dev/null)" = "$(readlink -f "$HOOK_SRC")" ]; then
  live=$(readlink -f "$HOME/.claude/settings.json" 2>/dev/null)
  [ "$live" = "$(readlink -f "$SETTINGS_SRC")" ] && ok "~/.claude/settings.json resolves to the dotfiles settings.json" \
               || bad "~/.claude/settings.json ($live) is not the dotfiles settings.json — registration would not take effect"
  [ -x "$HOOK_LIVE" ] && ok "hook reachable at $HOOK_LIVE" || bad "hook not linked at $HOOK_LIVE (run install.sh)"
else
  ok "installed-tree checks skipped: $HOOK_SRC is not the tree $HOME/.claude links to (clean clone)"
fi

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/plugins/cache/i-have-adhd/i-have-adhd/9.9.9/skills/i-have-adhd"
printf -- '---\nname: x\n---\nRULE-LINE-ONE\n' > "$d/plugins/cache/i-have-adhd/i-have-adhd/9.9.9/skills/i-have-adhd/SKILL.md"
: > "$d/.adhd-always-on"
one='ADHD MODE ACTIVE (always-on); ruleset = i-have-adhd skill.'
# The hook is silent for headless sessions (WM_SEAT rb|r7|ctl or a `claude -p` ancestor); the selftest runs under
# seat units and clean clones, so neutralize both seams (ADHD_SKIP_ANCESTORS=1 is the hook's selftest-only seam).
run() { env -u CLAUDE_LEAN_START -u SEAT_LEAN -u WM_SEAT ADHD_SKIP_ANCESTORS=1 CLAUDE_CONFIG_DIR="$d" "$@"; }
[ "$(run CLAUDE_LEAN_START=1 "$HOOK_SRC" </dev/null)" = "$one" ] && ok "CLAUDE_LEAN_START=1 -> one-liner" || bad "CLAUDE_LEAN_START=1 did not emit the one-liner"
[ "$(run SEAT_LEAN=1 "$HOOK_SRC" </dev/null)" = "$one" ] && ok "SEAT_LEAN=1 -> one-liner" || bad "SEAT_LEAN=1 did not emit the one-liner"
[ "$(echo '{"source":"compact"}' | run "$HOOK_SRC")" = "$one" ] && ok "source=compact -> one-liner" || bad "source=compact did not emit the one-liner"
out=$(echo '{"source":"startup"}' | run "$HOOK_SRC")
case "$out" in *RULE-LINE-ONE*) ok "normal start -> full ruleset";; *) bad "normal start did not emit the ruleset";; esac
case "$out" in *'name: x'*) bad "frontmatter leaked into the ruleset";; *) ok "frontmatter stripped";; esac
rm -f "$d/.adhd-always-on"; [ -z "$(run "$HOOK_SRC" </dev/null)" ] && ok "no flag -> silent" || bad "emitted without the opt-in flag"
: > "$d/.i-have-adhd-always"; run "$HOOK_SRC" </dev/null >/dev/null
{ [ -f "$d/.adhd-always-on" ] && [ ! -f "$d/.i-have-adhd-always" ]; } && ok "legacy plugin flag migrated (plugin hook becomes a no-op)" || bad "legacy flag not migrated"

if grep -rl "Local patch" "$HOME/.claude/plugins/cache/i-have-adhd" --include='always-on.*' 2>/dev/null | grep -q .; then
  bad "plugin cache still carries a local patch (a plugin update would erase it): $(grep -rl 'Local patch' "$HOME/.claude/plugins/cache/i-have-adhd" --include='always-on.*' | head -1)"
else ok "plugin cache hooks carry no local patch"; fi
[ ! -f "$HOME/.claude/.i-have-adhd-always" ] && ok "plugin's legacy flag absent (plugin hook is a no-op)" || bad "legacy flag present: plugin would also inject the full ruleset in lean sessions"
[ "$fail" = 0 ] && echo "selftest: PASS" || echo "selftest: FAIL"
exit $fail
