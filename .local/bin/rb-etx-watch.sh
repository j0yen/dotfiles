#!/usr/bin/env bash
# rb-etx-watch.sh: one pass, no loop. Fires `seat-event.sh rb "ETX TRIGGER n=<k> <file> pac_a=<y|n>"` on a NEW ETXTBSY suite red (chain-watch 5d8f:
# a 2nd parallel ETXTBSY red on wm-build main CI -> hand PR; wm-build has no GitHub CI, so its suite reds are the coder reports and the verifier runs).
# Scans ONLY these globs (never a recursive find/grep): $ETX_CODERS_DIR/*.report.md  $ETX_CODERS_DIR/*.out  $ETX_VERIFIER_DIR/*/run.out  $ETX_VERIFIER_DIR/*/result.json
# HIT (G1) = BOTH: the pattern `ETXTBSY|Text file busy|ExecutableFileBusy|os error 26` on a line that does not start (after spaces) with > # - and is not inside a
#   ``` fence, AND the same file matches `panicked at|test result: FAILED|error\[`. A report that only quotes the pattern never fires.
# SKIPS (G2) exact: etx*.report.md, etx*.out, $ETX_VERIFIER_DIR/vetx*/ . IN-FLIGHT (G4), skipped and not recorded: run.out whose result.json is absent or < 60 s old
#   (a fresh result.json is skipped the same way); <name>.out with no <name>.report.md. A <name>.out whose <name>.report.md is itself a hit is skipped (one red = one event).
# STATE $ETX_STATE: seen (path<TAB>inode<TAB>size<TAB>mtime<TAB>hits; seen.tmp + mv -f; a truncated last line is ignored), seeded (timestamp), fired (n).
#   hits = count of REAL ETX lines (same filter as HIT) when the record was written. A legacy 4-field record ADOPTS the current count on first sight (no fire) and is
#   rewritten to 5 fields in that same pass. First pass with no `seeded` records every current hit WITHOUT firing and prints `ETX SEED n=<k>` (G5).
#   FIRE KEY = (path, count of real ETX lines) (ctl 6152 cond. 2): a recorded path fires again when its inode changed, its size DEcreased (a new run), or its hits
#   count ROSE (a NEW real ETX line in a growing file; bell text adds `new ETX line <k>-><m>`). Growth with no new real ETX line is silent. Every pass rewrites the
#   record of every hit file. ACCEPTED GAP: an in-place rewrite with an equal count and non-decreasing size is silent. The event n = hit paths incl. seeded ones and this one (G10).
# PREMISE + EXPIRES via watcher-premise.sh (G7/G8): premise = $ETX_PREMISE_DIR exists; gone/expired -> `ETX DISARMED premise|expired|<defect>`, no scan, no state write.
# Env: ETX_CODERS_DIR ETX_VERIFIER_DIR ETX_STATE ETX_SEAT_EVENT ETX_EXPIRES ETX_PREMISE_DIR WP_STATE ETX_WP_LIB ETX_MUTATE (test only: seen-false = the seen check never matches)
# Writes: $ETX_STATE, $WP_STATE, and whatever seat-event.sh writes. Exit: 0 ok / disarmed, 1 seat-event failed for some hit, 2 usage.
set -u
export LC_ALL=C
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
if [ "${1:-}" = "--selftest" ]; then
  T="$HERE/../../tests/rb-etx-watch.test.sh"
  [ -r "$T" ] || { echo "rb-etx-watch --selftest: $T not found" >&2; exit 2; }
  exec bash "$T"
fi
[ "$#" -eq 0 ] || { echo "usage: rb-etx-watch.sh [--selftest]" >&2; exit 2; }

CODERS=${ETX_CODERS_DIR:-/home/jsy/.cache/rb-seat/coders}
VERIF=${ETX_VERIFIER_DIR:-$HOME/.local/state/aide-verifier}
STATE=${ETX_STATE:-$HOME/.local/state/rb-etx-watch}
BELL=${ETX_SEAT_EVENT:-/home/jsy/dotfiles/.local/bin/seat-event.sh}
EXPIRES=${ETX_EXPIRES:-2026-11-06T23:59:00-08:00}
PDIR=${ETX_PREMISE_DIR:-/home/jsy/.cache/rb-seat/coders}
MUTATE=${ETX_MUTATE:-}
ETX_RE='ETXTBSY|Text file busy|ExecutableFileBusy|os error 26'
RED_RE='panicked at|test result: FAILED|error\['
INFLIGHT_S=60

for _l in "${ETX_WP_LIB:-}" "$HERE/../lib/watcher-premise.sh" "$HOME/.local/lib/watcher-premise.sh"; do [ -n "$_l" ] && [ -r "$_l" ] && { . "$_l"; break; }; done
type wp_arm >/dev/null 2>&1 || { echo "rb-etx-watch: watcher-premise.sh lib not found" >&2; exit 2; }

wp_arm rb-etx-watch "test -d $(printf '%q' "$PDIR")" "$EXPIRES" 'chain-watch 5d8f: 2nd ETXTBSY red -> hand PR' || true
if ! wp_gate 2>/dev/null; then
  if [ "${WP_DEFECT:--}" = expired ]; then why=expired; elif [ "${WP_VERDICT:-}" = GONE ]; then why=premise; else why="${WP_DEFECT:--}"; fi
  echo "ETX DISARMED $why"
  exit 0
fi

