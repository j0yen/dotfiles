#!/usr/bin/env bash
# owed-now: nothing this session owns waits when the session could do it now.
#   Joe 10-31 11:1x PM "stop delaying work. NEVER DELAY SOMETHING YOU CAN DO NOW!", "never forget this", "make that code",
#   "make it impossible to procrastinate on anything" (approvals #181, #182). Earlier the same night: #179 "your scheduling is too conservative".
# Rule: a row this session owns is either done, or it carries `waits-on=<host|seat|person|event>` naming what it waits for. A future due
#   without that marker is a delay (DELAY). A row past its due is OVERDUE. Both are defects the session works before its turn ends.
# Rows: the canonical ledger via asks-view (A1255; $OPEN_ASKS is a test fixture honoured only with ASKS_VIEW_TEST=1), the lines above the one equal to "# CLOSED"; columns id asked owner due key check what;
#   a row whose column 2 starts with MET/DONE/CANCELLED/MOOT is closed.
# Modes:
#   owed-now.sh lint [--seat S] [--now ISO]   print the DELAY/OVERDUE rows for owner S (default $WM_SEAT); exit 1 if any, 0 if none
#   owed-now.sh hook                          stdin = Claude hook JSON. Seat = $WM_SEAT, else seats.tsv by session_id, else exit 0 (plain session).
#       UserPromptSubmit -> additionalContext listing the rows (the turn starts on them)
#       Stop             -> {"decision":"block","reason":...} ONCE per turn (stop_hook_active false), so the turn works the rows before it ends;
#                           the second Stop of the same turn passes (a bounded push, never a loop). A subagent (.agent_id set) is never blocked.
#   owed-now.sh guard                         PreToolUse (Edit|Write|MultiEdit|Bash): DENIES a write that would add a DELAY row to open-asks.tsv
#                                             (post-state minus pre-state, any owner), and a Bash command that names open-asks.tsv AND writes it
#                                             (redirect, tee, sed -i, cp/mv, script write) with a local timestamp beyond now+grace and no waits-on= in the same command;
#                                             reads of the file and timestamps ending in Z or +00:00 (quoted upstream times) pass.
#                                             The refusal is the rule's code form: a future due cannot be written without naming what it waits on
#                                             (Joe 10-31 11:3x PM "use code to make this impossible moving forward").
#       Stop             -> blocks up to OWED_NOW_STOP_MAX (3) times per turn (counter reset at UserPromptSubmit), not once.
#   owed-now.sh --selftest                    run the cases in a throwaway dir
#   owed-now.sh refresh --seat S             the background producer: runs the lint (canonical ledger, live) and writes the seat's prompt-context cache
#                                             ($OWED_NOW_STATE/<seat>.ups-cache.json, atomic rename, one refresher per seat via an exclusive lock file)
# Critical path (A1296 hook critical-path reduction, Joe 11-13): in canonical (asks) mode the UserPromptSubmit hook NEVER reads the ledger: it prints the seat's cached
#   rows (from `refresh`, started detached by the hook itself when the cache is older than OWED_CACHE_REFRESH_S and by the outbox-replay timer), marked STALE past
#   OWED_CACHE_MAX_AGE_S, or a truthful "UNKNOWN: cache absent/malformed, NOT none owed" marker on EVERY prompt while the cache is unknown (the full text once per session and state, a short
#   line after; stale: a STALE line every prompt; rv6 F6-2, silence read as none owed). The Stop hook stays a synchronous required guard for the ledger READ (it persists
#   fingerprints and blocks on a NEW one) but never waits on the store lock and never delivers (F7-1: followup-stop-nowait.sh; delivery = followup-outbox-replay.timer); on a ledger failure it already fails open. Fingerprint, dedupe, claim and outbox semantics are untouched.
# Env: OWED_CACHE_REFRESH_S (default 20) OWED_CACHE_MAX_AGE_S (default 900) OPEN_ASKS SEATS_TABLE OWED_NOW_GRACE_MIN (default 10) OWED_NOW_MAX_ROWS (default 15) OWED_NOW_STOP_MAX (default 3) OWED_NOW_STATE. Never fails a tool call: errors to stderr.
set -u
GRACE="${OWED_NOW_GRACE_MIN:-10}"; [[ "$GRACE" =~ ^[0-9]{1,3}$ ]] || GRACE=10
MAXR="${OWED_NOW_MAX_ROWS:-15}"; [[ "$MAXR" =~ ^[0-9]{1,3}$ ]] || MAXR=15
STOPMAX="${OWED_NOW_STOP_MAX:-3}"; [[ "$STOPMAX" =~ ^[0-9]{1,2}$ ]] || STOPMAX=3
state_dir() { printf "%s" "${OWED_NOW_STATE:-$HOME/.claude/state/owed-now}"; }
# Row source (ledger ask A1307): OWED_NOW_SOURCE=asks reads the canonical store through followup-lib.sh fu_eval (an overdue row with a live claim or a valid
# structured blocker is accounted and never listed; a Stop escalates a new fingerprint once); =tsv reads the legacy file. Default: tsv when the file path env is set
# explicitly (selftest, tests), else asks.
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "$here/followup-lib.sh" 2>/dev/null || true
. "$here/exlock.sh" 2>/dev/null || true   # F7-4: the one lock-file protocol
. "$here/followup-stop-nowait.sh" 2>/dev/null || true   # F7-1: the one non-waiting Stop obligation check (shared with followup-stop-gate.sh and seat-followups.sh)
src() { if [ -n "${OWED_NOW_SOURCE:-}" ]; then printf '%s' "$OWED_NOW_SOURCE"; elif [ -n "${OPEN_ASKS:-}" ]; then printf tsv; else printf asks; fi; }

