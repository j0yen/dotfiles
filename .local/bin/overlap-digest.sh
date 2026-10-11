#!/usr/bin/env bash
# overlap-digest.sh [--since 1h] [--out <path>] — who touched which PRD slug
# (PRD dotfiles-sibling-overlap-digest R1-R3, R6). Joins the PRD repo's git log,
# agorabus session activity logs and wm-build's state.db into rows
# (actor, slug, action, ts), then names every pair of distinct actors on one
# slug within OVERLAP_WINDOW_MIN minutes as an OVERLAP line. Read-only against
# all sources; a missing source is listed in the header. Always exits 0.
#
# Writes <out> (default $OPERATOR_CACHE_DIR/overlap-digest.md). Header lines
# start with "# "; everything below is a pure function of the sources. An
# OVERLAP line absent from the previous digest also lands in a notice file
# $OPERATOR_NOTICES_DIR/<ts>-overlap.txt (the status-card channel).
#
# Env: PRD_DIR (~/Documents/PRDs), OVERLAP_SESSIONS_DIR (~/.cache/agorabus/sessions),
# WM_STATE_DB (~/.local/state/wm-build/state.db), OPERATOR_CACHE_DIR,
# OPERATOR_NOTICES_DIR, OVERLAP_WINDOW_MIN (30).
set -uo pipefail
export LC_ALL=C

prd_dir="${PRD_DIR:-$HOME/Documents/PRDs}"
sess_dir="${OVERLAP_SESSIONS_DIR:-$HOME/.cache/agorabus/sessions}"
db="${WM_STATE_DB:-$HOME/.local/state/wm-build/state.db}"
cache="${OPERATOR_CACHE_DIR:-$HOME/.cache/operator}"
notices="${OPERATOR_NOTICES_DIR:-$cache/notices}"
win_min="${OVERLAP_WINDOW_MIN:-30}"
since=1h
out="$cache/overlap-digest.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-$since}"; shift 2 ;;
    --out) out="${2:-$out}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$since" in
  *[0-9]m) secs=$(( ${since%m} * 60 )) ;;
  *[0-9]h) secs=$(( ${since%h} * 3600 )) ;;
  *[0-9]d) secs=$(( ${since%d} * 86400 )) ;;
  *[0-9]) secs=$since ;;
  *) secs=3600; since=1h ;;
esac
now=$(date +%s)
cutoff=$(( now - secs ))
tmp=$(mktemp -d) || exit 0
trap 'rm -rf "$tmp"' EXIT
rows="$tmp/rows"; : >"$rows"   # tab-separated: ts actor slug action listed_only
declare -a src

# --- (a) git rows ---
hashes="$tmp/hashes"; : >"$hashes"
if git -C "$prd_dir" rev-parse --git-dir >/dev/null 2>&1; then
  src+=("git ok")
  git -C "$prd_dir" log --since="$secs seconds ago" --format='@@%h %ct %s' --name-only 2>/dev/null |
  awk -v cutoff="$cutoff" '
    /^@@/ { h=substr($1,3); ts=$2; subj=$0; sub(/^@@[^ ]+ [0-9]+ ?/,"",subj); next }
    /^$/ { next }
    { n=split($0,p,"/"); b=p[n]
      if (b ~ /^PRD-.+\.md$/ && ts+0 >= cutoff) { s=b; sub(/^PRD-/,"",s); sub(/\.md$/,"",s); print h "\t" ts "\t" s "\t" subj } }' |
  sort -u >"$tmp/gitrows"
  cut -f1 "$tmp/gitrows" | sort -u >"$hashes"
else
  src+=("git missing ($prd_dir)")
  : >"$tmp/gitrows"
fi

