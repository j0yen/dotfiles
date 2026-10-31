#!/usr/bin/env bash
# land-red-hold.sh: one pass, no loop. INTERIM watcher (fw-1058 mechanism 8, rb row d-20261026-222932-rb-0569; r7 port row 0b39): the land must not turn a red CI
# with no named failing test into a fresh inner. Page: ~/Notes/wiki/answers/2026-10-26-rb-1058-ci-red-classified-infra-six-runs-one-prd-five-whys-rhyme.md § Mechanisms 8.
# TRIGGERS (journal rows, read through a byte cursor, never `wm-build status|runs|run show|explain`, which read the whole journal and OOM the host):
#   A  op=ci-red-classified with row.tests == [] (or absent)      B  op=readmit-from-land-failed (table daemon)
#   C  (post only) op=insert table=runs row.stage=claimed for the same slug within 300 s after an A/B row: "fresh run <id> admitted N s after the red"
# ACTION (every write is   wp_gate && wp_emit_write ... && <the write>):
#   cordon   `bash -c "$LRH_CORDON_CMD" _ <slug> <reason>` ($1 slug, $2 reason; also LRH_SLUG/LRH_REASON). RB default: wm-build decision open "$2" --slug "$1".
#            ONE cordon per (slug, run_id) across A and B. Open decision ref_=slug blocks admission and redrive; it does NOT stop an inner already running.
#            Never pause, `run close`, redrive or unpause. A failing cordon is retried on up to 3 ticks, one post with the stderr tail.
#   CI post  pending item (slug, run, trigger, PR head sha) polled by later ticks (`gh run list --commit <sha>`); when every run is completed ONE post to the
#            inbox seat with the failed test names (<= 20) from each failed job's --log-failed; "no test names; failed jobs: ..." for an aggregator-only red;
#            "CI still running after 90 min" once. Posts are deduped per (slug, run, trigger).
#   F7       a trigger row older than 2 h at read time gets a post, no cordon.
# CURSOR $LRH_STATE_DIR/cursor = "<inode> <offset>". First run (no cursor) starts at the current EOF. Size < offset or a new inode = rotation: reset to 0.
#   Only complete lines are consumed (cursor stops after the last \n; a partial tail waits); a tick reads at most 64 MB; a malformed line is logged and skipped.
# PREMISE (F6, never gh): LRH_FIXED_VERSION empty, or `wm-build --version` does not contain it (the land-fix-retry promotion writes it into the env file).
#   EXPIRES 2026-10-29T23:59:00-07:00 is the hard stop. Disarmed: no reads, no writes; the first disarmed tick posts the ids of the cordons still open (F2).
# PARAMS (env wins over ~/.config/land-red-hold.env, KEY=VALUE lines, no eval): LRH_JOURNAL LRH_CORDON_CMD LRH_INBOX_SEAT (rb) LRH_REPO (j0yen/mcphost)
#   LRH_STATE_DIR LRH_OWNER (rb|r7, the wm-decide --agent) LRH_FIXED_VERSION LRH_EXPIRES LRH_SEAT_EVENT LRH_PREMISE_CMD (test seam) LRH_MUTATE (test only: drop-tests-check)
#   LRH_HELP_CMD (selftest: command printing `wm-build decision --help`) WP_STATE WP_DECIDE_BIN LRH_WP_LIB
# Exit: 0 ok / disarmed / lock busy, 2 usage or lib missing. --selftest runs tests/land-red-hold.test.sh (rb + r7 profiles) and the on-host `decision --help` check.
set -u
export LC_ALL=C
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

if [ "${1:-}" = "--selftest" ]; then
  T="$HERE/../../tests/land-red-hold.test.sh"
  if [ -z "${LRH_SELFTEST_HELP_ONLY:-}" ]; then
    [ -r "$T" ] || { echo "land-red-hold --selftest: $T not found" >&2; exit 2; }
    bash "$T" || exit 1
  fi
  HELP_CMD=${LRH_HELP_CMD:-wm-build decision --help}
  if [ -z "${LRH_HELP_CMD:-}" ] && ! command -v wm-build >/dev/null 2>&1; then
    echo "SKIP on-host decision --help check: no wm-build on this host (run it on RedBaron)"; exit 0
  fi
  h=$(timeout 60 bash -c "$HELP_CMD" 2>&1)
  if printf '%s\n' "$h" | grep -qE '^[[:space:]]+open([[:space:]]|$)' && printf '%s\n' "$h" | grep -qE 'open[^|]*--slug|decision open .*--slug'; then
    echo "PASS on-host decision --help: open subcommand takes --slug"; exit 0
  fi
  echo "FAIL on-host decision --help: no 'open' subcommand with --slug in:"; printf '%s\n' "$h" | head -n 12; exit 1
