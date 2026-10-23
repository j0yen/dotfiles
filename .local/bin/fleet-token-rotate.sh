#!/usr/bin/env bash
# fleet-token-rotate.sh <account> --by <who> --trigger <429|schedule|hand> [--why <text>] [--evidence <text>]
#   Moves the whole fleet to another Claude account's setup-token from the store (fleet-token-store.sh). NEVER prints a token.
#   1. refuse (exit 1) when the store lacks <account>; token.json (fleet-dash) already names it -> `no-op: <account> already current`, exit 0
#      (a missing token.json = unknown = allowed; seed it with `fleet-token-store.sh current <account>`)
#   2. PRE-VERIFY: ONE haiku call on carbon with the candidate token in THAT call's environment only
#      (`CLAUDE_CODE_OAUTH_TOKEN=<tok> timeout 60 claude -p --model claude-haiku-5-5 'reply ok'`, output discarded). Fails -> ALARM, exit 2, nothing placed.
#   3. copy the store file to a 0600 temp under $XDG_RUNTIME_DIR (else a 0700 mktemp dir under ~/.cache), trap-shredded on every exit path,
#      run fleet-token-place.sh <temp>. Place failure (nonzero exit, `placed rc=<n>`, `verify=FAIL`) -> RE-PLACE the previous account's store entry, ALARM, exit 3.
#   4. success: token.json {account, placed_at, by, trigger, previous, previous_reset_at}; one line in ~/.local/state/fleet-token/rotations.log;
#      bell ctl rb r7 (seat-event.sh); start seat-tick@ctl/rb/r7 (--no-block: a tick is a oneshot that can run for hours); one wm-decide row (aide, other, carbon).
#      previous_reset_at = the largest quota_wait_until in ctl/rb/r7-tick.json (epoch; null when none): the watcher will not rotate back before it.
# Daemons and adopted units keep the OLD token until restarted (the bell says so); this script restarts nothing but the three seat ticks.
# Exit: 0 rotated / no-op, 1 refused, 2 pre-verify failed, 3 place failed (rolled back), 64 usage.
# Env (all injectable, default the real thing): FLEET_TOKEN_VERIFY_CMD FLEET_TOKEN_PLACE_CMD FLEET_TOKEN_BELL_CMD FLEET_TOKEN_SYSTEMCTL FLEET_TOKEN_RECORD_CMD
#   XDG_CONFIG_HOME XDG_RUNTIME_DIR FLEET_DASH_DIR FLEET_TOKEN_STATE_DIR; FLEET_TOKEN_SELFTEST=1 + FLEET_TOKEN_NOW_EPOCH (fake clock, selftest only).
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
usage() { echo 'usage: fleet-token-rotate.sh <account> --by <who> --trigger <429|schedule|hand> [--why <text>] [--evidence <text>]  |  --selftest' >&2; exit 64; }

TMPS=(); OWN_DIR=""
cleanup() {
  local f
  for f in "${TMPS[@]+"${TMPS[@]}"}"; do [ -e "$f" ] && { shred -u "$f" 2>/dev/null || rm -f "$f"; }; done
  [ -z "$OWN_DIR" ] || rmdir "$OWN_DIR" 2>/dev/null || true
}
# mk_temp: a 0600 file for place to read, never in /tmp. Sets MK_TMP (NOT a $(...) call: TMPS / OWN_DIR must be set in THIS shell for the trap)
mk_temp() {
  local d="${XDG_RUNTIME_DIR:-}" t
  if [ -z "$d" ] || [ ! -d "$d" ] || [ ! -w "$d" ]; then
    if [ -z "$OWN_DIR" ]; then
      mkdir -p "$HOME/.cache"
      OWN_DIR="$(umask 077; mktemp -d "$HOME/.cache/fleet-token-tmp.XXXXXX")"; chmod 700 "$OWN_DIR"
    fi
    d="$OWN_DIR"
  fi
  t="$(umask 077; mktemp "$d/fleet-token.XXXXXX")"; chmod 600 "$t"
  TMPS+=("$t"); MK_TMP="$t"
}

# pre_verify <storefile>: the token goes into the environment of this one call and nowhere else; output discarded
pre_verify() {
  local tok; tok="$(ft_token_of "$1")"
  [ -n "$tok" ] || return 1
  (
    set +x
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    cd "$HOME"
    if [ -n "${FLEET_TOKEN_VERIFY_CMD:-}" ]; then $FLEET_TOKEN_VERIFY_CMD; else timeout 60 claude -p --model claude-haiku-5-5 'reply ok'; fi
  ) >/dev/null 2>&1
}