# A row whose what-column carries a well-formed waits-on=<host|seat|person|event>:<target> is accounted, not OVERDUE, while the target is still plausible:
# non-empty, not a "none/unknown/done/dead" placeholder, and the row is no more than OWED_WAITS_MAX_H hours (default 72) past due, so a stale marker cannot hide a row forever.
# A row with no waits-on= is always reported.
waits_plausible() {   # waits_plausible <detail> <due-epoch> <now-epoch>
  local detail="$1" due="$2" now="$3" t
  [[ "$detail" =~ waits-on=(host|seat|person|event):([^|]*) ]] || return 1
  t="${BASH_REMATCH[2]}"; t="${t#"${t%%[![:space:]]*}"}"
  [ -n "$t" ] || return 1
  shopt -s nocasematch; [[ "$t" =~ ^(none|n/a|na|unknown|done|met|dead|gone|stale)([^[:alnum:]]|$) ]] && { shopt -u nocasematch; return 1; }; shopt -u nocasematch
  [[ "$due" =~ ^[0-9]+$ ]] && [ $((now - due)) -gt $(( ${OWED_WAITS_MAX_H:-72} * 3600 )) ] && return 1
  return 0
}

# THE seat alias table (rv6 F6-1): reader (hook), producer (refresh) and lint all map through it, so the cache key, the ledger query and the UNKNOWN state share one name.
# ops = preferred name of ctl (A1296 rev181). followup-eval.py main() and aside-followup-stop.sh map ops->ctl in their own language; no other seat is aliased anywhere.
seat_alias() { case "$1" in ops) printf ctl ;; *) printf '%s' "$1" ;; esac; }

lint() {   # lint <seat> <now-epoch>  -> prints rows, returns 1 on any
  local seat="$1" now="$2" f
  seat="$(seat_alias "$seat")"
  if [ "$(src)" = asks ] && [ "$seat" != - ]; then
    FOLLOWUP_NOW="$(date -d "@$now" '+%Y-%m-%dT%H:%M')" fu_eval "$seat" || { printf 'LEDGER\t-\t\tLEDGER-UNREADABLE: canonical ledger unreadable (%s); this is NOT "none owed"\n' "$FU_REASON"; return 1; }
    [ "$FU_EVAL" != "[]" ] || return 0
    local rows="" id due kind detail de
    while IFS=$'\t' read -r id due kind detail; do
      de="$(date -d "${due/T/ }" +%s 2>/dev/null)"
      waits_plausible "$detail" "$de" "$now" && continue
      rows+="$(printf 'OVERDUE\t%s\tdue=%s\t[%s] %s' "$id" "$due" "$kind" "$detail")"$'\n'
    done < <(jq -r '.[] | [.id, .due, .kind, (.detail // "" | gsub("[\t\n]"; " "))] | @tsv' <<<"$FU_EVAL")
    [ -n "$rows" ] || return 0
    printf '%s' "$rows"; return 1
  fi
  [ -n "$seat" ] || return 0
  f="$(mktemp -p "${TMPDIR:-$HOME/.cache}" owed-view.XXXXXX)" || return 0   # A1255: rows come from the canonical ledger via asks-view, never from open-asks.tsv
  "${ASKS_VIEW_BIN:-asks-view}" >"$f" 2>/dev/null || { rm -f "$f"; printf 'LEDGER\t-\t\tLEDGER-UNREADABLE: asks-view failed (asks-view incident opened); this is NOT "none owed"\n'; return 1; }
  _lint_rows "$seat" "$now" "$f"; local rc=$?; rm -f "$f"; return $rc
}

_lint_rows() {
  local seat="$1" now="$2" f="$3"
  [ -s "$f" ] || return 0
  local alt=""; case "$seat" in aide) alt=ctl ;; ctl) alt=aide ;; esac   # carbon executor seat: rows owned by aide or ctl (hermes-handover 2.2)
  local closed; closed=",$(awk -F'\t' '/^# CLOSED/{c=1;next} c&&NF>=7{printf "%s,", $1}' "$f")"   # A1222: ids in the CLOSED section
  awk -F'\t' -v seat="$seat" -v alt="$alt" -v now="$now" -v grace="$((GRACE * 60))" -v closed="$closed" -v maxh="${OWED_WAITS_MAX_H:-72}" '
    $0 == "# CLOSED" { exit }
    /^#/ || NF < 7 { next }
    seat != "-" && $3 != seat && (alt == "" || $3 != alt) { next }
    $2 ~ /^(MET|DONE|CANCELLED|MOOT)/ { next }
    {
      due = $4; gsub(/T/, " ", due); gsub(/[+-][0-9][0-9]:?[0-9][0-9]$|Z$/, "", due)
      if (due !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/) { print "DELAY\t" $1 "\tdue=" $4 "\tunreadable due\t" substr($7, 1, 90); n++; next }
      cmd = "date -d \"" due "\" +%s 2>/dev/null"; cmd | getline e; close(cmd)
      if (e == "") { print "DELAY\t" $1 "\tdue=" $4 "\tunreadable due\t" substr($7, 1, 90); n++; next }
      if (match($7, /waits-on=row:[A-Za-z0-9_,-]+/)) { w = substr($7, RSTART + 13, RLENGTH - 13); m = split(w, a, ","); ok = 1; for (i = 1; i <= m; i++) if (index(closed, "," a[i] ",") == 0) ok = 0
        if (ok) { print "READY\t" $1 "\tdue=" $4 "\tpredecessor " w " closed: start now\t" substr($7, 1, 90); n++; next } }
      if (e + 0 <= now + 0) {
        if ($7 ~ /waits-on=(host|seat|person|event):[^ \t|]/ && $7 !~ /waits-on=(host|seat|person|event):[ ]*(none|n\/a|unknown|done|met|dead|gone|stale)([^A-Za-z0-9]|$)/ && (now + 0 - e) <= maxh * 3600) next
        print "OVERDUE\t" $1 "\tdue=" $4 "\t" substr($7, 1, 90); n++; next }
      if (e + 0 > now + grace && $7 !~ /waits-on=[^ \t]+/) { print "DELAY\t" $1 "\tdue=" $4 "\tno waits-on=\t" substr($7, 1, 90); n++ }
    }
    END { exit (n > 0) }' "$f"
}

