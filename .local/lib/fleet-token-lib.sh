#!/usr/bin/env bash
# fleet-token-lib.sh -- SOURCED by fleet-token-{store,rotate,429-watch,schedule}.sh. Never run directly, never prints a token.
# Paths (all resolved at call time so a selftest can point HOME / XDG_CONFIG_HOME at a throwaway dir):
#   FT_CFG   ${XDG_CONFIG_HOME:-$HOME/.config}/fleet-token        (store/<account> 0600 in a 0700 dir, ring, schedule)
#   FT_DASH  ${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}           (token.json = the account the fleet runs on; <seat>-tick.json; ctl-events.log)
#   FT_STATE ${FLEET_TOKEN_STATE_DIR:-$HOME/.local/state/fleet-token}  (rotations.log, stamps, watcher log, blocked-until-<account>, blocks.log)
# A token is only ever compared by sha256 prefix (8 hex chars) and only ever passed to a child through its environment or a 0600 file.
# FLEET_TOKEN_NOW_EPOCH is a fake clock, honoured only when FLEET_TOKEN_SELFTEST=1.

ft_paths() {
  FT_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/fleet-token"
  FT_STORE="$FT_CFG/store"
  FT_DASH="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}"
  FT_TOKJSON="$FT_DASH/token.json"
  FT_STATE="${FLEET_TOKEN_STATE_DIR:-$HOME/.local/state/fleet-token}"
  FT_ROTLOG="$FT_STATE/rotations.log"
  FT_BLOCKLOG="$FT_STATE/blocks.log"
  FT_SEATS="ctl rb r7"
}

ft_now() { if [ "${FLEET_TOKEN_SELFTEST:-}" = 1 ] && [[ "${FLEET_TOKEN_NOW_EPOCH:-}" =~ ^[0-9]+$ ]]; then echo "$FLEET_TOKEN_NOW_EPOCH"; else date +%s; fi; }
ft_iso() { date -d "@${1:-$(ft_now)}" -Iseconds; }

# account names are opaque strings but become file names: no path characters, no leading dot
ft_valid_account() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]; }
ft_clean() { printf '%s' "${1:-}" | tr '\r\n\t|' '    ' | sed -E 's/^ +//; s/ +$//'; }

# ft_sha8 <file>: first 8 hex of the sha256 of the file's token text (the first non-empty line, trimmed), the only way two tokens are compared
ft_sha8() { ft_token_of "$1" | sha256sum | cut -c1-8; }
# ft_token_of <file>: the token text (stdout, for a pipe or a variable only): an sk-ant-oat... match as fleet-token-place.sh reads it, else the first non-empty line
ft_token_of() {
  local t
  t="$(grep -o 'sk-ant-oat[A-Za-z0-9_-]*' "$1" 2>/dev/null | head -n1)"
  [ -n "$t" ] || t="$(grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null | tr -d '[:space:]')"
  printf '%s' "$t"
}

# ---- per-account blocked-until (a usage limit that resets at a known time) ------------------------------------------
# $FT_STATE/blocked-until-<account> holds ONE epoch; blocks.log gets one line per ft_block. The 429 watcher (skip_reason) and the weekly
# schedule both refuse an account while its epoch is in the future. Every parse and every comparison uses ft_now (FLEET_TOKEN_NOW_EPOCH in a selftest).
FT_LA_TZ="America/Los_Angeles"

# ft_la_iso <epoch>: 2026-10-26T21:00-07:00 (LA time, offset included)
ft_la_iso() { TZ="$FT_LA_TZ" date -d "@$1" '+%Y-%m-%dT%H:%M%:z'; }

