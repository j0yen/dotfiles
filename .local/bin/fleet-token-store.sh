#!/usr/bin/env bash
# fleet-token-store.sh -- the account -> setup-token store behind fleet-token-rotate.sh. NEVER prints a token.
#   add <account> [--tty]   read the token from STDIN into ${XDG_CONFIG_HOME:-~/.config}/fleet-token/store/<account> (0600, dir 0700).
#                           Refuses when stdin is a terminal unless --tty (then a silent prompt), and refuses ANY argv token.
#   list                    `<account> <age-days>` per entry, nothing else
#   rm <account>            remove an entry (shredded)
#   current <account>       bootstrap: write ~/.cache/fleet-dash/token.json {account, placed_at:null, by:"hand", trigger:"seed"}
#                           ONLY when it does not exist (it names the account the fleet already runs on; rotate treats a missing file as unknown)
#   --selftest              throwaway HOME, canary token, fakes; no real store, no real token
# Exit: 0 ok, 1 not found / failed, 64 usage or refusal.
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
usage() { echo 'usage: fleet-token-store.sh add <account> [--tty] (token on stdin) | list | rm <account> | current <account> | --selftest' >&2; exit 64; }

cmd_add() {
  local acct="${1:-}" tty=0 tok tmp
  shift || true
  ft_valid_account "$acct" || { echo "fleet-token-store: bad or missing account name" >&2; exit 64; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --tty) tty=1 ;;
      *) echo "fleet-token-store: REFUSED: a token on the command line lands in ps and shell history; pipe it on stdin" >&2; exit 64 ;;
    esac
    shift
  done
  if [ -t 0 ]; then
    [ "$tty" = 1 ] || { echo "fleet-token-store: REFUSED: stdin is a terminal; pipe the token in, or pass --tty for a silent prompt" >&2; exit 64; }
    IFS= read -rs -p "token for $acct (hidden): " tok; echo >&2
  else
    tok="$(head -c 8192 | grep -m1 -v '^[[:space:]]*$' || true)"
  fi
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  [ -n "$tok" ] || { echo "fleet-token-store: REFUSED: empty token" >&2; exit 1; }
  ( umask 077; mkdir -p "$FT_STORE" )
  chmod 700 "$FT_CFG" "$FT_STORE"
  tmp="$(umask 077; mktemp "$FT_STORE/.add.XXXXXX")"
  printf '%s\n' "$tok" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$FT_STORE/$acct"
  tok=""
  echo "stored: $acct"
}

