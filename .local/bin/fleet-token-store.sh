#!/usr/bin/env bash
# fleet-token-store.sh -- the account -> setup-token store behind fleet-token-rotate.sh. NEVER prints a token.
#   add <account> [--tty]   read STDIN (first 64 KiB) and store the LAST sk-ant-oat... match into ${XDG_CONFIG_HOME:-~/.config}/fleet-token/store/<account>
#                           (0600, dir 0700). Input with no such token (e.g. TUI escape codes from `claude setup-token`) is REFUSED, store untouched.
#                           Refuses when stdin is a terminal unless --tty (then a silent prompt, same validation), and refuses ANY argv token.
#   list                    `<account> <age-days>` per entry, nothing else
#   check                   `<account> ok|BAD` per entry (BAD = no sk-ant-oat token in the file); exit 1 if any BAD
#   rm <account>            remove an entry (shredded)
#   current <account>       bootstrap: write ~/.cache/fleet-dash/token.json {account, placed_at:null, by:"hand", trigger:"seed"}
#                           ONLY when it does not exist (it names the account the fleet already runs on; rotate treats a missing file as unknown)
#   block <account> <when> [why...]   refuse <account> for rotation (watcher + weekly schedule) until <when>: an America/Los_Angeles date ("2026-10-26 21:00",
#                           "Oct 26, 9pm", "3:30pm") or an epoch; must be in the future. Writes $FT_STATE/blocked-until-<account> + blocks.log. Prints the
#                           stored time as 2026-10-26T21:00-07:00. No store entry needed.
#   unblock <account>       drop the block (logged)
#   blocked                 `<account> <iso> (<why>)` per ACTIVE block
#   --selftest              throwaway HOME, canary token, fakes; no real store, no real token
# Exit: 0 ok, 1 not found / failed, 64 usage or refusal.
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
usage() { echo 'usage: fleet-token-store.sh add <account> [--tty] (token on stdin) | list | check | rm <account> | current <account> | block <account> <when> [why] | unblock <account> | blocked | --selftest' >&2; exit 64; }

cmd_add() {
  local acct="${1:-}" tty=0 tok raw tmp n
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
    IFS= read -rs -p "token for $acct (hidden): " raw; echo >&2
  else
    raw="$(head -c 65536 | tr -d '\0')"
  fi
  # only an sk-ant-oat token is ever stored: `claude setup-token` output leads with TUI escape codes, so the first line is junk
  tok="$(printf '%s' "$raw" | grep -a -o 'sk-ant-oat[A-Za-z0-9_-]*' | tail -n1 || true)"
  if [ -z "$tok" ]; then
    n="$(printf '%s' "$raw" | wc -c)"; raw=""
    echo "fleet-token-store: REFUSED: no sk-ant-oat token in input (got $n bytes); pipe: claude setup-token 2>/dev/null | grep -o 'sk-ant-oat[A-Za-z0-9_-]*' | tail -1 | fleet-token-store.sh add <acct>" >&2
    exit 1
  fi
  raw=""
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

cmd_check() {
  local f bad=0
  [ -d "$FT_STORE" ] || return 0
  for f in "$FT_STORE"/*; do
    [ -f "$f" ] || continue
    if grep -aq 'sk-ant-oat[A-Za-z0-9_-]' "$f" 2>/dev/null; then printf '%s ok\n' "$(basename "$f")"
    else printf '%s BAD\n' "$(basename "$f")"; bad=1; fi
  done
  return "$bad"
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

cmd_block() {
  local acct="${1:-}" when="${2:-}" why ep now
  ft_valid_account "$acct" || { echo "fleet-token-store: bad or missing account name" >&2; exit 64; }
  [ -n "$when" ] || { echo "fleet-token-store: block needs a time (America/Los_Angeles date or epoch)" >&2; exit 64; }
  shift 2; why="${*:-hand}"
  ep="$(ft_parse_la_date "$when")" || { echo "fleet-token-store: REFUSED: cannot parse '$when' as a date" >&2; exit 64; }
  now="$(ft_now)"
  [ "$ep" -gt "$now" ] || { echo "fleet-token-store: REFUSED: $(ft_la_iso "$ep") is not in the future" >&2; exit 64; }
  ft_block "$acct" "$ep" "$why"
  echo "blocked: $acct until $(ft_la_iso "$ep")"
}

cmd_unblock() {
  local acct="${1:-}"
  ft_valid_account "$acct" || { echo "fleet-token-store: bad or missing account name" >&2; exit 64; }
  ft_unblock "$acct"
  echo "unblocked: $acct"
}

cmd_blocked() {
  local f a r now; now="$(ft_now)"
  for f in "$FT_STATE"/blocked-until-*; do
    [ -f "$f" ] || continue
    a="${f##*/blocked-until-}"; r="$(ft_block_reason "$a" "$now")"
    [ -z "$r" ] || printf '%s %s\n' "$a" "$r"
  done
}