# ft_parse_la_date <string>: prints an epoch, returns 1 when the string is not a date. The ONE parser (watcher, store CLI, rotate), always
# America/Los_Angeles. Accepted: a bare epoch (9+ digits); a 429 reset text ("resets" prefix, "(America/Los_Angeles)" suffix and commas are dropped):
#   weekly  "Oct 26, 9pm" / "Oct 26 9:30 pm"  no year: the current LA year, +1 year when that is < now - 1 day
#   session "3:30pm"                          today, +1 day when that is < now
# anything else goes to date -d in LA ("2026-10-26 21:00").
ft_parse_la_date() {
  local s now y ep mon day h m ap today
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/\([^)]*\)//g; s/[,.]|\xc2\xb7/ /g; s/^[[:space:]]*resets?[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -n "$s" ] || return 1
  now="$(ft_now)"
  if [[ "$s" =~ ^[0-9]{9,}$ ]]; then printf '%s\n' "$s"; return 0; fi
  if [[ "$s" =~ ^([a-z]{3,9})\ ([0-9]{1,2})\ ([0-9]{1,2})(:([0-9]{2}))?\ ?(am|pm)$ ]]; then
    mon="${BASH_REMATCH[1]}"; day="${BASH_REMATCH[2]}"; h="${BASH_REMATCH[3]}"; m="${BASH_REMATCH[5]:-00}"; ap="${BASH_REMATCH[6]}"
    [ "$((10#$h))" -ge 1 ] && [ "$((10#$h))" -le 12 ] && [ "$((10#$m))" -lt 60 ] || return 1
    y="$(TZ="$FT_LA_TZ" date -d "@$now" +%Y)"
    ep="$(TZ="$FT_LA_TZ" date -d "$mon $day $y $h:$m $ap" +%s 2>/dev/null)" || return 1
    if [ "$ep" -lt $(( now - 86400 )) ]; then ep="$(TZ="$FT_LA_TZ" date -d "$mon $day $((y + 1)) $h:$m $ap" +%s 2>/dev/null)" || return 1; fi
    printf '%s\n' "$ep"; return 0
  fi
  if [[ "$s" =~ ^([0-9]{1,2})(:([0-9]{2}))?\ ?(am|pm)$ ]]; then
    h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[3]:-00}"; ap="${BASH_REMATCH[4]}"
    [ "$((10#$h))" -ge 1 ] && [ "$((10#$h))" -le 12 ] && [ "$((10#$m))" -lt 60 ] || return 1
    today="$(TZ="$FT_LA_TZ" date -d "@$now" +%F)"
    ep="$(TZ="$FT_LA_TZ" date -d "$today $h:$m $ap" +%s 2>/dev/null)" || return 1
    if [ "$ep" -lt "$now" ]; then ep="$(TZ="$FT_LA_TZ" date -d "$today + 1 day $h:$m $ap" +%s 2>/dev/null)" || return 1; fi
    printf '%s\n' "$ep"; return 0
  fi
  ep="$(TZ="$FT_LA_TZ" date -d "$s" +%s 2>/dev/null)" || return 1
  [[ "$ep" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ep"
}

# ft_blocked_until <account>: the stored epoch (active or not), nothing when absent, unreadable or not a number
ft_blocked_until() {
  local v; ft_valid_account "${1:-}" || return 0
  v="$(head -n1 "$FT_STATE/blocked-until-$1" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v"
  return 0
}

# ft_block_reason <account> <now>: `blocked until <iso> (<why>)` while the block is in the future, else nothing
ft_block_reason() {
  local u why
  u="$(ft_blocked_until "$1")"
  { [ -n "$u" ] && [ "$u" -gt "$2" ]; } || return 0
  why="$(grep -F " account=$1 " "$FT_BLOCKLOG" 2>/dev/null | tail -n1 | sed -nE 's/.* why=(.*)$/\1/p' || true)"
  printf 'blocked until %s%s\n' "$(ft_la_iso "$u")" "${why:+ ($why)}"
}

# ft_block <account> <epoch> <why> [keep-later]: atomic write of the epoch + one blocks.log line. keep-later = leave a later existing block alone (returns 3, nothing written).
ft_block() {
  local acct="${1:-}" ep="${2:-}" why tmp cur now
  ft_valid_account "$acct" && [[ "$ep" =~ ^[0-9]+$ ]] || return 1
  if [ "${4:-}" = keep-later ]; then cur="$(ft_blocked_until "$acct")"; { [ -z "$cur" ] || [ "$cur" -lt "$ep" ]; } || return 3; fi
  why="$(ft_clean "${3:-}")"; now="$(ft_now)"
  ( umask 077; mkdir -p "$FT_STATE" )
  tmp="$(umask 077; mktemp "$FT_STATE/.blocked.XXXXXX")"
  printf '%s\n' "$ep" >"$tmp"; mv -f "$tmp" "$FT_STATE/blocked-until-$acct"
  ( umask 077; printf '%s | ts=%s account=%s until=%s until_iso=%s why=%s\n' "$(ft_iso "$now")" "$now" "$acct" "$ep" "$(ft_la_iso "$ep")" "$why" >>"$FT_BLOCKLOG" )
}

# ft_unblock <account>: drop the block (a hand correction); logged
ft_unblock() {
  ft_valid_account "${1:-}" || return 1
  [ -e "$FT_STATE/blocked-until-$1" ] || return 0
  rm -f "$FT_STATE/blocked-until-$1"
  ( umask 077; printf '%s | ts=%s account=%s until=cleared why=unblock\n' "$(ft_iso)" "$(ft_now)" "$1" >>"$FT_BLOCKLOG" )
}

# ft_current: the account named in token.json ("" when the file is missing or unreadable = unknown = rotation allowed)
ft_current() { [ -r "$FT_TOKJSON" ] && jq -r '.account // empty' "$FT_TOKJSON" 2>/dev/null || true; }

# ft_alarm <text>: `<ISO> | fleet-token | ALARM fleet-token: <text>` appended to ctl's event log (no wake: ctl reads it on its next turn),
# same lock file and shape as seat-tick.sh stop_hook_alarm. Also on stderr.
ft_alarm() {
  local txt line; txt="$(ft_clean "$1")"; line="ALARM fleet-token: $txt"
  echo "$line" >&2
  mkdir -p "$FT_DASH" 2>/dev/null || return 0
  {
    flock 7
    [ -e "$FT_DASH/ctl-events.log" ] || ( umask 077; : >"$FT_DASH/ctl-events.log" )
    chmod 600 "$FT_DASH/ctl-events.log"
    printf '%s | fleet-token | %s\n' "$(ft_iso)" "$line" >>"$FT_DASH/ctl-events.log"
  } 7>>"$FT_DASH/ctl-events.lock"
  return 0
}

# ---- selftest helpers (used by every script's --selftest) --------------------------------------------------------
FT_CANARY='canary-tok-7f3e9a'   # tokens in a selftest are this value plus an optional -suffix; the scan below looks for the prefix

# ft_st_env <T>: a throwaway HOME / XDG / dash / state / runtime dir under <T>, the fake clock switch, and the fake commands
ft_st_env() {
  local T="$1"
  export FLEET_TOKEN_SELFTEST=1 HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/run" \
         FLEET_DASH_DIR="$T/home/.cache/fleet-dash" FLEET_TOKEN_STATE_DIR="$T/home/.local/state/fleet-token"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$FLEET_DASH_DIR" "$T/fakes"; chmod 700 "$XDG_RUNTIME_DIR"
  unset CLAUDE_CODE_OAUTH_TOKEN
  ft_paths
  local F="$T/fakes"
  # verify: the token arrives in the environment of THIS call only; "-bad" tokens fail, "-limit" tokens fail with a limit message
  cat >"$F/verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +x
t="${CLAUDE_CODE_OAUTH_TOKEN:-}"
printf 'verify sha8=%s argc=%s\n' "$(printf '%s' "$t" | sha256sum | cut -c1-8)" "$#" >>"$FAKE_LOG_DIR/verify.log"
case "$t" in *-limit) echo "You've hit your session limit · resets 7:10pm (America/Los_Angeles)"; exit 1 ;; *-bad) echo "401"; exit 1 ;; esac
exit 0
EOF
  # place: reads the temp file it is given (it must be 0600, under XDG_RUNTIME_DIR), logs only a sha8, removes the file like the real script's shred -u
  cat >"$F/place" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +x