cmd_list() {
  local f now; now="$(ft_now)"
  [ -d "$FT_STORE" ] || return 0
  for f in "$FT_STORE"/*; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "$(basename "$f")" "$(( (now - $(stat -c %Y "$f")) / 86400 ))"
  done
}

cmd_rm() {
  local acct="${1:-}"
  ft_valid_account "$acct" || { echo "fleet-token-store: bad or missing account name" >&2; exit 64; }
  [ -f "$FT_STORE/$acct" ] || { echo "fleet-token-store: no store entry '$acct'" >&2; exit 1; }
  shred -u "$FT_STORE/$acct" 2>/dev/null || rm -f "$FT_STORE/$acct"
  echo "removed: $acct"
}

cmd_current() {
  local acct="${1:-}" tmp
  ft_valid_account "$acct" || { echo "fleet-token-store: bad or missing account name" >&2; exit 64; }
  if [ -e "$FT_TOKJSON" ]; then echo "token.json exists (account $(ft_current)): unchanged"; return 0; fi
  mkdir -p "$FT_DASH"
  tmp="$(umask 077; mktemp "$FT_DASH/.token.XXXXXX")"
  jq -n --arg a "$acct" '{account:$a, placed_at:null, by:"hand", trigger:"seed"}' >"$tmp"
  mv -f "$tmp" "$FT_TOKJSON"
  echo "seeded token.json: account $acct"
}

selftest() {
  local T out rc c=canary-tok-7f3e9a; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  ( set +e; ft_st_env "$T"; FT_ST_T="$T"
    local o="$T/out" e="$T/err"
    run() { "$SELF" "$@" >"$o" 2>"$e"; }
    # 1. add from stdin
    printf '%s\n' "$c" | run add jyen.pm; rc=$?
    [ "$rc" = 0 ] && [ "$(cat "$FT_STORE/jyen.pm")" = "$c" ]; ft_st_chk "add from stdin: exit 0, store file holds the token" $?
    [ "$(stat -c %a "$FT_STORE/jyen.pm")" = 600 ] && [ "$(stat -c %a "$FT_STORE")" = 700 ] && [ "$(stat -c %a "$FT_CFG")" = 700 ]; ft_st_chk "store file 0600, store dir 0700, fleet-token dir 0700" $?
    ! grep -qF "$c" "$o" "$e"; ft_st_chk "add: the token is in neither stdout nor stderr" $?
    # 2. refusals
    run add jyen.tech "$c"; rc=$?
    [ "$rc" = 64 ] && [ ! -e "$FT_STORE/jyen.tech" ] && grep -q 'REFUSED' "$e"; ft_st_chk "argv token: refused (exit 64), nothing stored, the token is not echoed" $?
    # a pty for stdin: script(1) when present
    if command -v script >/dev/null 2>&1; then
      script -qec "$SELF add jyen.tech" /dev/null >"$o" 2>"$e" </dev/null || true
      [ ! -e "$FT_STORE/jyen.tech" ] && grep -aq 'REFUSED' "$o" "$e"; ft_st_chk "stdin a tty without --tty: refused, nothing stored" $?
    else ft_st_chk "stdin a tty without --tty: refused (script(1) missing: skipped)" 0; fi
    printf '\n  \n' | run add jyen.tech; rc=$?
    [ "$rc" = 1 ] && [ ! -e "$FT_STORE/jyen.tech" ]; ft_st_chk "empty stdin: refused" $?
    printf '%s\n' "$c" | run add '../evil'; rc=$?
    [ "$rc" = 64 ] && [ ! -e "$FT_STORE/../evil" ]; ft_st_chk "path-shaped account name refused" $?
    # 3. list: name + age only
    printf '%s-2\n' "$c" | run add jyen.tech
    touch -d "$(date -d "@$(( $(ft_now) - 5 * 86400 - 60 ))" '+%F %T')" "$FT_STORE/jyen.tech"
    run list; rc=$?
    [ "$rc" = 0 ] && [ "$(sort "$o" | tr '\n' ';')" = "jyen.pm 0;jyen.tech 5;" ] && ! grep -qF "$c" "$o"; ft_st_chk "list: '<account> <age-days>' only ($(sort "$o" | tr '\n' ';'))" $?
    # 4. current: seeds once, never overwrites
    run current jyen.pm; rc=$?
    [ "$rc" = 0 ] && [ "$(jq -c . "$FT_TOKJSON")" = '{"account":"jyen.pm","placed_at":null,"by":"hand","trigger":"seed"}' ]; ft_st_chk "current: seeds token.json {account, placed_at:null, by:hand, trigger:seed}" $?
    run current jyen.tech; rc=$?
    [ "$rc" = 0 ] && [ "$(jq -r .account "$FT_TOKJSON")" = jyen.pm ]; ft_st_chk "current: an existing token.json is never overwritten" $?
    # 5. rm
    run rm jyen.tech; rc=$?
    [ "$rc" = 0 ] && [ ! -e "$FT_STORE/jyen.tech" ]; ft_st_chk "rm removes the entry" $?
    run rm jyen.tech; rc=$?
    [ "$rc" = 1 ]; ft_st_chk "rm of a missing entry: exit 1" $?
    ft_st_done fleet-token-store
  ) ; return $?
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -ge 1 ] || usage
ft_paths
sub="$1"; shift
case "$sub" in
  add) cmd_add "$@" ;;
  list) cmd_list ;;
  rm) cmd_rm "$@" ;;
  current) cmd_current "$@" ;;
  *) usage ;;
esac
