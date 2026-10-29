#!/usr/bin/env bash
# approval-check.sh — the controller's READ-ONLY reader of ~/.claude/state/approvals.log (written only by the aide via approve.sh).
#   approval-check.sh [--since "<2:30 PM | ISO | YYYY-MM-DD>"] [--last N] [--id N] [pattern]
# Line format: #<id> | <YYYY-MM-DD h:MM AM/PM TZ> | <session> | Joe: "<verbatim>" | re: <what>
# Prints matching data lines prefixed age=<N>m; exit 0 if >= 1 matched, 1 if none, 2 on usage error or an UNSAFE FILE.
# REFUSES (exit 2) a file that is not mode 600 or not owned by the current user. Never writes.
# Order: --id | --since filter, then pattern (case-insensitive ERE), then --last N. Test override: APPROVALS_FILE.
set -uo pipefail
LOG="${APPROVALS_FILE:-$HOME/.claude/state/approvals.log}"
DATA_RE='^#[0-9]+ \| '

run_check() {
  local since="" last="" pat="" idq=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 ;;
      --last) last="${2:-}"; shift 2 ;;
      --id) idq="${2:-}"; shift 2 ;;
      --*) echo "approval-check.sh: unknown flag $1" >&2; return 2 ;;
      *) pat="$1"; shift ;;
    esac
  done
  local se=""
  if [ -n "$since" ]; then
    se=$(date -d "$since" +%s 2>/dev/null) || { echo "approval-check.sh: cannot parse --since '$since'" >&2; return 2; }
  fi
  case "$last" in ""|*[!0-9]*) [ -z "$last" ] || { echo "approval-check.sh: --last needs a number" >&2; return 2; } ;; esac
  case "$idq" in ""|*[!0-9]*) [ -z "$idq" ] || { echo "approval-check.sh: --id needs a number" >&2; return 2; } ;; esac
  [ -e "$LOG" ] || { echo "approval-check.sh: no approvals file at $LOG" >&2; return 1; }
  local mode owner me; mode=$(stat -c %a "$LOG" 2>/dev/null); owner=$(stat -c %U "$LOG" 2>/dev/null); me=$(id -un)
  if [ "$mode" != 600 ] || [ "$owner" != "$me" ]; then
    echo "approval-check.sh: REFUSING to read $LOG: mode $mode owner $owner (required: mode 600 owner $me). Approvals from an unsafe file are not trusted; fix the file or ask the aide." >&2
    return 2
  fi
  [ -r "$LOG" ] || { echo "approval-check.sh: cannot read $LOG" >&2; return 1; }
  local now line ts e out="" n=0 lid flags dups; now=$(date +%s)
  dups=$(grep -E "$DATA_RE" "$LOG" | cut -d' ' -f1 | sort | uniq -d)
  while IFS= read -r line; do
    [[ "$line" =~ $DATA_RE ]] || continue
    lid="${line%% | *}"; lid="${lid#\#}"
    ts="${line#* | }"; ts="${ts%% | *}"; e=$(date -d "$ts" +%s 2>/dev/null) || e=""
    if [ -n "$idq" ] && [ "$lid" != "$idq" ]; then continue; fi
    if [ -n "$se" ] && [ -n "$e" ]; then [ "$e" -ge "$se" ] || continue; fi   # unparsed stamp: fail open, always included
    if [ -n "$pat" ]; then printf '%s\n' "$line" | grep -qiE -- "$pat" 2>/dev/null || continue; fi
    flags=""
    [ -n "$e" ] || flags="UNPARSED-STAMP "
    [[ "$ts" =~ [0-9]:[0-9]x ]] && flags+="X-MINUTE-STAMP "
    grep -qxF -- "#$lid" <<< "$dups" && flags+="DUPLICATE-NUMBER #$lid "
    if [ -n "$e" ]; then out+="age=$(( (now - e) / 60 ))m $flags$line"$'\n'; else out+="age=? $flags$line"$'\n'; fi
    n=$((n+1))
  done < "$LOG"
  [ "$n" -gt 0 ] || return 1
  if [ -n "$last" ]; then printf '%s' "$out" | tail -n "$last"; else printf '%s' "$out"; fi
  return 0
}