# place_account <account>: 0 = placed and every host verified; the place script's own output is shown with the token (if it ever leaked) redacted
place_account() {
  local acct="$1" tmp out rc tok
  mk_temp; tmp="$MK_TMP"
  cat -- "$FT_STORE/$acct" >"$tmp"
  tok="$(ft_token_of "$tmp")"
  if out="$(${FLEET_TOKEN_PLACE_CMD:-fleet-token-place.sh} "$tmp" 2>&1)"; then rc=0; else rc=$?; fi
  [ -z "$tok" ] || out="${out//"$tok"/[redacted]}"
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  place: /'
  [ -e "$tmp" ] && { shred -u "$tmp" 2>/dev/null || rm -f "$tmp"; }
  [ "$rc" = 0 ] || { PLACE_WHY="place exit $rc"; return 1; }
  if printf '%s\n' "$out" | grep -Eq 'placed rc=[1-9]|verify=FAIL'; then
    PLACE_WHY="$(printf '%s\n' "$out" | grep -E 'placed rc=[1-9]|verify=FAIL' | head -n3 | tr '\n' ';' | cut -c1-200)"; return 1
  fi
  return 0
}

max_reset() {   # the largest quota_wait_until across the three tick.json files (epoch) or empty
  local s v best=""
  for s in $FT_SEATS; do
    v="$(jq -r '.quota_wait_until // empty' "$FT_DASH/$s-tick.json" 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    if [ -z "$best" ] || [ "$v" -gt "$best" ]; then best="$v"; fi
  done
  printf '%s' "$best"
}

rotate() {
  local acct="" by="" trigger="" why="" evid=""
  acct="${1:-}"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) by="${2:-}"; shift ;;
      --trigger) trigger="${2:-}"; shift ;;
      --why) why="${2:-}"; shift ;;
      --evidence) evid="${2:-}"; shift ;;
      *) usage ;;
    esac
    shift
  done
  ft_valid_account "$acct" || usage
  [[ "$by" =~ ^[A-Za-z0-9._@:+-]+$ ]] || usage
  case "$trigger" in 429|schedule|hand) ;; *) usage ;; esac

  [ -f "$FT_STORE/$acct" ] || { echo "fleet-token-rotate: REFUSED: no store entry for '$acct' (fleet-token-store.sh add $acct)" >&2; return 1; }
  mkdir -p "$FT_STATE" "$FT_DASH"
  exec 8>>"$FT_STATE/rotate.lock"
  flock -w 300 8 || { echo "fleet-token-rotate: another rotation holds the lock" >&2; return 1; }

  local prev; prev="$(ft_current)"
  if [ -n "$prev" ] && [ "$prev" = "$acct" ]; then echo "no-op: $acct already current"; return 0; fi
  local new8 prev8=""
  new8="$(ft_sha8 "$FT_STORE/$acct")"
  if [ -n "$prev" ] && [ -f "$FT_STORE/$prev" ]; then
    prev8="$(ft_sha8 "$FT_STORE/$prev")"
    if [ "$prev8" = "$new8" ]; then
      echo "fleet-token-rotate: REFUSED: '$acct' and the current '$prev' hold the same token (sha256 $new8)" >&2; return 1
    fi
  fi

  if ! pre_verify "$FT_STORE/$acct"; then
    ft_alarm "rotation to $acct ($trigger, by $by) NOT done: pre-verify haiku call with its token failed (token sha256 $new8); nothing placed, current stays '${prev:-unknown}'"
    return 2
  fi
  echo "pre-verify ok: $acct (token sha256 $new8)"

  PLACE_WHY=""
  if ! place_account "$acct"; then
    local rb="no previous account known: NOT rolled back"
    if [ -n "$prev" ] && [ -f "$FT_STORE/$prev" ]; then
      if place_account "$prev"; then rb="rolled back to '$prev' (placed and verified)"; else rb="rollback to '$prev' ALSO FAILED ($PLACE_WHY): hosts may hold mixed tokens"; fi
    elif [ -n "$prev" ]; then rb="previous '$prev' has no store entry: NOT rolled back"
    fi
    ft_alarm "rotation to $acct ($trigger, by $by) FAILED at place ($PLACE_WHY); $rb"
    return 3
  fi

  local ts iso reset rj
  ts="$(ft_now)"; iso="$(ft_iso "$ts")"; reset="$(max_reset)"
  local tmp; tmp="$(umask 077; mktemp "$FT_DASH/.token.XXXXXX")"
  jq -n --arg a "$acct" --arg at "$iso" --arg by "$by" --arg t "$trigger" --arg p "$prev" --arg r "$reset" \
    '{account:$a, placed_at:$at, by:$by, trigger:$t, previous:(if $p=="" then null else $p end), previous_reset_at:(if $r=="" then null else ($r|tonumber) end)}' >"$tmp"
  mv -f "$tmp" "$FT_TOKJSON"
  ( umask 077; printf '%s | ts=%s account=%s previous=%s by=%s trigger=%s previous_reset_at=%s\n' \
      "$iso" "$ts" "$acct" "${prev:-none}" "$by" "$trigger" "${reset:-null}" >>"$FT_ROTLOG" )
  echo "rotated: ${prev:-unknown} -> $acct ($trigger, by $by)"

  local text s
  text="TOKEN ROTATED to $acct ($trigger, by $by): daemons and adopted units keep the OLD token; rb runs rb-restart-precheck.sh before any wm-build restart"
  for s in $FT_SEATS; do
    EVENT_SOURCE=fleet-token ${FLEET_TOKEN_BELL_CMD:-seat-event.sh} "$s" "$text" >/dev/null 2>&1 || echo "fleet-token-rotate: WARN bell to $s failed" >&2
  done
  ${FLEET_TOKEN_SYSTEMCTL:-systemctl} --user start --no-block seat-tick@ctl seat-tick@rb seat-tick@r7 >/dev/null 2>&1 || echo "fleet-token-rotate: WARN seat-tick start failed" >&2

  local rv
  [ -n "$why" ] || why="trigger=$trigger by=$by"
  [ -n "$evid" ] || evid="pre-verify ok, place ok on every host"
  if rv="$(${FLEET_TOKEN_RECORD_CMD:-wm-decide} record --agent aide --kind other --target carbon \
      --what "TOKEN ROTATED to $acct ($trigger, by $by)" \
      --why "$why" \
      --evidence "$evid; token.json now account=$acct previous=${prev:-unknown} previous_reset_at=${reset:-null}; token sha256 new=$new8 old=${prev8:--}; rotations.log line written" \
      --reverse-text "fleet-token-rotate.sh ${prev:-<previous account>} --by <who> --trigger hand (the store keeps both entries; daemons and adopted units still hold the old token until restarted)" 2>&1)"; then
    echo "row: $(printf '%s' "$rv" | grep -Eo 'd-[A-Za-z0-9]+' | head -n1)"
  else
    ft_alarm "rotation to $acct done but the wm-decide row FAILED: $(printf '%s' "$rv" | head -n1 | cut -c1-120)"
  fi
  return 0
}

