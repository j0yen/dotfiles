#!/usr/bin/env bash
# fleet-token-place.sh [--account <acct>] [--check-only] <token-file> — place a Claude setup-token on carbon, redbaron, ryzen7, orch
# (~/.config/environment.d/90-claude-oauth.conf, 0600). Never prints the token. Verifies each host with a
# print-mode haiku call under systemd-run (the daemon's env path). Daemon restarts are the seats' job.
# Block list (fleet-token-store.sh block): before anything is placed, the token's account is resolved (--account, else the store entry whose
# token sha8 matches the file) and an ACTIVE block refuses the placement: exit 3, message on stderr, nothing written on any host.
# --check-only runs that resolution + block check and exits 0 (allowed) or 3 (blocked) without placing.
set -euo pipefail
set +x
. "$HOME/.local/lib/fleet-token-lib.sh"
ft_paths
acct=""; check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --account) acct="${2:?--account needs a name}"; shift 2 ;;
    --check-only) check=1; shift ;;
    *) break ;;
  esac
done
f=${1:?token file}; tok=$(grep -o 'sk-ant-oat[A-Za-z0-9_-]*' "$f" | head -1); [ -n "$tok" ] || { echo "no token in $f"; exit 1; }
if [ -z "$acct" ]; then
  want="$(ft_sha8 "$f")"
  for e in "$FT_STORE"/*; do
    [ -f "$e" ] || continue
    [ "$(ft_sha8 "$e")" = "$want" ] && { acct="${e##*/}"; break; }
  done
fi
if [ -n "$acct" ]; then
  ft_valid_account "$acct" || { echo "fleet-token-place: bad account name" >&2; exit 64; }
  why="$(ft_block_reason "$acct" "$(ft_now)")"
  [ -z "$why" ] || { echo "fleet-token-place: REFUSED: account $acct is $why (fleet-token-store.sh blocked); nothing placed" >&2; exit 3; }
else
  echo "fleet-token-place: WARN token matches no store entry; block list not checked (pass --account <acct>)" >&2
fi
[ "$check" = 0 ] || { echo "fleet-token-place: check-only: ${acct:-unknown account} not blocked"; exit 0; }
for h in carbon redbaron ryzen7 orch; do
  if [ "$h" = carbon ]; then
    umask 077; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" > ~/.config/environment.d/90-claude-oauth.conf; set -a; . ~/.config/environment.d/90-claude-oauth.conf; set +a; systemctl --user import-environment CLAUDE_CODE_OAUTH_TOKEN; rc=0
  else
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" | ssh -o ConnectTimeout=10 "$h" 'umask 077; mkdir -p ~/.config/environment.d; cat > ~/.config/environment.d/90-claude-oauth.conf; set -a; . ~/.config/environment.d/90-claude-oauth.conf; set +a; systemctl --user import-environment CLAUDE_CODE_OAUTH_TOKEN' && rc=0 || rc=$?
  fi
  echo "$h placed rc=$rc $(date '+%I:%M:%S %p')"
done
for h in carbon redbaron ryzen7 orch; do
  cmd='set -a; . ~/.config/environment.d/90-claude-oauth.conf; set +a; out=$(timeout 90 claude -p "reply with the single word ok" --model claude-haiku-5-5 2>&1 | tail -1); case "$out" in *ok*|*OK*) echo verify=ok;; *) echo "verify=FAIL ${out:0:80}";; esac'
  if [ "$h" = carbon ]; then r=$(bash -lc "$cmd"); else r=$(ssh -o ConnectTimeout=10 "$h" "bash -lc '$cmd'" 2>&1 | tail -1); fi
  echo "$h $r"
done
shred -u "$f" && echo "local token file shredded"
