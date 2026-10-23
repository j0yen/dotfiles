#!/usr/bin/env bash
# fleet-token-429-watch.sh -- every 2 min on carbon (fleet-token-429-watch.timer): when the plan's usage limit has hit the fleet, rotate to the next account.
# PREMISE: seat-tick's quota_wait_until is the fleet-wide limit signal
# EXPIRES: 2026-11-06T00:00:00-07:00. Premise + expiry + the per-write decision row come from the shared watcher lib (.local/lib/watcher-premise.sh): wp_arm/wp_gate
#   disarm the whole watcher past EXPIRES or when the premise command says GONE (it logs `disarmed` once and exits 0); re-arm = a reviewed edit of the wp_arm line.
#   Premise command: ctl-tick.json (the seat-tick file this watcher reads) exists. WP_OWNER=aide (the wm-decide --agent).
#   TRIGGER   (>= 2 seats of ctl rb r7 have now < quota_wait_until AND quota_account == token.json.account)
#             OR (exactly 1 such seat AND a confirming haiku probe on the CURRENT token fails with a limit message),
#             AND the earliest of those resets is more than 20 min away.
#   CANDIDATE the next account in ${XDG_CONFIG_HOME:-~/.config}/fleet-token/ring (ordered names, # comments) after the current one that has a store
#             entry, skipping an account rotated away from < 6 h ago (floor) or whose rotations.log previous_reset_at is still in the future,
#             and one whose rotation failed in the last 30 min (the failed rotate already ALARMed; the next ring entry is tried).
#   ACTION    wp_gate && wp_emit_write rotate ... && fleet-token-rotate.sh <candidate> --by fleet-token-429-watch --trigger 429 --why "<the evidence>" (it bells and starts the seat ticks).
#             ONE wm-decide row per watcher rotation: the lib's (pre-write, premise-stamped, outbox first); rotate's own row is switched off for this call
#             (FLEET_TOKEN_RECORD_CMD=true). A hand or schedule rotation still gets rotate's row.
#   NO CANDIDATE -> ALARM at most once per 30 min. STORE AGE: ALARM once per day per store entry older than FLEET_TOKEN_STORE_MAX_DAYS (default 30).
#   The probe runs `claude -p --model claude-haiku-5-5 'reply ok'` with the current account's STORE token in that call's environment only
#   (else the inherited CLAUDE_CODE_OAUTH_TOKEN); only "failed AND the output is a limit line" counts, the output is never logged.
# Env (injectable): FLEET_TOKEN_PROBE_CMD FLEET_TOKEN_ROTATE_CMD FLEET_TOKEN_STORE_MAX_DAYS XDG_CONFIG_HOME FLEET_DASH_DIR FLEET_TOKEN_STATE_DIR WP_LIB WP_STATE WP_DECIDE_BIN;
#   FLEET_TOKEN_SELFTEST=1 + FLEET_TOKEN_NOW_EPOCH (fake clock) + FLEET_TOKEN_429_EXPIRES (the lib reads the REAL clock, so the selftest moves EXPIRES instead).
# Exit 0 always except usage (64) and a rotate failure it could not absorb (nothing: failures are stamped and ALARMed by rotate).
set -euo pipefail
set +x
# shellcheck source=../lib/fleet-token-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/fleet-token-lib.sh"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
PREMISE="seat-tick's quota_wait_until is the fleet-wide limit signal"
EXPIRES="2026-11-06T00:00:00-07:00"
[ "${FLEET_TOKEN_SELFTEST:-}" != 1 ] || EXPIRES="${FLEET_TOKEN_429_EXPIRES:-$EXPIRES}"
# the shared watcher lib; no lib = disarmed, never armed-by-default
WP_LIB="${WP_LIB:-$(dirname "$SELF")/../lib/watcher-premise.sh}"
if [ -r "$WP_LIB" ]; then . "$WP_LIB"; else wp_arm() { return 2; }; wp_gate() { return 1; }; wp_emit_write() { return 1; }; fi
export WP_OWNER=aide
MIN_AWAY=1200      # the earliest reset must be more than 20 min away
FLOOR=21600        # never rotate back to an account rotated away from < 6 h ago
FAIL_BACKOFF=1800  # a candidate whose rotation failed is skipped for 30 min
ALARM_EVERY=1800