# --- (b) session activity ---
sids=("$sess_dir"/*.ndjson)
have_sess=0
if [ -d "$sess_dir" ] && [ -e "${sids[0]}" ]; then
  have_sess=1; src+=("sessions ok")
elif [ -d "$sess_dir" ]; then
  src+=("sessions empty ($sess_dir)")
else
  src+=("sessions missing ($sess_dir)")
fi

unattributed=0
while IFS=$'\t' read -r h ts slug subj; do
  [ -n "$h" ] || continue
  word=${subj#chore: }; word=${word%%[ :]*}
  case "$word" in
    claim|release|archive|park|unpark|requeue) action=$word ;;
    *) action=edit ;;
  esac
  actor=""
  if [[ "$subj" =~ \(run=([0-9]+)\) ]]; then
    actor="daemon run=${BASH_REMATCH[1]}"
  elif [ $have_sess -eq 1 ]; then
    f=$(grep -lF -- "$h" "${sids[@]}" 2>/dev/null | head -1)
    [ -n "$f" ] && actor=$(basename "$f" .ndjson)
  fi
  if [ -z "$actor" ]; then actor="session?"; unattributed=$(( unattributed + 1 )); fi
  printf '%s\t%s\t%s\t%s\t0\n' "$ts" "$actor" "$slug" "$action" >>"$rows"
done <"$tmp/gitrows"

# session edit events (those that name a window commit were consumed above)
if [ $have_sess -eq 1 ]; then
  hj=$(jq -R . <"$hashes" | jq -sc .)
  for f in "${sids[@]}"; do
    sid=$(basename "$f" .ndjson)
    jq -r --arg sid "$sid" --argjson cutoff "$cutoff" --argjson hs "$hj" '
      select((.type // .event // "") == "agent.activity")
      | . as $e
      | select(($hs | any(. as $h | ($e | tojson | contains($h)))) | not)
      | (.ts | if type == "number" then . else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // 0) end) as $t
      | select($t >= $cutoff)
      | (.paths // [])[] | select(test("PRD-.+\\.md$"))
      | (split("/") | last | sub("^PRD-"; "") | sub("\\.md$"; "")) as $slug
      | [$t, $sid, $slug, "edit", "0"] | @tsv' "$f" 2>/dev/null >>"$rows"
  done
fi

# --- (c) state.db ---
if [ -r "$db" ]; then
  src+=("state.db ok")
  q() { timeout 2 sqlite3 -readonly -separator $'\t' "$db" "$1" 2>/dev/null; }
  q "select cast(strftime('%s', started) as int), case when coalesce(created_by,'') in ('','daemon','wm-build') then 'daemon run=' || id else created_by end, slug, 'run-start', 0 from runs where started is not null and cast(strftime('%s', started) as int) >= $cutoff
     union all
     select cast(strftime('%s', ended) as int), case when coalesce(created_by,'') in ('','daemon','wm-build') then 'daemon run=' || id else created_by end, slug, 'run-end', 0 from runs where ended is not null and cast(strftime('%s', ended) as int) >= $cutoff" >>"$rows"
  # operator_actions are listed only (PRD open question default): flag 1 keeps them out of overlap pairs
  q "select cast(strftime('%s', ts) as int), operator, target, cmd, 1 from operator_actions where cast(strftime('%s', ts) as int) >= $cutoff" >>"$rows"
else
  src+=("state.db missing ($db)")
fi

# --- render ---
fmt_time() { date -d "@$1" '+%m-%d %I:%M %p'; }
sort -t$'\t' -k1,1n -k2,2 -k3,3 -k4,4 -u "$rows" >"$tmp/sorted"

body="$tmp/body"; : >"$body"
while IFS=$'\t' read -r ts actor slug action _; do
  printf '%s | %s | %s | %s\n' "$(fmt_time "$ts")" "$actor" "$slug" "$action" >>"$body"
done <"$tmp/sorted"

overlaps="$tmp/overlaps"; : >"$overlaps"
mapfile -t R <"$tmp/sorted"
n=${#R[@]}
for (( i = 0; i < n; i++ )); do
  IFS=$'\t' read -r t1 a1 s1 x1 l1 <<<"${R[i]}"
  [ "$l1" = 0 ] || continue
  for (( j = i + 1; j < n; j++ )); do
    IFS=$'\t' read -r t2 a2 s2 x2 l2 <<<"${R[j]}"
    [ "$l2" = 0 ] && [ "$s1" = "$s2" ] && [ "$a1" != "$a2" ] || continue
    d=$(( t2 - t1 ))
    [ $d -le $(( win_min * 60 )) ] || continue
    printf 'OVERLAP: %s touched by %s and %s within %s min — %s (%s %s) then %s (%s %s)\n' \
      "$s1" "$a1" "$a2" $(( (d + 30) / 60 )) "$x1" "$a1" "$(date -d "@$t1" '+%I:%M %p')" "$x2" "$a2" "$(date -d "@$t2" '+%I:%M %p')" >>"$overlaps"
  done
done
sort -u "$overlaps" -o "$overlaps"
count=$(wc -l <"$overlaps")

mkdir -p "$(dirname "$out")" 2>/dev/null
prev="$tmp/prev"; : >"$prev"
[ -r "$out" ] && grep '^OVERLAP:' "$out" >"$prev" 2>/dev/null
{
  echo "# overlap-digest generated $(date '+%Y-%m-%d %I:%M %p') — window $since"
  echo "# sources: $(IFS=';'; echo "${src[*]}" | sed 's/;/; /g')"
  echo "# unattributed: $unattributed"
  cat "$body" "$overlaps"
  echo "overlaps: $count"
} >"$out.tmp" && mv -f "$out.tmp" "$out"

# --- notice for overlaps not in the previous digest ---
new=$(grep -vxFf "$prev" "$overlaps" 2>/dev/null)
if [ -n "$new" ]; then
  mkdir -p "$notices" 2>/dev/null &&
    printf '%s\n' "$new" >"$notices/$(date +%Y%m%dT%H%M%S)-overlap.txt"
fi
exit 0