seat_of() {   # seat_of <hook json>
  local in="$1" sid
  if [ -n "${WM_SEAT:-}" ]; then printf '%s' "$WM_SEAT"; return; fi
  command -v jq >/dev/null 2>&1 || return 0
  sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)"; [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  awk -F'\t' -v s="$sid" '$3==s && $1 ~ /^[a-z0-9]+$/ {print $1; exit}' "${SEATS_TABLE:-$HOME/.claude/state/seats.tsv}" 2>/dev/null
}

# --- UserPromptSubmit prompt-context cache (canonical mode only). No ledger call on the prompt path.
CACHE_REFRESH_S="${OWED_CACHE_REFRESH_S:-20}"; [[ "$CACHE_REFRESH_S" =~ ^[0-9]{1,5}$ ]] || CACHE_REFRESH_S=20
CACHE_MAX_AGE_S="${OWED_CACHE_MAX_AGE_S:-900}"; [[ "$CACHE_MAX_AGE_S" =~ ^[0-9]{1,6}$ ]] || CACHE_MAX_AGE_S=900
self_path() { readlink -f "${BASH_SOURCE[0]}"; }
cache_file() { printf '%s/%s.ups-cache.json' "$(state_dir)" "$1"; }

# cache_read <seat>: C_STATE = fresh | stale | absent | malformed; C_AGE seconds; C_CLEAN true|false; C_ROWS text. Reads one local regular file, never the ledger.
cache_read() {
  local f now ts sz out
  C_STATE=absent; C_AGE=0; C_CLEAN=false; C_ROWS=""
  f="$(cache_file "$1")"
  [ -e "$f" ] || return 0
  if [ ! -f "$f" ] || [ -L "$f" ]; then C_STATE=malformed; return 0; fi
  sz="$(stat -c %s "$f" 2>/dev/null)"; { [[ "$sz" =~ ^[0-9]+$ ]] && [ "$sz" -le 1048576 ]; } || { C_STATE=malformed; return 0; }
  out="$(jq -r --arg s "$1" 'select(type=="object" and .v==1 and .seat==$s and (.ts|type=="number") and (.clean|type=="boolean") and (.rows|type=="string")) | [.ts, .clean, (.rows|@base64)] | @tsv' "$f" 2>/dev/null)"
  [ -n "$out" ] || { C_STATE=malformed; return 0; }
  ts="$(cut -f1 <<<"$out")"; C_CLEAN="$(cut -f2 <<<"$out")"; C_ROWS="$(cut -f3 <<<"$out" | base64 -d 2>/dev/null)"
  [[ "$ts" =~ ^[0-9]+$ ]] || { C_STATE=malformed; return 0; }
  now="$(date +%s)"; C_AGE=$((now - ts)); [ "$C_AGE" -ge 0 ] || { C_STATE=malformed; return 0; }
  if [ "$C_AGE" -gt "$CACHE_MAX_AGE_S" ]; then C_STATE=stale; else C_STATE=fresh; fi
}