selftest() {
  local T out rc c=sk-ant-oat01-canary-tok-7f3e9a; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
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
    # 2b. TUI junk before the token: only the token is stored; junk-only input is refused and leaves an entry unchanged
    printf '\033[?25l\033[2J\033[1;1H  Welcome to Claude Code\n\033[0m\n   Your OAuth token:\n\n%s\033[0m\n' "${c}-tui" | run add jyen.tui; rc=$?
    [ "$rc" = 0 ] && [ "$(cat "$FT_STORE/jyen.tui")" = "${c}-tui" ]; ft_st_chk "TUI junk then token: only the token is stored" $?
    printf '%s\n%s\n' "${c}-first" "${c}-last" | run add jyen.tui
    [ "$(cat "$FT_STORE/jyen.tui")" = "${c}-last" ]; ft_st_chk "two tokens in input: the last one is stored" $?
    printf '\033[?25l\033[2J\033[1;1H  Welcome to Claude Code\n' | run add jyen.tui; rc=$?
    [ "$rc" = 1 ] && [ "$(cat "$FT_STORE/jyen.tui")" = "${c}-last" ] && grep -q 'REFUSED: no sk-ant-oat token in input (got [0-9]* bytes)' "$e"; ft_st_chk "junk-only input: refused (exit 1), existing entry unchanged" $?
    printf 'canary-tok-7f3e9a-notoken\n' | run add jyen.junk; rc=$?
    [ "$rc" = 1 ] && [ ! -e "$FT_STORE/jyen.junk" ] && ! grep -qF 'canary-tok-7f3e9a' "$e"; ft_st_chk "non-oat text refused, not echoed, nothing stored" $?
    # check: ok/BAD per entry, exit 1 on any BAD, no token content
    run check; rc=$?
    [ "$rc" = 0 ] && ! grep -q BAD "$o" && grep -q '^jyen.tui ok$' "$o" && ! grep -qF "$c" "$o"; ft_st_chk "check: all good entries -> ok, exit 0, no token printed" $?
    ( umask 077; printf '\033[?25l\033[2J\n' >"$FT_STORE/jyen.bad" )
    run check; rc=$?
    [ "$rc" = 1 ] && grep -q '^jyen.bad BAD$' "$o" && grep -q '^jyen.tui ok$' "$o" && ! grep -qF "$c" "$o"; ft_st_chk "check: a junk entry is BAD, exit 1" $?
    rm -f "$FT_STORE/jyen.bad" "$FT_STORE/jyen.tui"
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
    # 6. block / unblock / blocked (fake clock 1790000000 = Mon 2026-09-21 07:13 PDT)
    export FLEET_TOKEN_NOW_EPOCH=1790000000
    run block jyen.tech "2026-10-26 21:00" weekly limit; rc=$?
    [ "$rc" = 0 ] && grep -qx 'blocked: jyen.tech until 2026-10-26T21:00-07:00' "$o" && [ "$(cat "$FT_STATE/blocked-until-jyen.tech")" = 1793073600 ] \
      && grep -q ' account=jyen.tech until=1793073600 until_iso=2026-10-26T21:00-07:00 why=weekly limit$' "$FT_BLOCKLOG"; ft_st_chk "block <acct> '2026-10-26 21:00': epoch file + blocks.log line + printed ISO carries the offset" $?
    run blocked; [ "$(cat "$o")" = "jyen.tech blocked until 2026-10-26T21:00-07:00 (weekly limit)" ]; ft_st_chk "blocked lists the active block with its reason" $?
    run block jyen.pm "Oct 26, 9pm"; [ "$(cat "$FT_STATE/blocked-until-jyen.pm")" = 1793073600 ]; ft_st_chk "block with the weekly 429 text form 'Oct 26, 9pm' -> same epoch" $?
    run block jyen.pm "3:30pm"; [ "$(cat "$FT_STATE/blocked-until-jyen.pm")" = 1790029800 ]; ft_st_chk "block with the session form '3:30pm' -> today 3:30 PM LA" $?
    run block jyen.pm "not a date"; rc=$?
    [ "$rc" = 64 ] && grep -q 'REFUSED' "$e" && [ "$(cat "$FT_STATE/blocked-until-jyen.pm")" = 1790029800 ]; ft_st_chk "unparseable time: refused (64), existing block untouched" $?
    run block jyen.pm "2026-09-01 10:00"; rc=$?
    [ "$rc" = 64 ] && grep -q 'not in the future' "$e"; ft_st_chk "a time in the past: refused (64)" $?
    run block '../evil' "2026-10-26 21:00"; rc=$?
    [ "$rc" = 64 ] && [ ! -e "$FT_STATE/blocked-until-../evil" ]; ft_st_chk "path-shaped account: refused" $?
    export FLEET_TOKEN_NOW_EPOCH=1793073601
    run blocked; [ ! -s "$o" ]; ft_st_chk "blocked: an expired block is not listed" $?
    export FLEET_TOKEN_NOW_EPOCH=1790000000
    run unblock jyen.tech; rc=$?
    [ "$rc" = 0 ] && [ ! -e "$FT_STATE/blocked-until-jyen.tech" ] && grep -q 'account=jyen.tech until=cleared' "$FT_BLOCKLOG"; ft_st_chk "unblock removes the file and logs it" $?
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
  check) cmd_check ;;
  rm) cmd_rm "$@" ;;
  current) cmd_current "$@" ;;
  block) cmd_block "$@" ;;
  unblock) cmd_unblock "$@" ;;
  blocked) cmd_blocked ;;
  *) usage ;;
esac