selftest() {
  local T c=canary-tok-7f3e9a; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  ( set +e; ft_st_env "$T"; FT_ST_T="$T"
    local o="$T/out" e="$T/err" rc A B C Bad Bp
    run() { "$SELF" "$@" >"$o" 2>"$e"; }
    fl() { cat "$FAKE_LOG_DIR/$1.log" 2>/dev/null; }
    tokj() { jq -r "$1" "$FT_TOKJSON"; }
    ft_st_store acctA "$c"; ft_st_store acctB "$c-2"; ft_st_store acctC "$c-3"; ft_st_store acctBad "$c-bad"; ft_st_store acctBp "$c-badplace"
    ft_st_store acctDup "$c"; ft_st_store acctV "$c-verifyfail"; ft_st_store acctX1 "$c-exit1"
    A="$(ft_sha8 "$FT_STORE/acctA")"; B="$(ft_sha8 "$FT_STORE/acctB")"; C="$(ft_sha8 "$FT_STORE/acctC")"
    local NOW=1790000000; export FLEET_TOKEN_NOW_EPOCH=$NOW

    # 1. refusals
    run nosuch --by t --trigger hand; rc=$?
    [ "$rc" = 1 ] && grep -q 'REFUSED' "$e" && [ ! -e "$FT_TOKJSON" ] && [ -z "$(fl place)" ] && [ -z "$(fl verify)" ]; ft_st_chk "missing store entry: refused (exit 1), nothing verified or placed, no token.json" $?
    run acctB --by t --trigger bogus; rc=$?; [ "$rc" = 64 ]; ft_st_chk "bad trigger: usage, exit 64" $?
    run acctB --by t --trigger hand "$c"; rc=$?; [ "$rc" = 64 ] && ! grep -qF "$c" "$e"; ft_st_chk "stray argv: exit 64, not echoed" $?
    [ -z "$(fl place)" ]; ft_st_chk "usage errors placed nothing" $?

    # 2. no-op when current
    "$(dirname "$SELF")/fleet-token-store.sh" current acctA >/dev/null
    run acctA --by t --trigger hand; rc=$?
    [ "$rc" = 0 ] && grep -qx 'no-op: acctA already current' "$o" && [ -z "$(fl place)" ] && [ -z "$(fl verify)" ] && [ -z "$(fl bell)" ] && [ ! -e "$FT_ROTLOG" ]; ft_st_chk "already current: 'no-op: acctA already current', exit 0, no verify/place/bell/log" $?
    # a candidate holding the SAME token as the current one is not a rotation
    run acctDup --by t --trigger hand; rc=$?
    [ "$rc" = 1 ] && grep -q 'same token' "$e" && [ -z "$(fl place)" ]; ft_st_chk "same token (sha256 prefix equal) as the current account: refused, nothing placed" $?

    # 3. pre-verify failure
    run acctBad --by t --trigger 429; rc=$?
    [ "$rc" = 2 ] && [ -z "$(fl place)" ] && [ -z "$(fl bell)" ] && [ -z "$(fl systemctl)" ] && [ "$(tokj .account)" = acctA ] && [ -z "$(fl record)" ] \
      && grep -q 'ALARM fleet-token: rotation to acctBad (429, by t) NOT done: pre-verify' "$FT_DASH/ctl-events.log"; ft_st_chk "pre-verify fails: exit 2, ALARM in ctl-events.log, NOTHING placed/belled/started, token.json unchanged" $?
    grep -Eq '^[0-9T:+-]+ \| fleet-token \| ALARM fleet-token: ' "$FT_DASH/ctl-events.log" && [ "$(stat -c %a "$FT_DASH/ctl-events.log")" = 600 ]; ft_st_chk "ALARM line shape '<ISO> | fleet-token | ALARM fleet-token: <text>', file 0600" $?
    [ -z "$(ls -A "$XDG_RUNTIME_DIR")" ]; ft_st_chk "pre-verify failure left no temp file" $?

    # 4. place failures roll back to the previous account
    : >"$FAKE_LOG_DIR/place.log"
    run acctBp --by t --trigger 429; rc=$?
    [ "$rc" = 3 ] && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 2 ] && [ "$(fl place | sed -n 2p | sed -E 's/.*sha8=([0-9a-f]{8}).*/\1/')" = "$A" ] \
      && [ "$(tokj .account)" = acctA ] && [ -z "$(fl bell)" ] && [ -z "$(fl systemctl)" ] && [ ! -e "$FT_ROTLOG" ] \
      && grep -q 'FAILED at place.*rolled back to .acctA. (placed and verified)' "$FT_DASH/ctl-events.log"; ft_st_chk "place reports a host rc!=0: exit 3, the previous entry (acctA) re-placed, ALARM, token.json/log/bells untouched" $?
    [ -z "$(ls -A "$XDG_RUNTIME_DIR")" ]; ft_st_chk "failed place: temp files shredded (runtime dir empty)" $?
    : >"$FAKE_LOG_DIR/place.log"
    run acctV --by t --trigger 429; rc=$?
    [ "$rc" = 3 ] && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 2 ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "place output 'verify=FAIL' counts as a failed place: rolled back" $?
    : >"$FAKE_LOG_DIR/place.log"
    run acctX1 --by t --trigger 429; rc=$?
    [ "$rc" = 3 ] && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 2 ] && [ -z "$(ls -A "$XDG_RUNTIME_DIR")" ]; ft_st_chk "place exiting 1: rolled back, runtime dir empty" $?

    # 5. success
    printf '{"quota_wait_until":%s}\n' "$((NOW + 600))" >"$FT_DASH/ctl-tick.json"; printf '{"quota_wait_until":%s}\n' "$((NOW + 5400))" >"$FT_DASH/rb-tick.json"; printf '{"quota_wait_until":null}\n' >"$FT_DASH/r7-tick.json"
    : >"$FAKE_LOG_DIR/place.log"; : >"$FAKE_LOG_DIR/record.log"; : >"$FAKE_LOG_DIR/bell.log"
    run acctB --by aide --trigger 429 --why "seats rb,r7 limited until X" --evidence "tick.json ctl,rb"; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctB ] && [ "$(tokj .previous)" = acctA ] && [ "$(tokj .trigger)" = 429 ] && [ "$(tokj .by)" = aide ] \
      && [ "$(tokj .previous_reset_at)" = "$((NOW + 5400))" ] && [ "$(tokj .placed_at)" = "$(date -d "@$NOW" -Iseconds)" ] && [ "$(stat -c %a "$FT_TOKJSON")" = 600 ]; ft_st_chk "success: token.json {account:acctB, previous:acctA, trigger, by, placed_at, previous_reset_at = max quota_wait_until}" $?
    [ "$(wc -l <"$FT_ROTLOG")" = 1 ] && grep -q "ts=$NOW account=acctB previous=acctA by=aide trigger=429 previous_reset_at=$((NOW + 5400))$" "$FT_ROTLOG"; ft_st_chk "success: one rotations.log line ($(cut -c1-110 "$FT_ROTLOG"))" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 1 ] && fl place | grep -q "sha8=$B dir=$XDG_RUNTIME_DIR mode=600"; ft_st_chk "success: ONE place call, temp under XDG_RUNTIME_DIR, mode 600, holds acctB's token" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/bell.log")" = 3 ] && [ "$(fl bell | awk '{print $1}' | tr '\n' ' ')" = "ctl rb r7 " ] \
      && fl bell | head -n1 | grep -qF 'TOKEN ROTATED to acctB (429, by aide): daemons and adopted units keep the OLD token; rb runs rb-restart-precheck.sh before any wm-build restart'; ft_st_chk "success: 3 bells (ctl rb r7) with the exact text" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/systemctl.log")" = 1 ] && fl systemctl | grep -qx -- '--user start --no-block seat-tick@ctl seat-tick@rb seat-tick@r7'; ft_st_chk "success: one 'systemctl --user start seat-tick@ctl seat-tick@rb seat-tick@r7'" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/record.log")" = 1 ] && fl record | grep -q '^record --agent aide --kind other --target carbon --what TOKEN ROTATED to acctB (429, by aide) --why seats rb,r7 limited until X --evidence tick.json ctl,rb; ' && fl record | grep -q -- '--reverse-text fleet-token-rotate.sh acctA '; ft_st_chk "success: ONE wm-decide row (aide, other, carbon) with the watcher's --why/--evidence" $?
    fl record | grep -q "new=$B old=$A"; ft_st_chk "row names tokens only by sha256 prefix" $?
    [ -z "$(ls -A "$XDG_RUNTIME_DIR")" ] && grep -q '^row: d-fake0001$' "$o"; ft_st_chk "success: runtime dir empty, row id printed" $?

    # 5b. killed mid-place (systemd stop): the trap still shreds the temp
    ft_st_store acctSlow "$c-slow"; : >"$FAKE_LOG_DIR/place.log"
    setsid "$SELF" acctSlow --by aide --trigger hand >"$o" 2>"$e" & local sp=$!
    for _ in $(seq 1 80); do [ -s "$FAKE_LOG_DIR/place.log" ] && break; sleep 0.1; done
    [ -n "$(ls -A "$XDG_RUNTIME_DIR")" ]; ft_st_chk "during place the 0600 temp exists under XDG_RUNTIME_DIR" $?
    kill -TERM -- "-$sp" 2>/dev/null; wait "$sp" 2>/dev/null
    [ -z "$(ls -A "$XDG_RUNTIME_DIR")" ] && [ "$(tokj .account)" = acctB ]; ft_st_chk "SIGTERM mid-place: temp shredded by the trap, token.json untouched" $?

    # 6. a previous with no reset on record, the row failing, the no-XDG_RUNTIME_DIR fallback
    rm -f "$FT_DASH"/*-tick.json; : >"$FAKE_LOG_DIR/place.log"
    ( unset XDG_RUNTIME_DIR; FAKE_RECORD_FAIL=1 "$SELF" acctC --by aide --trigger schedule >"$o" 2>"$e" ); rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctC ] && [ "$(tokj .previous_reset_at)" = null ] && grep -q "dir=$HOME/.cache/fleet-token-tmp\." "$FAKE_LOG_DIR/place.log" && grep -q 'mode=600' "$FAKE_LOG_DIR/place.log" \
      && [ -z "$(ls -A "$HOME/.cache" | grep fleet-token-tmp)" ] && grep -q 'rotation to acctC done but the wm-decide row FAILED' "$FT_DASH/ctl-events.log" && [ "$(wc -l <"$FT_ROTLOG")" = 2 ]; ft_st_chk "no XDG_RUNTIME_DIR: 0700 dir under ~/.cache, removed after; previous_reset_at null; a failed row ALARMs but the rotation stands" $?
    grep -q 'previous_reset_at=null$' "$FT_ROTLOG"; ft_st_chk "rotations.log records previous_reset_at=null" $?
    ! grep -rqF "$c" "$o" "$e"; ft_st_chk "stdout and stderr of the last run carry no token" $?
    ft_st_done fleet-token-rotate
  ); return $?
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -ge 1 ] || usage
ft_paths
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
rotate "$@"