# spawn_refresh <seat>: start the producer detached (own session, no inherited fds) and return at once; the hook never waits on it.
spawn_refresh() {
  local me; me="$(self_path)"
  if command -v setsid >/dev/null 2>&1; then setsid -f bash "$me" refresh --seat "$1" </dev/null >/dev/null 2>&1
  else ( nohup bash "$me" refresh --seat "$1" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1; fi
  return 0
}

# suggest_detached <evaluator> <message> <suggestion args...>: the blocking write of an unowned-suggestion record, started detached when the store lock was busy (F6-3).
# F7-2: the record is spooled as one JSON file in the state dir this hook already owns (no new store), named by the hash of its content so a repeated busy Stop reuses it
# (at most one detached writer per distinct record, none stacked while the lock stays held); `owed-now.sh spool-run <file>` writes it through the evaluator and removes the
# file only after the write succeeded. A writer that died (crash, reboot) leaves the file for drain_spool, which the existing producer timer (followup-outbox-replay.sh ->
# `refresh`) runs: nothing is lost and nothing is orphaned.
SPOOL_RETRY_MIN=1
suggest_detached() {
  local sev="$1" msg="$2" h f sd me; shift 2
  sd="$(state_dir)"; mkdir -p "$sd" 2>/dev/null || return 0
  h="$(printf '%s\0' "$@" "$msg" | sha1sum | cut -c1-20)"; f="$sd/sug.$h.json"
  [ -z "$(find "$f" -maxdepth 0 -mmin -"$SPOOL_RETRY_MIN" 2>/dev/null)" ] || return 0   # written within the last minute: its detached writer is (assumed) still waiting for the lock
  printf '%s\0' "$@" | jq -Rsc --arg msg "$msg" '{v:1,args:(split("\u0000")[:-1]),msg:$msg}' >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null || { rm -f "$f.tmp.$$"; return 0; }
  me="$(self_path)"
  if command -v setsid >/dev/null 2>&1; then setsid -f bash "$me" spool-run "$f" </dev/null >/dev/null 2>&1
  else ( nohup bash "$me" spool-run "$f" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1; fi
  return 0
}
# spool_run <file>: write one spooled suggestion (blocking on the store lock: the caller is detached or the producer timer); the file goes only after the write succeeded.
spool_run() {
  local f="$1" ev out; local -a args
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  ev="$(fu_eval_bin)" || return 0
  mapfile -t args < <(jq -r '.args[]' "$f" 2>/dev/null); [ "${#args[@]}" -gt 0 ] || { rm -f "$f"; return 0; }
  out="$(jq -j '.msg // ""' "$f" 2>/dev/null | python3 -I "$ev" "${args[@]}" 2>/dev/null)"
  # the file goes only when the evaluator's own answer says the record is on disk (emitted, or already there = deduped) or that nothing is flagged; a busy store (75), an unwritable state dir (3) or a crash prints no such answer and keeps the file for the next drain
  if jq -e '(.flagged == false) or (.flagged == true and (.emitted == true or .deduped == true))' >/dev/null 2>&1 <<<"$out"; then rm -f "$f"; fi
  return 0
}
# drain_spool: retry every spooled suggestion older than SPOOL_RETRY_MIN (its detached writer is gone). Idempotent: the evaluator dedupes by fingerprint.
drain_spool() {
  local f
  for f in "$(state_dir)"/sug.*.json; do
    [ -f "$f" ] || continue
    [ -n "$(find "$f" -maxdepth 0 -mmin +"$SPOOL_RETRY_MIN" 2>/dev/null)" ] || continue
    spool_run "$f"
  done
  return 0
}

# refresh <seat>: the producer. One refresher per seat (exclusive lock file, exlock.sh); writes the cache atomically.
refresh() {
  local seat st lock f tmp rows rc now
  seat="$(seat_alias "$1")"
  [[ "$seat" =~ ^[a-z0-9]+$ ]] || return 2
  [ "$(src)" = asks ] || return 0
  st="$(state_dir)"; mkdir -p "$st" 2>/dev/null || return 0
  lock="$st/$seat.refresh.lock"
  type exlock_take >/dev/null 2>&1 && exlock_take "$lock" || return 0
  now="$(date +%s)"
  rows="$(lint "$seat" "$now")"; rc=$?
  f="$(cache_file "$seat")"; tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || { exlock_release; return 0; }
  # rows go in on stdin, never as a command-line argument: one argument is capped at 128 KiB (MAX_ARG_STRLEN), so 1,000 owed rows made the old `jq --arg rows` fail and the cache never appeared (F7-5)
  if printf '%s' "$rows" | jq -Rsc --arg s "$seat" --argjson ts "$now" --argjson clean "$([ "$rc" = 0 ] && echo true || echo false)" '{v:1,seat:$s,ts:$ts,clean:$clean,rows:.}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else rm -f "$tmp"; fi
  exlock_release   # explicit on the normal path; the EXIT / TERM / INT / HUP traps of the refresh mode release it when the process is killed (F7-4)
  return 0
}

hook() {
  [ -z "${WM_HELPER:-}" ] || { cat >/dev/null 2>&1; return 0; }   # A1300 E4: helper child owes nothing; the guard mode is untouched
  local in ev aid seat rows n body sid cf
  in="$(cat)"; command -v jq >/dev/null 2>&1 || return 0
  ev="$(jq -r '.hook_event_name // empty' <<<"$in" 2>/dev/null)"; aid="$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)"
  [ -z "$aid" ] || return 0
  case "$ev" in UserPromptSubmit|Stop) ;; *) return 0 ;; esac
  seat="$(seat_of "$in")"; [ -n "$seat" ] || return 0
  seat="$(seat_alias "$seat")"   # once, before cache_read / spawn_refresh / the UNKNOWN state key: reader and producer share one key (rv6 F6-1)
  if [ "$(src)" = asks ] && [ "$ev" = Stop ]; then   # canonical mode: a Stop blocks only on a NEW fingerprint, never on a recital of unchanged ids
    cache_read "$seat"; { [ "$C_STATE" = fresh ] && [ "$C_AGE" -le "$CACHE_REFRESH_S" ]; } || spawn_refresh "$seat"   # keep the next prompt's cache warm, detached
    if ! fu_eval_bin >/dev/null 2>&1 || ! type fu_stop_new >/dev/null 2>&1; then   # missing evaluator (or the shared Stop helper) = visible owned state, once per session (no recital loop)
      local msid mst mf; msid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"; [[ "$msid" =~ ^[A-Za-z0-9._-]+$ ]] || msid=nosid
      mst="$(state_dir)"; mkdir -p "$mst" 2>/dev/null; mf="$mst/$msid.noeval"
      [ ! -e "$mf" ] || return 0
      : >"$mf"; body="FOLLOW-UP EVALUATOR MISSING (seat $seat): followup-eval.py is absent, so owed obligations cannot be evaluated; install or restore it (owner ctl)."
      if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$body"; else jq -cn --arg r "$body" '{decision:"block", reason:$r}'; fi
      return 0
    fi
    # W4 (A1346): an unowned suggestion in the final message becomes a typed suggestion-only obligation through the one evaluator (emit/persist: fp dedupe, outbox,
    # durable deliverer replay below). Recording never blocks the turn and never changes the output; owner= and due=<ISO> written in the message count as owned.
    local smsg sev sown sdue ssid; smsg="$(jq -r '.last_assistant_message // empty' <<<"$in" 2>/dev/null)"
    if [ -n "$smsg" ] && sev="$(fu_eval_bin)"; then
      ssid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"; [[ "$ssid" =~ ^[A-Za-z0-9._-]+$ ]] || ssid=nosid
      sown="$(grep -oiE 'owner[:=] ?[a-z0-9_-]+' <<<"$smsg" | head -1 | sed -E 's/^[^:=]*[:=] ?//')"
      sdue="$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' <<<"$smsg" | head -1)"
      # typed producer: a `check: <cmd>` line that is EXACTLY an allow-listed form maps 1:1 to a runner verb; anything else keeps the row-only path
      local schk sact=""; schk="$(grep -oiE '(^|[[:space:]])check[:=] ?(systemctl --user is-active [A-Za-z0-9][A-Za-z0-9@._-]{0,79}\.(service|timer)|bash tests/[a-z0-9][a-z0-9-]{0,63}\.test\.sh)[[:space:]]*$' <<<"$smsg" | head -1 | sed -E 's/^[[:space:]]*check[:=] ?//I; s/[[:space:]]+$//')"
      case "$schk" in
        "systemctl --user is-active "*) sact="$(jq -cn --arg u "${schk##* }" '{verb:"service-state",unit:$u}')" ;;
        "bash tests/"*.test.sh) sact="$(jq -cn --arg n "$(basename "${schk##* }" .test.sh)" '{verb:"named-test",name:$n}')" ;;
      esac
      printf '%s' "$smsg" | python3 -I "$sev" suggestion --nowait --seat "$seat" --id "stop-$ssid" --rev 1 ${sown:+--owner "$sown"} ${sdue:+--due "$sdue"} ${sact:+--action "$sact"} >/dev/null 2>&1
      [ $? -ne 75 ] || suggest_detached "$sev" "$smsg" suggestion --seat "$seat" --id "stop-$ssid" --rev 1 ${sown:+--owner "$sown"} ${sdue:+--due "$sdue"} ${sact:+--action "$sact"}   # store busy: the same write, blocking, off the Stop path; nothing lost, fp dedupe keeps it once
    fi
    # F6-3 (option a) + F7-1: the Stop path never waits on the fingerprint-store lock and never delivers. followup-stop-nowait.sh tries the lock once; when another process holds
    # it the Stop passes with a marker the next prompt prints (the fingerprint stays unrecorded, so the next Stop escalates it). Outbox delivery is left to the existing durable
    # consumer (followup-outbox-replay.timer): no Stop hook replays, so a slow delivery command cannot hold the Stop event.
    local new ksid; ksid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"
    fu_stop_new "$seat" "$ksid"; new="$FU_STOP_NEW"
    [ -n "$new" ] || return 0
    body="$(fu_block_reason "$new")"
    if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$body"; else jq -cn --arg r "$body" '{decision:"block", reason:$r}'; fi
    return 0
  fi
  local stale_note="" LOCKNOTE=""
  ups_ctx() { jq -cn --arg r "$1${LOCKNOTE:+ $LOCKNOTE}" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$r}}'; }
  if [ "$(src)" = asks ] && [ "$ev" = UserPromptSubmit ]; then   # critical path: cached rows or a truthful UNKNOWN, never a ledger call
    cache_read "$seat"
    { [ "$C_STATE" = fresh ] && [ "$C_AGE" -le "$CACHE_REFRESH_S" ]; } || spawn_refresh "$seat"
    local usid ust uk; usid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"; [[ "$usid" =~ ^[A-Za-z0-9._-]+$ ]] || usid=nosid
    ust="$(state_dir)"; mkdir -p "$ust" 2>/dev/null
    [ ! -e "$ust/$usid.stoplock" ] || LOCKNOTE="FOLLOW-UP STOP CHECK SKIPPED: the follow-up store was locked at this session's last Stop, so new obligations were NOT checked then; this is NOT \"none owed\"."
    case "$C_STATE" in
      absent|malformed)   # F6-2: every prompt while the cache is unknown carries a marker: the full text once per session and state, a short line after (no recital loop, no silence)
        uk="$ust/$usid.unk"
        if [ "$(cat "$uk" 2>/dev/null)" = "$C_STATE" ]; then
          ups_ctx "OWED NOW UNKNOWN (seat $seat): the owed-rows cache is still $C_STATE; this is NOT \"none owed\"."
          return 0
        fi
        echo "$C_STATE" >"$uk"
        ups_ctx "OWED NOW UNKNOWN (seat $seat): the owed-rows cache is $C_STATE, so what this seat owes is not known yet; a background refresh was started. This is NOT \"none owed\"; run ~/.claude/hooks/owed-now.sh lint --seat $seat to read the ledger now."
        return 0 ;;
      stale) stale_note=" [cache STALE: read $((C_AGE / 60)) min ago; a refresh was started]" ;;
    esac
    if [ "$C_CLEAN" = true ] && [ -z "$C_ROWS" ]; then   # the last read found nothing owed
      if [ -z "$stale_note" ]; then
        rm -f "$ust/$usid.unk" 2>/dev/null
        [ -z "$LOCKNOTE" ] || ups_ctx "OWED NOW (seat $seat): the last ledger read found nothing owed."
        return 0
      fi
      ups_ctx "OWED NOW (seat $seat): the last ledger read ($((C_AGE / 60)) min ago) found nothing owed, and the cache is STALE; a background refresh was started."   # every prompt while stale (F6-2)
      return 0
    fi
    rm -f "$ust/$usid.unk" 2>/dev/null
    rows="$C_ROWS"
  else
    rows="$(lint "$seat" "$(date +%s)")" && return 0
  fi
  if [ "$(printf '%s\n' "$rows" | head -1 | cut -f1)" = LEDGER ]; then   # unreadable ledger: say so loudly as context, exit 0, never block or exit 2
    body="$(printf '%s\n' "$rows" | head -1 | cut -f4)"
    if [ "$ev" = UserPromptSubmit ]; then ups_ctx "$body (seat $seat)$stale_note"; else printf '%s (seat %s)\n' "$body" "$seat"; fi
    return 0
  fi
  n="$(printf '%s\n' "$rows" | grep -c .)"
  body="OWED NOW (seat $seat, $n row(s), $(LC_ALL=C date '+%-I:%M %p')): each row below is done this turn, or its what-column gets waits-on=<host|seat|person|event> naming what it waits for, or it is reported MISSED with the earliest real time. A due time is for work that waits on someone else; what this session can do, it does now (Joe 10-31 11:1x PM, approvals #181/#182).