# count of real ETX lines (not quoted, not fenced); memoized per file per pass in HC
declare -A HC
etx_count() {
  [ -n "${HC[$1]+x}" ] && return 0
  HC[$1]=$(awk -v re="$ETX_RE" '/^[[:space:]]*```/ { fence = !fence; next } fence { next } /^[[:space:]]*[>#-]/ { next } $0 ~ re { c++ } END { print c+0 }' "$1" 2>/dev/null)
  [[ ${HC[$1]} =~ ^[0-9]+$ ]] || HC[$1]=0
}
# at least one real ETX line AND a red marker in the same file
is_hit() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  etx_count "$1"
  [ "${HC[$1]}" -gt 0 ] || return 1
  grep -qE "$RED_RE" "$1"
}
age_s() { echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )); }

hits=()
shopt -s nullglob
for f in "$CODERS"/*.report.md "$CODERS"/*.out; do
  b=${f##*/}
  case "$b" in etx*.report.md|etx*.out) continue;; esac
  case "$b" in
    *.out)
      stem=${f%.out}
      [ -f "$stem.report.md" ] || continue
      is_hit "$stem.report.md" && continue;;
  esac
  is_hit "$f" && hits+=("$f")
done
for f in "$VERIF"/*/run.out "$VERIF"/*/result.json; do
  d=${f%/*}
  case "${d##*/}" in vetx*) continue;; esac
  rj=$d/result.json
  [ -f "$rj" ] && [ "$(age_s "$rj")" -ge "$INFLIGHT_S" ] || continue
  is_hit "$f" && hits+=("$f")
done
shopt -u nullglob

mkdir -p "$STATE" || exit 2
SEEN=$STATE/seen
declare -A rec   # path -> "inode<TAB>size<TAB>mtime<TAB>hits"
declare -A legacy
if [ -r "$SEEN" ]; then
  mapfile -t _lines < "$SEEN"
  # a seen file not ending in a newline has a truncated last line: ignore it
  if [ -s "$SEEN" ] && [ "$(tail -c1 "$SEEN" | od -An -c | tr -d ' ')" != '\n' ]; then unset '_lines[${#_lines[@]}-1]'; fi
  for _ln in "${_lines[@]}"; do
    IFS=$'\t' read -r _p _i _s _m _h _x <<<"$_ln"
    [ -n "${_p:-}" ] && [ -n "${_m:-}" ] && [ -z "${_x:-}" ] && [[ $_i =~ ^[0-9]+$ && $_s =~ ^[0-9]+$ && $_m =~ ^[0-9]+$ ]] || continue
    if [ -z "${_h:-}" ]; then legacy[$_p]="$_i"$'\t'"$_s"$'\t'"$_m"   # 4-field legacy record: adopts below
    elif [[ $_h =~ ^[0-9]+$ ]]; then rec[$_p]="$_i"$'\t'"$_s"$'\t'"$_m"$'\t'"$_h"; fi
  done
  # E1/E6: every legacy record adopts the CURRENT count (no fire) and is rewritten to 5 fields this pass; an unreadable path takes hits=1
  for _p in "${!legacy[@]}"; do
    if [ -f "$_p" ] && [ -r "$_p" ]; then etx_count "$_p"; _h=${HC[$_p]}; else _h=1; fi
    rec[$_p]="${legacy[$_p]}"$'\t'"$_h"
  done
fi

write_seen() {
  local p
  for p in "${!rec[@]}"; do printf '%s\t%s\n' "$p" "${rec[$p]}"; done | sort > "$SEEN.tmp" && mv -f "$SEEN.tmp" "$SEEN"
}
cur() { etx_count "$1"; printf '%s\t%s\n' "$(stat -c '%i'$'\t''%s'$'\t''%Y' "$1")" "${HC[$1]}"; }

if [ ! -e "$STATE/seeded" ]; then
  for f in "${hits[@]}"; do rec[$f]=$(cur "$f"); done
  write_seen
  echo "${#hits[@]}" > "$STATE/fired"
  date -Is > "$STATE/seeded"
  echo "ETX SEED n=${#hits[@]}"
  exit 0
fi

n=$(cat "$STATE/fired" 2>/dev/null); [[ ${n:-} =~ ^[0-9]+$ ]] || n=0
rc=0; fired=0
for f in "${hits[@]}"; do
  now=$(cur "$f"); IFS=$'\t' read -r ni ns nm nh <<<"$now"; extra=""
  old=${rec[$f]-}
  [ "$MUTATE" = seen-false ] && old=""
  if [ -n "$old" ]; then
    IFS=$'\t' read -r oi os om oh <<<"$old"
    if [ "$ni" = "$oi" ] && [ "$ns" -ge "$os" ]; then
      [ "$nh" -gt "$oh" ] || { rec[$f]=$now; continue; }   # same run, no new real ETX line (growth is silent)
      extra=" new ETX line $oh->$nh"
    fi
  fi
  pa=n; grep -q 'pac_a' "$f" && pa=y
  if "$BELL" rb "ETX TRIGGER n=$((n+1)) ${f##*/} pac_a=$pa$extra" >/dev/null 2>&1; then
    n=$((n+1)); fired=$((fired+1)); rec[$f]=$now; echo "$n" > "$STATE/fired"
  else
    echo "ETX seat-event failed for ${f##*/}; will retry next pass" >&2; rc=1
  fi
done
write_seen
echo "ETX SCAN hits=${#hits[@]} fired=$fired n=$n"
exit $rc