fi
[ "$#" -eq 0 ] || { echo "usage: land-red-hold.sh [--selftest]" >&2; exit 2; }

# ---- config: env wins over the file
CFG=${LRH_ENV_FILE:-$HOME/.config/land-red-hold.env}
if [ -r "$CFG" ]; then
  while IFS= read -r _ln || [ -n "$_ln" ]; do
    case "$_ln" in ''|'#'*) continue;; esac
    _k=${_ln%%=*}; _v=${_ln#*=}
    case "$_k" in LRH_*|WP_*) ;; *) continue;; esac
    case "$_v" in \'*\') _v=${_v:1:${#_v}-2};; \"*\") _v=${_v:1:${#_v}-2};; esac
    [ -n "${!_k+x}" ] || export "$_k=$_v"
  done < "$CFG"
fi
JOURNAL=${LRH_JOURNAL:-$HOME/.local/state/wm-build-hot/journal.jsonl}
CORDON_CMD=${LRH_CORDON_CMD:-'wm-build decision open "$2" --slug "$1"'}
INBOX=${LRH_INBOX_SEAT:-rb}
REPO=${LRH_REPO:-j0yen/mcphost}
STATE=${LRH_STATE_DIR:-$HOME/.local/state/land-red-hold}
BELL=${LRH_SEAT_EVENT:-$HOME/.local/bin/seat-event.sh}
EXPIRES=${LRH_EXPIRES:-2026-10-29T23:59:00-07:00}
MUTATE=${LRH_MUTATE:-}
CAP=$((64*1024*1024)); STALE_S=7200; ADMIT_S=300; CI_WAIT_S=5400; CI_GIVEUP_S=86400; MAX_TRIES=3
export WP_OWNER=${LRH_OWNER:-rb} LRH_FIXED_VERSION=${LRH_FIXED_VERSION:-}
: "${WP_STATE:=$STATE/wp}"; export WP_STATE
PREMISE=${LRH_PREMISE_CMD:-'test -z "$LRH_FIXED_VERSION" || ! wm-build --version | grep -qF "$LRH_FIXED_VERSION"'}

for _l in "${LRH_WP_LIB:-}" "$HERE/../lib/watcher-premise.sh" "$HOME/.local/lib/watcher-premise.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type wp_arm >/dev/null 2>&1 || { echo "land-red-hold: watcher-premise.sh lib not found" >&2; exit 2; }

mkdir -p "$STATE/cordon" "$STATE/pending" "$STATE/logs" || exit 2
exec 9>"$STATE/.lock"; flock -n 9 || { echo "LRH busy (lock held)"; exit 0; }
LOG=$STATE/land-red-hold.log
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG" 2>/dev/null; }
now=$(date +%s)
san() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
clean1() { local s=${1-}; s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }; printf '%s' "$s"; }

seen_has() { grep -qxF -- "$1" "$STATE/seen" 2>/dev/null; }
seen_add() { printf '%s\n' "$1" >> "$STATE/seen"; }
post() { # KEY MESSAGE : one post per KEY; recorded only when seat-event succeeded
  seen_has "$1" && return 0
  if "$BELL" "$INBOX" "$(clean1 "$2")" >/dev/null 2>&1; then seen_add "$1"; NPOST=$((NPOST+1)); log "POST $1"; return 0; fi
  log "POST FAILED $1 (seat-event rc!=0; retried next tick)"; return 1
}