$(printf '%s\n' "$rows" | head -n "$MAXR")"
  [ "$n" -le "$MAXR" ] || body="$body
... $((n - MAXR)) more: ~/.claude/hooks/owed-now.sh lint --seat $seat"
  sid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"; [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || sid=nosid
  local st; st="$(state_dir)"; mkdir -p "$st" 2>/dev/null; cf="$st/$sid.stops"
  if [ "$ev" = Stop ]; then
    n="$(cat "$cf" 2>/dev/null || echo 0)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [ "$n" -lt "$STOPMAX" ] || return 0          # bounded push: STOPMAX blocks per turn, never a loop
    echo $((n + 1)) >"$cf"
    if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$(tr '\n' ' ' <<<"$body")"; else
    jq -cn --arg r "$body (Stop block $((n + 1))/$STOPMAX this turn)" '{decision:"block", reason:$r}'; fi
  else
    echo 0 >"$cf"
    if [ "$(src)" = asks ]; then   # canonical mode: a prompt recites the owed rows only when their fingerprint changed since this session's last prompt
      local ufp uf; ufp="$(printf '%s\n' "$rows" | sha256sum | cut -c1-16)"; uf="$st/$sid.upfp"
      if [ "$(cat "$uf" 2>/dev/null)" = "$ufp" ]; then   # unchanged rows are not recited again, but a stale cache or a skipped Stop check still says so on every prompt (F6-2)
        [ -z "$stale_note" ] || { ups_ctx "OWED NOW (seat $seat): $n row(s) still owed as last recited; cache STALE ($((C_AGE / 60)) min old), a background refresh was started."; return 0; }
        [ -z "$LOCKNOTE" ] || ups_ctx "OWED NOW (seat $seat): $n row(s) still owed as last recited."
        return 0
      fi
      echo "$ufp" >"$uf"
    fi
    ups_ctx "$body$stale_note"
  fi
}

