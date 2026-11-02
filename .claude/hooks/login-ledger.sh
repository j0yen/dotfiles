#!/usr/bin/env bash
# login-ledger: a carbon Claude session's account change is recorded the turn it happens (A264; Joe 10-31 10:19 PM "document it. keep it consistent.", approvals #171).
# Account = oauthAccount.emailAddress in $LOGIN_LEDGER_CLAUDE_JSON (default ~/.claude.json), an address, never a token.
# Class = $WM_SEAT, else "plain". When the account differs from the last `/login → <account>` line for that class in $LOGIN_LEDGER_MEMORY
#   (default the quota-ledger memory file), append `- <date> <time>: <class> /login → <account>` and write the class's account to $LOGIN_LEDGER_STATE
#   (default ~/.cache/fleet-dash/login-ledger.json, key accounts.<class>) for the fleet-dash collector to merge into status.json.
# Hook (SessionStart / UserPromptSubmit): stdin ignored, never fails a turn, prints nothing. `--selftest` runs the cases in a throwaway dir.
set -u
CJ="${LOGIN_LEDGER_CLAUDE_JSON:-$HOME/.claude.json}"
MEM="${LOGIN_LEDGER_MEMORY:-$HOME/.claude/projects/-home-jsy/memory/reference_claude_account_quota_ledger_20261023.md}"
STATE="${LOGIN_LEDGER_STATE:-$HOME/.cache/fleet-dash/login-ledger.json}"

run() {
  local class acct last now
  class="${WM_SEAT:-plain}"; class="${class//[^A-Za-z0-9_-]/}"; [ -n "$class" ] || class=plain
  [ -r "$CJ" ] && [ -w "$MEM" ] || return 0
  acct="$(jq -r '.oauthAccount.emailAddress // empty' "$CJ" 2>/dev/null)"
  [[ "$acct" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || return 0
  last="$(grep -F " $class /login → " "$MEM" | tail -n1 | sed -E 's/.*\/login → ([^ ]+).*/\1/')"
  if [ "$last" != "$acct" ]; then
    now="$(date '+%m-%d %-I:%M %p %Z')"
    printf '%s\n' "- $now: $class /login → $acct (login-ledger hook)" >> "$MEM"
  fi
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || return 0
  local cur='{}'; [ -s "$STATE" ] && cur="$(cat "$STATE")"
  printf '%s' "$cur" | jq --arg c "$class" --arg a "$acct" '.accounts[$c]=$a' > "$STATE.tmp.$$" 2>/dev/null \
    && mv -f "$STATE.tmp.$$" "$STATE" || rm -f "$STATE.tmp.$$"
}

selftest() {
  local d p=0 f=0; d="$(mktemp -d)"
  chk() { if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got '$2' want '$3')"; fi; }
  CJ="$d/c.json"; MEM="$d/m.md"; STATE="$d/s.json"
  printf 'x\n' > "$d/m.md"; printf '{"oauthAccount":{"emailAddress":"a@x.dev"},"token":"SECRET"}' > "$d/c.json"
  (unset WM_SEAT; run); chk "first login appended" "$(grep -c 'plain /login → a@x.dev' "$d/m.md")" 1
  (unset WM_SEAT; run); chk "same account not repeated" "$(grep -c '/login →' "$d/m.md")" 1
  printf '{"oauthAccount":{"emailAddress":"b@x.dev"}}' > "$d/c.json"
  (WM_SEAT=aide run); chk "other class has its own line" "$(grep -c 'aide /login → b@x.dev' "$d/m.md")" 1
  (unset WM_SEAT; run); chk "changed account appended" "$(grep -c 'plain /login → b@x.dev' "$d/m.md")" 1
  chk "state accounts.plain" "$(jq -r .accounts.plain "$d/s.json")" b@x.dev
  chk "state accounts.aide" "$(jq -r .accounts.aide "$d/s.json")" b@x.dev
  chk "token never written" "$(cat "$d/m.md" "$d/s.json" | grep -c SECRET)" 0
  rm -rf "$d"; echo "selftest: $p PASS $f FAIL"; [ "$f" = 0 ]
}

case "${1:-}" in
  --selftest) selftest ;;
  *) cat >/dev/null 2>&1; run 2>/dev/null; exit 0 ;;
esac