# ---- premise, expiry, disarm notice (F2)
wp_arm land-red-hold "$PREMISE" "$EXPIRES" 'no land-fix-retry binary is promoted (LRH_FIXED_VERSION unset or not the running wm-build): the land ends runs on partial CI records' || true
NPOST=0; NCORD=0; NEV=0
if ! wp_gate 2>>"$LOG"; then
  why="${WP_DEFECT:--}"; [ "$why" = "-" ] && why="premise ${WP_VERDICT:-?}"
  if [ ! -e "$STATE/disarm-notified" ]; then
    open=""
    for f in "$STATE"/cordon/*.tsv; do [ -e "$f" ] || continue
      IFS=$'\t' read -r s r t rts st tr did _ < "$f"; [ "$st" = open ] && open="$open $s/run$r=$did"; done
    if "$BELL" "$INBOX" "land-red-hold DISARMED ($why): cordons still open:${open:- none}; close each decision after reading its CI failure names" >/dev/null 2>&1; then : > "$STATE/disarm-notified"; fi
  fi
  echo "LRH DISARMED $why"; exit 0
fi
rm -f "$STATE/disarm-notified"

# ---- cursor read (F1)
size=$(stat -c %s "$JOURNAL" 2>/dev/null) || { echo "LRH journal missing: $JOURNAL"; exit 0; }
ino=$(stat -c %i "$JOURNAL")
off=""; cino=""
[ -r "$STATE/cursor" ] && read -r cino off < "$STATE/cursor"
case "$off" in ''|*[!0-9]*) off="";; esac
if [ -z "$off" ]; then
  printf '%s %s\n' "$ino" "$size" > "$STATE/cursor"; log "FIRST RUN: cursor at EOF $size, nothing old is read"
  echo "LRH FIRST RUN cursor=$size"; FIRST=1
else
  FIRST=0
  if [ "$cino" != "$ino" ] || [ "$size" -lt "$off" ]; then log "ROTATION inode $cino->$ino size $size < offset $off: reset to 0"; off=0; fi
fi

CH=$STATE/chunk.$$; LINES=$STATE/lines.$$; trap 'rm -f "$CH" "$LINES"' EXIT
: > "$LINES"
if [ "$FIRST" = 0 ] && [ "$size" -gt "$off" ]; then
  n=$((size-off)); [ "$n" -gt "$CAP" ] && n=$CAP
  tail -c +$((off+1)) "$JOURNAL" 2>/dev/null | head -c "$n" > "$CH"
  got=$(stat -c %s "$CH"); partial=0
  if [ "$got" -gt 0 ] && [ "$(tail -c1 "$CH" | od -An -c | tr -d ' ')" != '\n' ]; then partial=$(tail -n1 "$CH" | wc -c); fi
  used=$((got-partial))
  if [ "$used" -le 0 ] && [ "$got" -ge "$CAP" ]; then used=$got; log "64 MB without a newline: skipped"; fi
  head -c "$used" "$CH" > "$LINES"
  printf '%s %s\n' "$ino" "$((off+used))" > "$STATE/cursor"
fi

# ---- parse candidates line by line; a bad line is logged and skipped
events=$STATE/events.tsv; touch "$events"
handle_ab() { # trig slug run ts
  local trig=$1 slug=$2 run=$3 ts=$4 epoch age cf
  [ -n "$slug" ] && [ "$slug" != null ] || return 0
  epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=$now
  if [ "$run" = "-" ] || [ "$run" = null ] || [ -z "$run" ]; then
    run=$(awk -F'\t' -v s="$slug" '$1==s {r=$2} END{print r}' "$events"); [ -n "$run" ] || run="-"
  fi
  NEV=$((NEV+1)); age=$((now-epoch))
  printf '%s\t%s\t%s\n' "$slug" "$run" "$epoch" >> "$events"
  if [ "$age" -gt "$STALE_S" ]; then
    post "post|$slug|$run|$trig|stale" "$slug run $run: land red ($trig) row is ${age}s old at read time; no cordon placed (older than 2 h); the seat decides"
    return 0
  fi
  cf=$STATE/cordon/$(san "$slug")__$(san "$run").tsv
  [ -e "$cf" ] || printf '%s\t%s\t%s\t%s\twant\t0\t-\t-\n' "$slug" "$run" "$trig" "$ts" > "$cf"
  local pf=$STATE/pending/$(san "$slug")__$(san "$run")__$trig.tsv
  [ -e "$pf" ] || [ -e "$STATE/done-$(san "$slug")__$(san "$run")__$trig" ] || printf '%s\t%s\t%s\t-\t%s\t0\n' "$slug" "$run" "$trig" "$now" > "$pf"
}
handle_c() { # slug newrun ts
  local slug=$1 nr=$2 ts=$3 epoch s r e best=""
  epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=$now
  while IFS=$'\t' read -r s r e; do
    [ "$s" = "$slug" ] && [ "$r" != "$nr" ] && [ "$epoch" -ge "$e" ] && [ $((epoch-e)) -le "$ADMIT_S" ] && best=$((epoch-e))
  done < "$events"
  [ -n "$best" ] || return 0
  post "adm|$slug|$nr" "$slug: fresh run $nr admitted $best s after the red; it re-reds at land unless the branch is fixed; the seat decides let-run vs run close"
}
if [ -s "$LINES" ]; then
  grep -E '"op" *: *"(ci-red-classified|readmit-from-land-failed|insert)"' "$LINES" | while IFS= read -r line; do
    proj=$(printf '%s' "$line" | jq -r --arg mut "$MUTATE" '
      if .op=="ci-red-classified" and (($mut=="drop-tests-check") or ((.row.tests // []) | length)==0) then ["A",(.row.slug//""),((.row.run_id//"-")|tostring),(.ts//"")]
      elif .op=="readmit-from-land-failed" and (.table//"daemon")=="daemon" then ["B",(.row.slug//""),((.row.run_id//"-")|tostring),(.ts//"")]
      elif .op=="insert" and .table=="runs" and .row.stage=="claimed" then ["C",(.row.slug//""),((.row.id//"")|tostring),(.ts//"")]
      else empty end | @tsv' 2>/dev/null) || { log "malformed journal line skipped: $(printf '%s' "$line" | cut -c1-120)"; continue; }
    [ -n "$proj" ] && printf '%s\n' "$proj"
  done > "$STATE/cands.$$"
  while IFS=$'\t' read -r k slug run ts; do
    case "$k" in A) handle_ab ci-red-classified "$slug" "$run" "$ts";; B) handle_ab readmit-from-land-failed "$slug" "$run" "$ts";; C) handle_c "$slug" "$run" "$ts";; esac
  done < "$STATE/cands.$$"
  rm -f "$STATE/cands.$$"
fi
awk -F'\t' -v c=$((now-86400)) '$3>=c' "$events" > "$events.t" && mv -f "$events.t" "$events"

# ---- cordons (F2/F3)
do_cordon() { # file
  local f=$1 slug run trig rts st tries did lasterr rc=99 out errf reason newid
  IFS=$'\t' read -r slug run trig rts st tries did lasterr < "$f"
  [ "$st" = want ] && [ "$tries" -lt "$MAX_TRIES" ] || return 0
  reason="land-red-hold run=$run RELEASE=close this decision after reading the posted CI failure names (slug $slug; $trig: land red CI with no named failing test)"
  errf=$STATE/cordon.err.$$
  if wp_gate && wp_emit_write cordon "slug=$slug run=$run" "wm-build decision open (cordon) slug=$slug via: $CORDON_CMD" "journal $trig row ts=$rts run=$run" "close the decision opened for $slug: wm-build decision close <id> \"<answer>\" (id in the cordon-done row)"; then
    out=$(LRH_SLUG=$slug LRH_REASON=$reason timeout 60 bash -c "$CORDON_CMD" _ "$slug" "$reason" 2>"$errf") && rc=0 || rc=$?
  fi
  if [ "$rc" = 99 ]; then log "cordon $slug/$run blocked by gate or outbox"; rm -f "$errf"; return 0; fi
  tries=$((tries+1))
  if [ "$rc" = 0 ]; then
    newid=$(printf '%s\n' "$out" | grep -oE '(^|[^A-Za-z0-9])(d-)?[0-9][0-9A-Za-z-]*' | head -n1 | sed -E 's/^[^A-Za-z0-9]//')
    if [ -z "$newid" ]; then
      newid=$(timeout 60 bash -c "${LRH_LIST_CMD:-wm-build decision list}" 2>/dev/null | awk -v s="$slug" '$2==s {id=$1} END{print id}')
    fi
    [ -n "$newid" ] || newid=unknown
    printf '%s\t%s\t%s\t%s\topen\t%s\t%s\t-\n' "$slug" "$run" "$trig" "$rts" "$tries" "$newid" > "$f"
    wp_emit_write cordon-done "slug=$slug run=$run" "decision opened for $slug" "decision id=$newid" "wm-build decision close $newid \"<answer>\"" || true
    NCORD=$((NCORD+1)); log "CORDON $slug run=$run id=$newid"
  else
    lasterr=$(clean1 "$(tail -c 300 "$errf" 2>/dev/null)")
    [ "$tries" -ge "$MAX_TRIES" ] && st=failed || st=want
    printf '%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' "$slug" "$run" "$trig" "$rts" "$st" "$tries" "${lasterr:--}" > "$f"
    post "post|$slug|$run|cordon-fail" "$slug run $run: cordon FAILED rc=$rc try $tries/$MAX_TRIES: ${lasterr:-no stderr}; no hold is in place"
  fi
  rm -f "$errf"
}
for f in "$STATE"/cordon/*.tsv; do [ -e "$f" ] && do_cordon "$f"; done

# ---- CI polls (F4); every gh call under timeout 120
gh_() { timeout 120 gh "$@"; }
poll() { # pending file
  local f=$1 slug run trig head first n90 age cf did cst runs rid tot done_ conc urls="" names="" fj="" j jid jn lg
  IFS=$'\t' read -r slug run trig head first n90 < "$f"
  age=$((now-first))
  if [ "$head" = "-" ]; then
    head=$(gh_ pr list --repo "$REPO" --state all --limit 100 --json headRefName,headRefOid,updatedAt 2>/dev/null \
      | jq -r --arg s "$slug" '[.[]|select(.headRefName|contains($s))]|sort_by(.updatedAt)|last|.headRefOid // empty' 2>/dev/null)
    if [ -z "$head" ]; then
      head=-
      if [ "$age" -gt "$CI_WAIT_S" ]; then post "post|$slug|$run|$trig" "$slug run $run: no PR head found for the slug in $REPO after 90 min; CI names unknown; cordon stays until a seat decides" && : > "$STATE/done-$(san "$slug")__$(san "$run")__$trig" && rm -f "$f"; fi
      return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$run" "$trig" "$head" "$first" "$n90" > "$f"
  fi
  cf=$STATE/cordon/$(san "$slug")__$(san "$run").tsv; did=-; cst=-
  [ -e "$cf" ] && { IFS=$'\t' read -r _ _ _ _ cst _ did _ < "$cf"; }
  [ "$cst" = open ] || did="none($cst)"
  runs=$(gh_ run list --repo "$REPO" --commit "$head" --limit 50 --json databaseId,status,conclusion,url 2>/dev/null) || runs=""
  tot=$(printf '%s' "$runs" | jq 'length' 2>/dev/null) || tot=0
  [ -n "$tot" ] || tot=0
  done_=0
  if [ "$tot" -gt 0 ]; then done_=$(printf '%s' "$runs" | jq '[.[]|select(.status!="completed")]|length' 2>/dev/null) || done_=1; [ "$done_" = 0 ] && done_=1 || done_=0; fi
  if [ "$done_" = 1 ]; then
    conc=$(printf '%s' "$runs" | jq -r '[.[].conclusion]|unique|join("+")')
    urls=$(printf '%s' "$runs" | jq -r '[.[]|select(.conclusion=="failure")|.url]|.[0:5]|join(" ")')
    lg=$STATE/logs/$(san "$slug")__$(san "$run")__$trig.log; : > "$lg"
    for rid in $(printf '%s' "$runs" | jq -r '.[]|select(.conclusion=="failure")|.databaseId'); do
      while IFS=$'\t' read -r jid jn; do
        [ -n "$jid" ] || continue
        fj="$fj${fj:+, }$jn"
        gh_ run view "$rid" --repo "$REPO" --job "$jid" --log-failed >> "$lg" 2>/dev/null
      done < <(gh_ run view "$rid" --repo "$REPO" --json jobs 2>/dev/null | jq -r '.jobs[]?|select(.conclusion=="failure")|[(.databaseId|tostring),.name]|@tsv')
    done
    names=$( { grep -oE 'test [^ ]+ \.\.\. FAILED' "$lg" | awk '{print $2}'; grep -oE -- '---- [^ ]+ stdout ----' "$lg" | awk '{print $2}'; } | sort -u | head -n 20 | paste -sd' ' -)
    local body
    if [ -n "$names" ]; then body="failed tests: $names"; elif [ -n "$fj" ]; then body="no test names; failed jobs: $fj"; else body="failed tests: none"; fi
    if post "post|$slug|$run|$trig" "$slug run $run: CI completed ${conc:-none}; $body; cordon $did stays until a seat decides (it blocks admission and redrive only; an inner already running is not stopped); urls: ${urls:--}; log $lg"; then
      : > "$STATE/done-$(san "$slug")__$(san "$run")__$trig"; rm -f "$f"
    fi
    return 0
  fi
  if [ "$age" -gt "$CI_WAIT_S" ] && [ "$n90" = 0 ]; then
    post "post|$slug|$run|$trig|90min" "$slug run $run: CI still running after 90 min (head ${head:0:12}); cordon $did stays until a seat decides" \
      && printf '%s\t%s\t%s\t%s\t%s\t1\n' "$slug" "$run" "$trig" "$head" "$first" > "$f"
  fi
  [ "$age" -gt "$CI_GIVEUP_S" ] && rm -f "$f"
  return 0
}
for f in "$STATE"/pending/*.tsv; do [ -e "$f" ] && poll "$f"; done

echo "LRH tick armed=1 events=$NEV cordons=$NCORD posts=$NPOST"
exit 0