deny() { jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'; }

guard() {   # PreToolUse: stdin hook json. Exit 0 silently unless the call would write a delay.
  local in tool fp f post pre_ids added cmd ts e now
  in="$(cat)"; command -v jq >/dev/null 2>&1 || return 0
  tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)"; f="${OPEN_ASKS:-}"; now="$(date +%s)"
  case "$tool" in
    Edit|Write|MultiEdit)
      fp="$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null)"
      [ -n "$f" ] && [ "$(basename -- "$fp" 2>/dev/null)" = "$(basename -- "$f")" ] || return 0
      post="$(mktemp -p "${TMPDIR:-$HOME/.cache}" owed-post.XXXXXX)" || return 0
      OWED_IN="$in" OWED_CUR="$f" python3 -I - >"$post" 2>/dev/null <<'PYX' || { rm -f "$post"; return 0; }
import json, os
h = json.loads(os.environ["OWED_IN"]); ti = h.get("tool_input") or {}; tool = h.get("tool_name")
cur = open(os.environ["OWED_CUR"], encoding="utf-8", errors="replace").read()
if tool == "Write": out = ti.get("content") or ""
else:
    edits = [ti] if tool == "Edit" else (ti.get("edits") or []); out = cur
    for e in edits:
        o = e.get("old_string") or ""; n = e.get("new_string") or ""
        if o: out = out.replace(o, n) if e.get("replace_all") else out.replace(o, n, 1)
print(out, end="")
PYX
      pre_ids="$(ASKS_VIEW_TEST=1 OPEN_ASKS="$f" lint - "$now" | awk -F'\t' '$1=="DELAY"{print $2}')"
      added="$(ASKS_VIEW_TEST=1 OPEN_ASKS="$post" lint - "$now" | awk -F'\t' -v pre="$pre_ids" 'BEGIN{n=split(pre,a,"\n"); for(i=1;i<=n;i++) seen[a[i]]=1} $1=="DELAY" && !seen[$2]')"
      rm -f "$post"
      [ -z "$added" ] && return 0
      deny "owed-now: this write adds a row with a future due and no waits-on= (a delay). Do the work now, or put waits-on=<host|seat|person|event> in the what column naming what it waits for (Joe 10-31 11:1x PM, approvals #181/#182):