wlog() { local l; l="$(ft_iso) $*"; echo "$l"; ( umask 077; printf '%s\n' "$l" >>"$FT_STATE/429-watch.log" ); }

# stamp_ok <name> <seconds>: 0 when the stamp is absent or older than <seconds> (and refreshes it); 1 when it is fresh
stamp_ok() {
  local f="$FT_STATE/$1.stamp" last now; now="$(ft_now)"
  last="$(cat "$f" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && [ $(( now - last )) -lt "$2" ]; then return 1; fi
  printf '%s\n' "$now" >"$f"; return 0
}

store_age_check() {
  local f acct max now day stamp
  max="${FLEET_TOKEN_STORE_MAX_DAYS:-30}"; [[ "$max" =~ ^[0-9]+$ ]] || max=30
  now="$(ft_now)"; day=$(( now / 86400 ))
  [ -d "$FT_STORE" ] || return 0
  for f in "$FT_STORE"/*; do
    [ -f "$f" ] || continue
    acct="$(basename "$f")"
    [ $(( now - $(stat -c %Y "$f") )) -gt $(( max * 86400 )) ] || continue
    stamp="$FT_STATE/age-$acct.stamp"
    [ "$(cat "$stamp" 2>/dev/null || true)" = "$day" ] && continue
    ft_alarm "store entry '$acct' is $(( (now - $(stat -c %Y "$f")) / 86400 )) days old (max $max): add a fresh setup-token (fleet-token-store.sh add $acct)"
    printf '%s\n' "$day" >"$stamp"
  done
}

# probe_limit: 0 = the probe on the CURRENT token failed AND its output is a usage-limit line
probe_limit() {
  local cur="$1" tok="" out rc
  [ -f "$FT_STORE/$cur" ] && tok="$(ft_token_of "$FT_STORE/$cur")"
  if out="$(
      set +x
      [ -z "$tok" ] || export CLAUDE_CODE_OAUTH_TOKEN="$tok"
      cd "$HOME"
      if [ -n "${FLEET_TOKEN_PROBE_CMD:-}" ]; then $FLEET_TOKEN_PROBE_CMD; else timeout 60 claude -p --model claude-haiku-5-5 'reply ok'; fi 2>&1
    )"; then rc=0; else rc=$?; fi
  [ "$rc" != 0 ] || return 1
  printf '%s' "$out" | tail -c 2048 | grep -Eiq 'hit your (session|usage|weekly) limit|resets[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m'
}

# skip_reason <account> <now>: prints why the account must not be rotated to (empty = eligible)
skip_reason() {
  local c="$1" now="$2" line ts rs f last
  [ -f "$FT_STORE/$c" ] || { echo "no store entry"; return; }
  f="$FT_STATE/fail-$c.stamp"; last="$(cat "$f" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && [ $(( now - last )) -lt "$FAIL_BACKOFF" ]; then echo "rotation to it failed < 30 min ago"; return; fi
  line="$(grep -F " previous=$c " "$FT_ROTLOG" 2>/dev/null | tail -n1 || true)"
  [ -n "$line" ] || return 0
  ts="$(sed -nE 's/.* ts=([0-9]+) .*/\1/p' <<<"$line")"; rs="$(sed -nE 's/.* previous_reset_at=([0-9]+|null)$/\1/p' <<<"$line")"
  if [[ "$rs" =~ ^[0-9]+$ ]] && [ "$rs" -gt "$now" ]; then echo "its limit resets $(ft_iso "$rs")"; return; fi
  if [[ "$ts" =~ ^[0-9]+$ ]] && [ $(( now - ts )) -lt "$FLOOR" ]; then echo "rotated away from < 6 h ago"; return; fi
}