selftest() {
  local d fail=0 f out rc; d=$(mktemp -d "$HOME/.cache/tmp/apcheck-selftest.XXXXXX") || { echo "FAIL setup"; return 1; }
  f="$d/a.log"; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
  local t_old t_new
  t_old=$(date -d '3 days ago' '+%F %-I:%M %p %Z'); t_new=$(date -d '10 minutes ago' '+%F %-I:%M %p %Z')
  { echo '# header comment'; echo "#1 | $t_old | aide | Joe: \"promote the binary\" | re: promote"; echo "#2 | $t_new | aide | Joe: \"yes ship it\" | re: the deploy"; } > "$f"
  chmod 600 "$f"; cp "$f" "$d/before"; LOG="$f"
  out=$(run_check); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 2 ] && ok "all lines, exit 0" || bad "all: rc=$rc $out"
  echo "$out" | grep -q '^age=[0-9]*m #[12] | ' && ok "age prefix: $(echo "$out" | tail -n1 | cut -c1-50)" || bad "age prefix"
  out=$(run_check "deploy"); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 1 ] && ok "pattern match" || bad "pattern rc=$rc"
  out=$(run_check "nomatchxyz"); rc=$?; [ $rc -eq 1 ] && [ -z "$out" ] && ok "no match exit 1" || bad "nomatch rc=$rc"
  out=$(run_check --since "$(date -d '1 hour ago' '+%F %T')"); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 1 ] && ok "--since ISO 1h" || bad "since rc=$rc $out"
  out=$(run_check --since "$(date -d '1 hour ago' '+%FT%T')"); rc=$?; [ $rc -eq 0 ] && ok "--since ISO T form" || bad "since T rc=$rc"
  out=$(run_check --since "$(date -d '5 days ago' '+%F')"); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 2 ] && ok "--since YYYY-MM-DD (5 days ago: both)" || bad "since date rc=$rc"
  out=$(run_check --since "$(date -d '1 minute ago' '+%-I:%M %p')"); rc=$?; [ $rc -eq 1 ] && ok "--since 12-h time, none newer" || bad "since 12h rc=$rc $out"
  out=$(run_check --last 1); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 1 ] && echo "$out" | grep -q 'ship it' && ok "--last 1 is newest" || bad "last rc=$rc"
  out=$(run_check --id 1); rc=$?; [ $rc -eq 0 ] && [ "$(echo "$out" | wc -l)" = 1 ] && echo "$out" | grep -q '#1 | .*promote the binary' && ok "--id 1 prints one approval" || bad "--id 1 rc=$rc $out"
  out=$(run_check --id 9); rc=$?; [ $rc -eq 1 ] && ok "--id 9 absent exit 1" || bad "--id 9 rc=$rc"
  out=$(run_check --since garbage 2>&1); rc=$?; [ $rc -eq 2 ] && ok "bad --since exit 2" || bad "bad since rc=$rc"
  cp "$f" "$d/open.log"; chmod 644 "$d/open.log"; LOG="$d/open.log"
  out=$(run_check 2>&1); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -q 'REFUSING.*mode 644' && ok "mode 644 refused (exit 2): $out" || bad "644 rc=$rc $out"
  chmod 600 "$d/open.log"; out=$(run_check 2>&1); rc=$?; [ $rc -eq 0 ] && ok "same file at 600 reads" || bad "600 rc=$rc"
  if [ "$(id -u)" = 0 ]; then echo "SKIP foreign-owner test (running as root)"; else
    out=$(LOG=/etc/hostname run_check 2>&1); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -q 'REFUSING' && ok "foreign-owned file refused (exit 2)" || bad "foreign rc=$rc $out"; fi
  LOG="$f"; cmp -s "$f" "$d/before" && ok "file unmodified" || bad "file modified"
  LOG="$d/absent"; out=$(run_check 2>&1); rc=$?; [ $rc -eq 1 ] && ok "absent file exit 1" || bad "absent rc=$rc"
  rm -rf "$d"; return $fail
}
if [ "${1:-}" = "--selftest" ]; then selftest; rc=$?; [ $rc -eq 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; exit $rc; fi
run_check "$@"