$added" ;;
    Bash)
      cmd="$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null)"
      # scope: only a command that names open-asks.tsv AND writes it (redirect, tee, sed -i, cp/mv/install onto it, a script's write/open w|a)
      grep -q 'open-asks' <<<"$cmd" || return 0
      grep -qE '>>?[[:space:]]*["'"'"']?[^[:space:];&|]*(open-asks|\$)|tee[^|;&]*open-asks|sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*i|(cp|mv|install)[[:space:]][^;&|]*open-asks|\.write\(|open\([^)]*,[[:space:]]*["'"'"'][wa]' <<<"$cmd" || return 0
      grep -q 'waits-on=' <<<"$cmd" && return 0
      # a timestamp ending in Z or +00:00 is a quoted upstream time, never a due
      for ts in $(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?' <<<"$cmd" | grep -vE '(Z|\+00:?00|-00:?00)$' | sort -u); do
        ts="${ts:0:16}"
        e="$(date -d "${ts/T/ }" +%s 2>/dev/null)" || continue
        if [ "$e" -gt $((now + GRACE * 60)) ]; then
          deny "owed-now: the command writes a future due ($ts) to an ask row without waits-on=. Do the work now, or add waits-on=<host|seat|person|event> to the same command (Joe 10-31 11:1x PM, approvals #181/#182)."; return 0
        fi
      done ;;
  esac
  return 0
}

