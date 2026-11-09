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
# Env: OPEN_ASKS SEATS_TABLE OWED_NOW_GRACE_MIN (default 10) OWED_NOW_MAX_ROWS (default 15) OWED_NOW_STOP_MAX (default 3) OWED_NOW_STATE. Never fails a tool call: errors to stderr.
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

lint() {   # lint <seat> <now-epoch>  -> prints rows, returns 1 on any
  local seat="$1" now="$2" f
  if [ "$(src)" = asks ] && [ "$seat" != - ]; then
    FOLLOWUP_NOW="$(date -d "@$now" '+%Y-%m-%dT%H:%M')" fu_eval "$seat" || { printf 'LEDGER\t-\t\tcanonical ledger unreadable: %s\n' "$FU_REASON"; return 1; }
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
  "${ASKS_VIEW_BIN:-asks-view}" >"$f" 2>/dev/null || { rm -f "$f"; echo "owed-now: canonical ask ledger unreadable (asks-view incident opened); no rows linted" >&2; return 0; }
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

hook() {
  local in ev aid seat rows n body sid cf
  in="$(cat)"; command -v jq >/dev/null 2>&1 || return 0
  ev="$(jq -r '.hook_event_name // empty' <<<"$in" 2>/dev/null)"; aid="$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)"
  [ -z "$aid" ] || return 0
  case "$ev" in UserPromptSubmit|Stop) ;; *) return 0 ;; esac
  seat="$(seat_of "$in")"; [ -n "$seat" ] || return 0
  if [ "$(src)" = asks ] && [ "$ev" = Stop ]; then   # canonical mode: a Stop blocks only on a NEW fingerprint, never on a recital of unchanged ids
    if ! fu_eval_bin >/dev/null 2>&1; then   # missing evaluator = visible owned state, once per session (no recital loop)
      local msid mst mf; msid="$(jq -r '.session_id // "nosid"' <<<"$in" 2>/dev/null)"; [[ "$msid" =~ ^[A-Za-z0-9._-]+$ ]] || msid=nosid
      mst="$(state_dir)"; mkdir -p "$mst" 2>/dev/null; mf="$mst/$msid.noeval"
      [ ! -e "$mf" ] || return 0
      : >"$mf"; body="FOLLOW-UP EVALUATOR MISSING (seat $seat): followup-eval.py is absent, so owed obligations cannot be evaluated; install or restore it (owner ctl)."
      if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$body"; else jq -cn --arg r "$body" '{decision:"block", reason:$r}'; fi
      return 0
    fi
    local new; new="$(fu_new_obligations "$seat")"; fu_outbox_replay >/dev/null 2>&1 || true
    [ -n "$new" ] || return 0
    body="$(fu_block_reason "$new")"
    if [ "${WM_DIRECTOR:-}" = hermes ]; then printf 'director=hermes report-not-block: %s\n' "$body"; else jq -cn --arg r "$body" '{decision:"block", reason:$r}'; fi
    return 0
  fi
  rows="$(lint "$seat" "$(date +%s)")" && return 0
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
      [ "$(cat "$uf" 2>/dev/null)" != "$ufp" ] || return 0
      echo "$ufp" >"$uf"
    fi
    jq -cn --arg r "$body" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$r}}'
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
  guard) guard ;;
  --selftest) selftest ;;
  *) echo "usage: owed-now.sh lint [--seat S|-] [--now ISO] | hook | guard | --selftest" >&2; exit 2 ;;
esac