f="$1"; t="$(head -n1 "$f" | tr -d '[:space:]')"
printf 'place sha8=%s dir=%s mode=%s\n' "$(printf '%s' "$t" | sha256sum | cut -c1-8)" "$(dirname "$f")" "$(stat -c %a "$f")" >>"$FAKE_LOG_DIR/place.log"
case "$t" in *-slow) sleep 30 ;; esac
rm -f "$f"
case "$t" in *-badplace) echo "carbon placed rc=0"; echo "redbaron placed rc=255"; exit 0 ;; *-verifyfail) echo "carbon verify=FAIL 401"; exit 0 ;; *-exit1) exit 1 ;; esac
echo "carbon placed rc=0"; echo "carbon verify=ok"
EOF
  for n in bell systemctl; do
    printf '#!/usr/bin/env bash\nset +x\nprintf "%%s\\n" "$*" >>"$FAKE_LOG_DIR/%s.log"\n' "$n" >"$F/$n"
  done
  # record: logs its argv (asserted token-free), prints a decision id; FAKE_RECORD_FAIL=1 makes it fail
  cat >"$F/record" <<'EOF2'
#!/usr/bin/env bash
set +x
printf '%s\n' "$*" >>"$FAKE_LOG_DIR/record.log"
[ -z "${FAKE_RECORD_FAIL:-}" ] || { echo "refused" >&2; exit 1; }
echo "d-fake0001"
EOF2
  chmod +x "$F"/*
  export FAKE_LOG_DIR="$T/fakelogs"; mkdir -p "$FAKE_LOG_DIR"
  export FLEET_TOKEN_VERIFY_CMD="$F/verify" FLEET_TOKEN_PLACE_CMD="$F/place" FLEET_TOKEN_BELL_CMD="$F/bell" \
         FLEET_TOKEN_RECORD_CMD="$F/record" FLEET_TOKEN_SYSTEMCTL="$F/systemctl"
}

# ft_st_store <account> <token>: put a store entry straight on disk (the canary token lives only here)
ft_st_store() {
  mkdir -p "$FT_STORE"; chmod 700 "$FT_CFG" "$FT_STORE"
  ( umask 077; printf '%s\n' "$2" >"$FT_STORE/$1" )
}

# ft_st_canary_scan <T>: 0 = the canary text is in NO file under <T> except the store dir and the live temp the fake place reads
# (fleet-token.* under XDG_RUNTIME_DIR, which other cases assert is gone afterwards); prints the offending files otherwise.
# ( stdout/stderr of every case are captured under <T>, so they are covered too)
ft_st_canary_scan() {
  local hits; hits="$(grep -rlF -- "$FT_CANARY" "$1" 2>/dev/null | grep -v -F -e "$FT_STORE/" -e "$XDG_RUNTIME_DIR/fleet-token." -e "$HOME/.cache/fleet-token-tmp." || true)"
  [ -z "$hits" ] || { echo "CANARY LEAK in: $hits" >&2; return 1; }
  return 0
}

# ft_st_chk <name> <rc>: PASS/FAIL line + the canary scan after EVERY case (a leak fails the case that caused it); sets FT_FAIL
FT_FAIL=0; FT_PASS=0; FT_ST_T=""
ft_st_chk() {
  local name="$1" rc="$2" leak=""
  if [ "$rc" = 0 ]; then FT_PASS=$((FT_PASS + 1)); echo "PASS $name"; else FT_FAIL=1; echo "FAIL $name"; fi
  if [ -n "$FT_ST_T" ] && ! leak="$(ft_st_canary_scan "$FT_ST_T" 2>&1)"; then FT_FAIL=1; echo "FAIL canary-scan after '$name': $leak"; fi
}
ft_st_done() { local n="$1"; [ "$FT_FAIL" = 0 ] && { echo "SELFTEST PASS $n ($FT_PASS cases)"; return 0; }; echo "SELFTEST FAIL $n"; return 1; }