selftest() {
  local d pass=0 fail=0 out rc
  d="$(mktemp -d -p "${TMPDIR:-$HOME/.cache}" owed-now.XXXXXX)"; trap 'rm -rf "$d"' RETURN
  export ASKS_VIEW_TEST=1 OPEN_ASKS="$d/open-asks.tsv" SEATS_TABLE="$d/seats.tsv" OWED_NOW_STATE="$d/state"; unset WM_SEAT
  printf '#!/usr/bin/env bash\ncat "$OPEN_ASKS"\n' >"$d/asks-view"; chmod +x "$d/asks-view"; export ASKS_VIEW_BIN="$d/asks-view"   # hermetic fixture reader (real 7-column schema), no host asks-view needed
  printf 'rb\t1\tsid-rb\n' >"$SEATS_TABLE"
  local now; now="$(date -d '2026-10-31 23:00' +%s)"
  printf '%s\n' '# open asks' \
    $'A1\t2026-10-31T22:00\taide\t2026-10-31T22:30\tk\tc\toverdue aide row' \
    $'A2\t2026-10-31T22:00\taide\t2026-11-01T00:30\tk\tc\tfuture due, no marker' \
    $'A3\t2026-10-31T22:00\taide\t2026-11-01T00:30\tk\tc\tfuture due waits-on=rb next tick' \
    $'A4\t2026-10-31T22:00\taide\t2026-10-31T23:05\tk\tc\twithin grace' \
    $'A5\tMET 10:50 PM\taide\t2026-10-31T22:30\tk\tc\tmet row' \
    $'A6\t2026-10-31T22:00\trb\t2026-11-01T00:30\tk\tc\trb future no marker' \
    '# CLOSED' \
    $'A7\t2026-10-31T22:00\taide\t2026-10-31T22:30\tk\tc\tclosed section' >"$OPEN_ASKS"
  t() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "PASS $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
  out="$(lint aide "$now")"; rc=$?
  t "$([ "$rc" = 1 ] && echo 0 || echo 1)" "lint exits 1 with owed rows"
  t "$(grep -q '^OVERDUE	A1' <<<"$out" && echo 0 || echo 1)" "A1 overdue"
  t "$(grep -q '^DELAY	A2' <<<"$out" && echo 0 || echo 1)" "A2 future due without waits-on = DELAY"
  rf="$(mktemp)"; printf 'R1\t2026-11-07T10:00\trb\t2099-01-01T00:00\tk\tc\tw waits-on=row:P1\nR2\t2026-11-07T10:00\trb\t2099-01-01T00:00\tk\tc\tw waits-on=row:P2\n# CLOSED\nP1\tDONE x\trb\t2026-01-01T00:00\tk\tc\twhat\n' >"$rf"
  rout="$(ASKS_VIEW_TEST=1 OPEN_ASKS="$rf" lint rb "$now")"; t "$(grep -q '^READY	R1' <<<"$rout" && ! grep -q 'R2' <<<"$rout" && echo 0 || echo 1)" "A1222 READY: successor with closed predecessor listed, open predecessor quiet"; rm -f "$rf"
  t "$(grep -q 'A3' <<<"$out" && echo 1 || echo 0)" "A3 waits-on= future due passes"
  t "$(grep -q 'A4' <<<"$out" && echo 1 || echo 0)" "A4 within grace passes"
  t "$(grep -q 'A5' <<<"$out" && echo 1 || echo 0)" "A5 MET row ignored"
  t "$(grep -q 'A6' <<<"$out" && echo 1 || echo 0)" "A6 other owner ignored for aide"
  t "$(grep -q 'A7' <<<"$out" && echo 1 || echo 0)" "A7 under # CLOSED ignored"
  out="$(lint rb "$now")"; t "$(grep -q '^DELAY	A6' <<<"$out" && echo 0 || echo 1)" "rb sees its own A6"
  out="$(lint r7 "$now")"; rc=$?; t "$rc" "r7 with no rows exits 0"
  # hook modes (fake now = real now; A1 overdue regardless)
  out="$(printf '{"hook_event_name":"Stop","session_id":"sid-rb","stop_hook_active":false}' | hook)"
  t "$(jq -e '.decision=="block" and (.reason|test("OWED NOW"))' <<<"$out" >/dev/null && echo 0 || echo 1)" "Stop first sighting blocks for a seats.tsv seat"
  out="$(printf '{"hook_event_name":"Stop","session_id":"sid-rb","agent_id":"x","stop_hook_active":false}' | hook)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "subagent never blocked"
  out="$(WM_SEAT=aide hook <<<'{"hook_event_name":"UserPromptSubmit","session_id":"zz"}')"
  t "$(jq -e '.hookSpecificOutput.additionalContext|test("A1")' <<<"$out" >/dev/null && echo 0 || echo 1)" "UserPromptSubmit lists rows for WM_SEAT"
  out="$(WM_SEAT=ctl hook <<<'{"hook_event_name":"UserPromptSubmit","session_id":"zz"}')"
  t "$(jq -e '.hookSpecificOutput.additionalContext|test("A1")' <<<"$out" >/dev/null && echo 0 || echo 1)" "WM_SEAT=ctl lists the aide-owned rows (carbon executor seat, transition aide|ctl)"
  out="$(printf '{"hook_event_name":"Stop","session_id":"nobody","stop_hook_active":false}' | hook)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "plain session (no seat) passes"
  out="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sid-rb"}' | hook >/dev/null; for i in 1 2 3 4; do r="$(printf '{"hook_event_name":"Stop","session_id":"sid-rb","stop_hook_active":true}' | hook)"; [ -z "$r" ] && echo pass || jq -r '.decision' <<<"$r"; done | tr '\n' ' ')"
  t "$([ "$out" = "block block block pass " ] && echo 0 || echo 1)" "Stop blocks 3x per turn then passes (got: $out)"
  local nowiso; nowiso="$(date -d @"$now" '+%Y-%m-%dT%H:%M')"; local fut; fut="$(date -d @"$(( $(date +%s) + 7200 ))" '+%Y-%m-%dT%H:%M')"   # guard reads the real clock, so the future due must be real-future (fixed fut went past at 1:00 AM 11-01)
  out="$(jq -cn --arg f "$OPEN_ASKS" --arg o $'A4\t2026-10-31T22:00\taide\t2026-10-31T23:05\tk\tc\twithin grace' --arg n "A9	2026-10-31T22:00	aide	$fut	k	c	new delay row" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' | OWED_NOW_GRACE_MIN=10 guard)"
  t "$(jq -e '.hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|test("A9"))' <<<"$out" >/dev/null && echo 0 || echo 1)" "guard denies an Edit adding a future-due row without waits-on="
  out="$(jq -cn --arg f "$OPEN_ASKS" --arg o $'A4\t2026-10-31T22:00\taide\t2026-10-31T23:05\tk\tc\twithin grace' --arg n "A9	2026-10-31T22:00	aide	$fut	k	c	new row waits-on=rb next tick" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes an Edit whose future-due row carries waits-on="
  out="$(jq -cn --arg f "$OPEN_ASKS" --arg o $'no marker' --arg n 'no marker waits-on=rb' '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes an Edit that only fixes existing DELAY rows"
  out="$(jq -cn --arg c "printf 'A9\t$nowiso\taide\t$fut\tk\tc\tx\n' >> $OPEN_ASKS" '{tool_name:"Bash",tool_input:{command:$c}}' | guard)"
  t "$(jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null && echo 0 || echo 1)" "guard denies a Bash append with a future due and no waits-on="
  out="$(jq -cn --arg c "printf 'A9\t$nowiso\taide\t$fut\tk\tc\tx waits-on=r7 leg\n' >> $OPEN_ASKS" '{tool_name:"Bash",tool_input:{command:$c}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes the same Bash append with waits-on="
  out="$(jq -cn '{tool_name:"Bash",tool_input:{command:"ls -la"}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard ignores an unrelated Bash command"
  out="$(jq -cn '{tool_name:"Bash",tool_input:{command:"gh pr list --json mergedAt --jq '"'"'select(.mergedAt > \"2026-11-01T18:00:00Z\")'"'"'"}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes a gh command quoting a Z-suffixed upstream time"
  out="$(jq -cn --arg c "cat $OPEN_ASKS; echo due $fut" '{tool_name:"Bash",tool_input:{command:$c}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes a Bash command that only reads open-asks.tsv"
  out="$(jq -cn --arg c "printf 'A9\t$nowiso\taide\t${fut}Z\tk\tc\tx\n' >> $OPEN_ASKS" '{tool_name:"Bash",tool_input:{command:$c}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard ignores a Z-suffixed timestamp even in a write"
  out="$(jq -cn --arg c "seat-ask.sh --due $fut --to rb x" '{tool_name:"Bash",tool_input:{command:$c}}' | guard)"
  t "$([ -z "$out" ] && echo 0 || echo 1)" "guard passes a command that never names open-asks.tsv"
  echo "selftest: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
}

case "${1:-hook}" in
  lint) shift; seat="${WM_SEAT:-}"; now="$(date +%s)"
        while [ $# -gt 0 ]; do case "$1" in --seat) seat="$2"; shift 2;; --now) [ -n "${2:-}" ] || { echo "owed-now.sh: --now needs an ISO time (a bare --now would loop forever)" >&2; exit 2; }; now="$(date -d "$2" +%s)" || exit 2; shift 2;; *) shift;; esac; done
        lint "$seat" "$now" ;;
  hook) hook ;;
  refresh) shift; seat="${WM_SEAT:-}"; while [ $# -gt 0 ]; do case "$1" in --seat) seat="${2:-}"; shift 2;; *) shift;; esac; done
           trap 'exlock_release' EXIT; trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP   # F7-4: a killed producer releases its lock (SIGKILL: the 5-minute staleness)
           refresh "$seat"; rc=$?; drain_spool; exit "$rc" ;;
  spool-run) spool_run "${2:-}" ;;
  guard) guard ;;
  --selftest) selftest ;;
  *) echo "usage: owed-now.sh lint [--seat S|-] [--now ISO] | refresh --seat S | spool-run FILE | hook | guard | --selftest" >&2; exit 2 ;;
esac