watch() {
  local now dmsg
  now="$(ft_now)"
  mkdir -p "$FT_STATE"
  exec 9>>"$FT_STATE/429-watch.lock"; flock -n 9 || exit 0
  wp_arm fleet-token-429-watch "test -r '$FT_DASH/ctl-tick.json'" "$EXPIRES" "$PREMISE" || true
  if ! wp_gate 2>/dev/null; then
    if [ "${WP_DEFECT:-}" = expired ]; then dmsg="disarmed (premise: $PREMISE; expired $EXPIRES)"
    else dmsg="disarmed (premise: $PREMISE; verdict=${WP_VERDICT:-?} defect=${WP_DEFECT:--})"; fi
    [ "$(tail -n1 "$FT_STATE/429-watch.log" 2>/dev/null | cut -d' ' -f2-)" = "$dmsg" ] || wlog "$dmsg"
    exit 0
  fi
  store_age_check

  local cur s qw qa limited=() minreset="" anywait=0
  cur="$(ft_current)"
  for s in $FT_SEATS; do
    qw="$(jq -r '.quota_wait_until // empty' "$FT_DASH/$s-tick.json" 2>/dev/null || true)"
    [[ "$qw" =~ ^[0-9]+$ ]] && [ "$qw" -gt "$now" ] || continue
    anywait=1
    qa="$(jq -r '.quota_account // empty' "$FT_DASH/$s-tick.json" 2>/dev/null || true)"
    [ -n "$cur" ] && [ "$qa" = "$cur" ] || continue
    limited+=("$s"); if [ -z "$minreset" ] || [ "$qw" -lt "$minreset" ]; then minreset="$qw"; fi
  done
  if [ -z "$cur" ]; then
    [ "$anywait" = 0 ] || { stamp_ok no-current "$ALARM_EVERY" && ft_alarm "a seat is quota-waiting but $FT_TOKJSON is missing, so the account in use is unknown: run fleet-token-store.sh current <account>"; }
    exit 0
  fi
  [ "${#limited[@]}" -ge 1 ] || exit 0
  if [ $(( minreset - now )) -le "$MIN_AWAY" ]; then
    wlog "limit on ${limited[*]} (account $cur) but the earliest reset $(ft_iso "$minreset") is <= 20 min away: no rotation"; exit 0
  fi
  local evidence
  if [ "${#limited[@]}" -ge 2 ]; then
    evidence="seats ${limited[*]} are quota-waiting on account $cur until $(ft_iso "$minreset") (seat-tick quota_wait_until)"
  elif probe_limit "$cur"; then
    evidence="seat ${limited[0]} is quota-waiting on account $cur until $(ft_iso "$minreset") and a haiku probe on the current token failed with a limit message"
  else
    wlog "one seat (${limited[0]}) quota-waiting on $cur, the haiku probe did not confirm a limit: no rotation"; exit 0
  fi

  local ring=() line name i start=0 order=() cand="" why="" skipped=""
  if [ -r "$FT_CFG/ring" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      name="$(printf '%s' "${line%%#*}" | tr -d '[:space:]')"
      [ -z "$name" ] || ring+=("$name")
    done <"$FT_CFG/ring"
  fi
  for i in "${!ring[@]}"; do [ "${ring[$i]}" = "$cur" ] && start=$(( i + 1 )); done
  for (( i = 0; i < ${#ring[@]}; i++ )); do order+=("${ring[$(( (start + i) % ${#ring[@]} ))]}"); done
  for name in "${order[@]+"${order[@]}"}"; do
    [ "$name" != "$cur" ] || continue
    why="$(skip_reason "$name" "$now")"
    if [ -z "$why" ]; then cand="$name"; break; fi
    skipped="$skipped $name($why);"
  done
  if [ -z "$cand" ]; then
    wlog "limit on ${limited[*]} (account $cur) and no candidate:${skipped:- ring empty or unreadable}"
    stamp_ok no-candidate "$ALARM_EVERY" && ft_alarm "limit hit on account $cur ($evidence) and NO rotation candidate in the ring:${skipped:- ring empty or unreadable}; add an account (fleet-token-store.sh add <account>) or wait for a reset"
    exit 0
  fi
  wlog "TRIGGER: $evidence -> rotating to $cand"
  local rc=0
  if wp_gate && wp_emit_write rotate "carbon token.json account=$cur" "TOKEN ROTATE to $cand (429, by fleet-token-429-watch)" \
      "429 trigger: $evidence; ring order from $cur" "fleet-token-rotate.sh $cur --by <who> --trigger hand (the store keeps both entries; daemons and adopted units hold the old token until restarted)"; then
    FLEET_TOKEN_RECORD_CMD=true ${FLEET_TOKEN_ROTATE_CMD:-"$(dirname "$SELF")/fleet-token-rotate.sh"} "$cand" --by fleet-token-429-watch --trigger 429 --why "429 trigger: $evidence" --evidence "premise: $PREMISE; ring order from $cur" || rc=$?
    if [ "$rc" != 0 ]; then printf '%s\n' "$now" >"$FT_STATE/fail-$cand.stamp"; wlog "rotate to $cand FAILED rc=$rc (candidate skipped for 30 min; rotate raised its own ALARM)"; fi
  else
    wlog "rotate to $cand NOT done: the watcher lib refused the write (disarmed or the decision row could not be appended)"
  fi
  exit 0
}

selftest() {
  local T c=canary-tok-7f3e9a; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  ( set +e; ft_st_env "$T"; FT_ST_T="$T"
    local o="$T/out" e="$T/err" rc NOW=1790000000 A B Cc
    export FLEET_TOKEN_NOW_EPOCH=$NOW
    export FLEET_TOKEN_ROTATE_CMD="$(dirname "$SELF")/fleet-token-rotate.sh"
    # the lib: throwaway state, the fake record cmd standing in for wm-decide, a future EXPIRES (the lib reads the REAL clock)
    export WP_STATE="$T/home/.local/state/watcher-premise" WP_DECIDE_BIN="$T/fakes/record" FLEET_TOKEN_429_EXPIRES="$(date -d '+1 day' -Is)"
    cat >"$T/fakes/probe" <<'EOF2'
#!/usr/bin/env bash
set +x
printf 'probe sha8=%s\n' "$(printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | sha256sum | cut -c1-8)" >>"$FAKE_LOG_DIR/probe.log"
case "${FAKE_PROBE:-ok}" in
  limit) echo "You've hit your session limit · resets 7:10pm (America/Los_Angeles)"; exit 1 ;;
  other) echo "network unreachable"; exit 1 ;;
  *) echo ok; exit 0 ;;
esac
EOF2
    chmod +x "$T/fakes/probe"; export FLEET_TOKEN_PROBE_CMD="$T/fakes/probe"
    ft_st_store acctA "$c"; ft_st_store acctB "$c-2"; ft_st_store acctC "$c-3"; ft_st_store acctD "$c-4"
    A="$(ft_sha8 "$FT_STORE/acctA")"
    printf '# the order the fleet walks\nacctA\n  acctB   # second\n\nacctC\nacctD\n' >"$FT_CFG/ring"
    "$(dirname "$SELF")/fleet-token-store.sh" current acctA >/dev/null
    fl() { cat "$FAKE_LOG_DIR/$1.log" 2>/dev/null; }
    tokj() { jq -r "$1" "$FT_TOKJSON"; }
    # seats <ctl> <rb> <r7> [account]: each arg an offset in s from NOW for quota_wait_until, or - for none
    seats() {
      local s v i=0 acct="${4:-acctA}"
      for s in ctl rb r7; do
        i=$((i + 1)); v="${!i}"
        if [ "$v" = - ]; then printf '{"quota_wait_until":null,"quota_account":null}\n' >"$FT_DASH/$s-tick.json"
        else printf '{"quota_wait_until":%s,"quota_account":"%s"}\n' "$((NOW + v))" "$acct" >"$FT_DASH/$s-tick.json"; fi
      done
    }
    reset() { rm -rf "$WP_STATE"; rm -f "$FAKE_LOG_DIR"/*.log "$FT_ROTLOG" "$FT_STATE"/*.stamp "$FT_DASH/ctl-events.log"; "$(dirname "$SELF")/fleet-token-store.sh" current acctA >/dev/null; printf '{"account":"acctA","placed_at":null,"by":"hand","trigger":"seed"}\n' >"$FT_TOKJSON"; ft_st_store acctB "$c-2"; ft_st_store acctC "$c-3"; ft_st_store acctD "$c-4"; unset FAKE_PROBE; }
    runw() { "$SELF" >"$o" 2>"$e"; }

    # 1. nothing limited / the wait is already over / limited under ANOTHER account
    reset; seats - - -; runw; rc=$?
    [ "$rc" = 0 ] && [ -z "$(fl place)" ] && [ -z "$(fl probe)" ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "no seat limited: nothing, no probe, no rotation" $?
    reset; seats -100 -200 -; runw
    [ -z "$(fl place)" ] && [ -z "$(fl probe)" ]; ft_st_chk "quota_wait_until in the past: not limited" $?
    reset; seats 7200 7200 7200 acctZ; runw
    [ -z "$(fl place)" ] && [ -z "$(fl probe)" ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "three seats limited but under another account (quota_account != token.json.account): not counted" $?

    # 2. one seat
    reset; seats - 7200 -; FAKE_PROBE=ok runw; rc=$?
    [ "$rc" = 0 ] && [ "$(wc -l <"$FAKE_LOG_DIR/probe.log")" = 1 ] && [ -z "$(fl place)" ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "1 seat + a probe that passes: nothing rotates" $?
    fl probe | grep -q "sha8=$A"; ft_st_chk "the probe ran with the CURRENT account's token in its environment (sha256 $A)" $?
    reset; seats - 7200 -; FAKE_PROBE=other runw
    [ -z "$(fl place)" ] && [ "$(tokj .account)" = acctA ]; ft_st_chk "1 seat + a probe that fails WITHOUT a limit message: nothing rotates" $?
    reset; seats - 7200 -; FAKE_PROBE=limit runw; rc=$?
    [ "$rc" = 0 ] && [ "$(tokj .account)" = acctB ] && [ "$(tokj .trigger)" = 429 ] && [ "$(tokj .by)" = fleet-token-429-watch ] && [ "$(wc -l <"$FAKE_LOG_DIR/place.log")" = 1 ]; ft_st_chk "1 seat + a probe failing with a limit message: rotates to the next ring entry (acctB)" $?
    fl record | grep -q -- '--evidence 429 trigger: seat rb is quota-waiting on account acctA until .* a haiku probe on the current token failed with a limit message; ring order from acctA'; ft_st_chk "the row's --evidence carries the probe evidence" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/record.log")" = 1 ] && fl record | grep -q '^record --agent aide --via fleet-token-429-watch --model none --kind guard --what TOKEN ROTATE to acctB (429, by fleet-token-429-watch) --why guard write; premise: seat-tick.s quota_wait_until' \
      && fl record | grep -q -- '--tag by=joe-[0-9]*+fleet-token-429-watch'; ft_st_chk "exactly ONE decision row per rotation (the lib's: agent aide, via the watcher, by= tag; rotate's own row is off for this call)" $?
    [ "$(wc -l <"$WP_STATE"/outbox-*.jsonl)" = 2 ] && grep -q '"kind":"rotate"' "$WP_STATE"/outbox-*.jsonl && grep -q '"owner":"aide"' "$WP_STATE"/outbox-*.jsonl && grep -c '"ev":"recorded"' "$WP_STATE"/outbox-*.jsonl | grep -q 1 \
      && [ "$(cut -f4,6 "$WP_STATE/fleet-token-429-watch.tsv")" = "$(printf 'HOLDS\t1')" ]; ft_st_chk "the outbox holds the write row + its recorded marker; the lib status line says HOLDS armed" $?
    [ "$(wc -l <"$FAKE_LOG_DIR/bell.log")" = 3 ] && [ "$(wc -l <"$FAKE_LOG_DIR/systemctl.log")" = 1 ]; ft_st_chk "the rotation belled 3 seats and started the seat ticks" $?

    # 3. two seats, next ring entry WITH a store file, cooldowns
    reset; seats 7200 7200 -; rm -f "$FT_STORE/acctB"; runw
    [ "$(tokj .account)" = acctC ] && [ -z "$(fl probe)" ]; ft_st_chk "2 seats, no probe: rotates to the next ring entry that has a store file (acctB missing -> acctC)" $?
    fl record | grep -q -- '--evidence 429 trigger: seats ctl rb are quota-waiting on account acctA until '; ft_st_chk "the row's --evidence names the seats" $?
    reset; seats 7200 7200 -
    printf '%s | ts=%s account=acctA previous=acctB by=x trigger=429 previous_reset_at=null\n' "$(ft_iso)" "$((NOW - 3600))" >"$FT_ROTLOG"
    printf '%s | ts=%s account=acctA previous=acctC by=x trigger=429 previous_reset_at=%s\n' "$(ft_iso)" "$((NOW - 36000))" "$((NOW + 3600))" >>"$FT_ROTLOG"
    runw
    [ "$(tokj .account)" = acctD ]; ft_st_chk "acctB rotated away from 1 h ago (6 h floor) and acctC's reset is still in the future: both skipped -> acctD" $?
    reset; seats 7200 7200 -
    printf '%s | ts=%s account=acctA previous=acctB by=x trigger=429 previous_reset_at=%s\n' "$(ft_iso)" "$((NOW - 36000))" "$((NOW - 100))" >"$FT_ROTLOG"
    runw
    [ "$(tokj .account)" = acctB ]; ft_st_chk "acctB rotated away from 10 h ago with its reset in the past: eligible again" $?
    reset; seats 1100 1100 -; runw
    [ -z "$(fl place)" ] && [ "$(tokj .account)" = acctA ] && grep -q 'is <= 20 min away' "$FT_STATE/429-watch.log"; ft_st_chk "earliest reset only 18 min away: no rotation" $?
    reset; seats 1300 1300 -; runw
    [ "$(tokj .account)" = acctB ]; ft_st_chk "earliest reset 21 min away: rotates" $?

    # 4. a candidate whose pre-verify fails is skipped on the next run
    reset; seats 7200 7200 -; ft_st_store acctB "$c-bad"; runw
    [ "$(tokj .account)" = acctA ] && [ -z "$(fl place)" ] && grep -q 'rotation to acctB (429, by fleet-token-429-watch) NOT done' "$FT_DASH/ctl-events.log" && [ -e "$FT_STATE/fail-acctB.stamp" ]; ft_st_chk "candidate fails pre-verify: nothing placed, rotate ALARMed, candidate stamped" $?
    runw
    [ "$(tokj .account)" = acctC ]; ft_st_chk "next run: the failed candidate is skipped for 30 min -> acctC" $?

    # 5. no candidate: one ALARM per 30 min
    reset; seats 7200 7200 -; rm -f "$FT_STORE/acctB" "$FT_STORE/acctC" "$FT_STORE/acctD"; runw; runw
    [ "$(grep -c 'NO rotation candidate' "$FT_DASH/ctl-events.log")" = 1 ] && [ "$(tokj .account)" = acctA ] && [ -z "$(fl place)" ]; ft_st_chk "no candidate, two runs: exactly ONE ALARM" $?
    export FLEET_TOKEN_NOW_EPOCH=$((NOW + 1000)); seats 7200 7200 -; runw
    [ "$(grep -c 'NO rotation candidate' "$FT_DASH/ctl-events.log")" = 1 ]; ft_st_chk "no candidate, 17 min later: still one" $?
    export FLEET_TOKEN_NOW_EPOCH=$((NOW + 1900)); seats 7200 7200 -; runw
    [ "$(grep -c 'NO rotation candidate' "$FT_DASH/ctl-events.log")" = 2 ]; ft_st_chk "no candidate, 32 min after the first: a second ALARM" $?
    export FLEET_TOKEN_NOW_EPOCH=$NOW

    # 6. token.json missing
    reset; seats 7200 7200 -; rm -f "$FT_TOKJSON"; runw; runw
    [ -z "$(fl place)" ] && [ "$(grep -c 'is missing, so the account in use is unknown' "$FT_DASH/ctl-events.log")" = 1 ]; ft_st_chk "a quota-wait with no token.json: no rotation, one ALARM to seed it" $?

    # 7. expired premise (the lib reads the REAL clock: move EXPIRES into the past) / premise command GONE / decision row cannot be appended
    export FLEET_TOKEN_429_EXPIRES="2026-09-01T00:00:00-07:00"
    reset; seats 7200 7200 -; runw; rc=$?
    [ "$rc" = 0 ] && [ -z "$(fl place)" ] && grep -q 'disarmed (premise: seat-tick.s quota_wait_until is the fleet-wide limit signal' "$o" && [ "$(cut -f10 "$WP_STATE/fleet-token-429-watch.tsv")" = expired ]; ft_st_chk "past EXPIRES (lib path): logs 'disarmed', status defect=expired, exits 0, rotates nothing" $?
    runw; [ "$(grep -c disarmed "$FT_STATE/429-watch.log")" = 1 ]; ft_st_chk "disarmed is logged once, not every 2 minutes" $?
    export FLEET_TOKEN_429_EXPIRES="$(date -d '+1 day' -Is)"
    reset; seats 7200 7200 -; rm -f "$FT_DASH/ctl-tick.json"; runw; rc=$?
    [ "$rc" = 0 ] && [ -z "$(fl place)" ] && [ -z "$(fl record)" ] && [ "$(tokj .account)" = acctA ] && grep -q 'disarmed (premise: .* verdict=GONE' "$o" && [ "$(cut -f4,6 "$WP_STATE/fleet-token-429-watch.tsv")" = "$(printf 'GONE\t0')" ]; ft_st_chk "premise command GONE (ctl-tick.json missing): disarmed, no rotation, no row" $?
    reset; seats 7200 7200 -; mkdir -p "$WP_STATE"; mkdir "$WP_STATE/outbox-$(date +%Y%m%d).jsonl"; runw; rc=$?
    [ "$rc" = 0 ] && [ -z "$(fl place)" ] && [ "$(tokj .account)" = acctA ] && grep -q 'rotate to acctB NOT done: the watcher lib refused the write' "$FT_STATE/429-watch.log"; ft_st_chk "decision row cannot be appended: the write is BLOCKED (no rotation)" $?

    # 8. store age: one ALARM per day per entry
    reset; seats - - -
    touch -d "@$((NOW - 40 * 86400))" "$FT_STORE/acctD"; touch -d "@$((NOW - 10 * 86400))" "$FT_STORE/acctC"
    runw; runw
    [ "$(grep -c "store entry 'acctD' is 40 days old" "$FT_DASH/ctl-events.log")" = 1 ] && ! grep -q "acctC" "$FT_DASH/ctl-events.log"; ft_st_chk "store entry older than 30 days: ONE ALARM (two runs); a 10-day-old entry is quiet" $?
    export FLEET_TOKEN_NOW_EPOCH=$((NOW + 86400)); touch -d "@$((NOW - 40 * 86400))" "$FT_STORE/acctD"; runw
    [ "$(grep -c "store entry 'acctD'" "$FT_DASH/ctl-events.log")" = 2 ]; ft_st_chk "the next day: ALARM again" $?
    export FLEET_TOKEN_NOW_EPOCH=$NOW; FLEET_TOKEN_STORE_MAX_DAYS=50 runw
    [ "$(grep -c "store entry 'acctD'" "$FT_DASH/ctl-events.log")" = 2 ]; ft_st_chk "FLEET_TOKEN_STORE_MAX_DAYS=50 raises the limit (no new ALARM)" $?
    ! grep -rqF "$c" "$o" "$e"; ft_st_chk "stdout/stderr of the last run carry no token" $?
    ft_st_done fleet-token-429-watch
  ); return $?
}

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
[ $# -eq 0 ] || { echo 'usage: fleet-token-429-watch.sh  |  --selftest' >&2; exit 64; }
ft_paths
watch
