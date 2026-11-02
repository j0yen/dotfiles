#!/usr/bin/env bash
# walk-guard drift test: contracts/walk-guard.json is the ONE source for the hook, its refusal text,
# the pgrep pattern and the selftest; nothing the contract names may be hard-coded in the hook
# sources, and the one allowlisted copy (the bash fallback host list) must equal the contract.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
P="$ROOT/.claude/plugins/walk-guard"
C="$P/contracts/walk-guard.json"
H="$P/hooks/walk-guard.sh"
PY="$P/hooks/walk_guard.py"
fail=0
ok()  { echo "ok - $1"; }
bad() { echo "NOT OK - $1"; fail=1; }
check() { # $1=description, rest=command
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

for f in "$C" "$P/.claude-plugin/plugin.json" "$P/hooks/hooks.json"; do
  check "parses: ${f#$ROOT/}" jq -e . "$f"
done
check "hook script is executable" test -x "$H"
check "engine is executable" test -x "$PY"
cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$P/hooks/hooks.json")"
[ "$cmd" = '"${CLAUDE_PLUGIN_ROOT}/hooks/walk-guard.sh"' ] && ok "hooks.json registers walk-guard.sh through CLAUDE_PLUGIN_ROOT" || bad "hooks.json command is '$cmd'"
[ "$(jq -r '.hooks.PreToolUse[0].matcher' "$P/hooks/hooks.json")" = "Bash" ] && ok "hooks.json matcher is Bash" || bad "hooks.json matcher"

# contract shape
check "contract has commands, roots, prune_dirs, wrappers, hosts" \
  jq -e '.commands and .roots and .prune_dirs and .wrappers.ionice and .wrappers.nice and .wrappers.timeout_max and .hosts.ssh_targets and .hosts.local_guarded and .hosts.never' "$C"
for c in grep rg find du ls; do
  check "contract lists command $c" jq -e --arg c "$c" '.commands[$c]' "$C"
done
check "local_guarded is a subset of ssh_targets" \
  jq -e '(.hosts.local_guarded - .hosts.ssh_targets) == []' "$C"
check "never is disjoint from ssh_targets" jq -e '([.hosts.never[]] - [.hosts.ssh_targets[]]) == .hosts.never' "$C"

# no contract value is hard-coded in the engine or the shell entry
vals="$(jq -r '[.roots[].path, .exact_roots[], .prune_dirs[], .hosts.ssh_targets[], .hosts.local_guarded[], .hosts.never[]] | map(select(. != "~")) | .[]' "$C" | sort -u)"
hard=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  # engine: no occurrence at all. shell entry: only the allowlisted FALLBACK_SSH_HOSTS line may name a host.
  if grep -vE '^\s*#' "$PY" | grep -qwF -- "$v"; then hard="$hard $v(engine)"; fi
  if grep -vE '^\s*#|^FALLBACK_SSH_HOSTS=' "$H" | grep -qwF -- "$v"; then hard="$hard $v(entry)"; fi
done <<< "$vals"
[ -z "$hard" ] && ok "no contract root/prune/host literal in hook sources" || bad "hard-coded contract values:$hard"
wl="$(jq -r '"-c" + (.wrappers.ionice|sub("^-c";"")), .wrappers.nice, (.wrappers.timeout_max|tostring)' "$C" | tr '\n' ' ')"
for lit in "ionice -c3" "nice -n19" "timeout 600"; do
  if grep -vE '^\s*#' "$PY" "$H" | grep -qF -- "$lit"; then bad "wrapper literal '$lit' hard-coded in hook"; else ok "wrapper literal '$lit' not hard-coded"; fi
done

# the allowlisted copy: bash fallback hosts == contract ssh_targets
fb="$(sed -n 's/^FALLBACK_SSH_HOSTS="\(.*\)"/\1/p' "$H" | tr ' ' '\n' | sort | paste -sd' ')"
ct="$(jq -r '.hosts.ssh_targets[]' "$C" | sort | paste -sd' ')"
[ "$fb" = "$ct" ] && ok "fallback host list equals contract ssh_targets ($ct)" || bad "fallback hosts '$fb' != contract '$ct'"

# generated artifacts follow the contract
pat="$("$H" --pgrep-pattern)"
[ -n "$pat" ] && ok "pgrep pattern generated" || bad "pgrep pattern empty"
for line in "grep -r foo /x" "grep -rl foo /x" "/usr/bin/find /mnt/x -name y" "rg foo /x" "du -sh /x" "ls -R /x"; do
  printf '%s\n' "$line" | grep -Eq -- "$pat" && ok "pgrep matches: $line" || bad "pgrep misses: $line"
done
for line in "ls -la /x" "grep foo file.txt" "vim find.txt" "ssh redbaron true"; do
  printf '%s\n' "$line" | grep -Eq -- "$pat" && bad "pgrep wrongly matches: $line" || ok "pgrep ignores: $line"
done
tpl="$("$H" --template)"
for d in $(jq -r '.prune_dirs[]' "$C"); do
  case "$tpl" in *"--exclude-dir=$d"*) ok "template names prune dir $d" ;; *) bad "template misses prune dir $d" ;; esac
done
case "$tpl" in *"ionice -c3 nice -n19 timeout 600"*) ok "template carries the wrapper chain" ;; *) bad "template lacks wrapper chain" ;; esac

# drift is detected: a contract with a different root changes the refusal decision
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
jq '.roots += [{"path":"/srv/zz","depth":1}]' "$C" > "$t/c.json"
req='{"tool_input":{"command":"grep -r x /srv/zz/a"}}'
a="$(printf '%s' "$req" | WALK_GUARD_HOST=redbaron bash "$H" >/dev/null 2>&1; echo $?)"
b="$(printf '%s' "$req" | WALK_GUARD_HOST=redbaron WALK_GUARD_CONTRACT="$t/c.json" bash "$H" >/dev/null 2>&1; echo $?)"
[ "$a" = 0 ] && [ "$b" = 2 ] && ok "a root added to the contract changes the decision with no code change" || bad "contract edit not honoured (default=$a edited=$b)"
exit $fail
