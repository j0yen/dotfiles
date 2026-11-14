#!/usr/bin/env bash
# agorabus-lock-refresh-consume.sh: turns each green lock refresh in pending.txt into ONE canonical ask (A1493).
# Every non-empty line is processed. A line leaves pending.txt only when its own obligation is confirmed
# (ask found or filed, then read back); unconfirmed lines are rewritten atomically into pending.txt.
# Acts only on deny=green refreshed=yes tests=pass; any other line stays and is logged once to refused.txt.
# Idempotent per head=<sha> via consumed.tsv (ts, head, ask id, rev) plus a pre-check query on the ask store.
# Env: LOCK_REFRESH_DIR (default ~/.cache/rb-seat/lock-refresh), WM_ASKS_BIN (default wm-asks),
#      WM_ASKS_REMOTE (optional ssh target that runs wm-asks, the ask store lives on carbon), WM_SSH_BIN (default ssh).
set -u
D="${LOCK_REFRESH_DIR:-$HOME/.cache/rb-seat/lock-refresh}"
ASKS="${WM_ASKS_BIN:-wm-asks}"
REMOTE="${WM_ASKS_REMOTE:-}"
SSH="${WM_SSH_BIN:-ssh}"
P="$D/pending.txt"
C="$D/consumed.tsv"
[ -s "$P" ] || exit 0
grep -q '[^[:space:]]' "$P" || exit 0

if [ -z "$REMOTE" ] && ! command -v "$ASKS" >/dev/null 2>&1; then
  echo "agorabus-lock-refresh-consume: wm-asks not found ($ASKS) and WM_ASKS_REMOTE unset; pending left untouched" >&2
  exit 1
fi

# wa <args...>: run wm-asks locally, or through ssh with every argument shell-quoted for the remote side
wa() {
  if [ -n "$REMOTE" ]; then
    local q=() a
    for a in "$@"; do q+=("$(printf '%q' "$a")"); done
    "$SSH" "$REMOTE" "wm-asks ${q[*]}"
  else
    "$ASKS" "$@"
  fi
}

# rowinfo <expected id or empty>: stdin = query JSON list; prints "<id> <rev>" of the first valid row, else rc 1.
# With an expected id the list must hold exactly one row carrying that id.
rowinfo() {
  python3 -I -c '
import json, re, sys
exp = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(rows, list) or (exp and len(rows) != 1):
    sys.exit(1)
for r in rows:
    if not isinstance(r, dict):
        continue
    i, v = r.get("ask_id"), r.get("rev")
    if isinstance(i, str) and re.fullmatch(r"[A-Z][0-9]+", i) and (not exp or i == exp) \
       and isinstance(v, int) and not isinstance(v, bool):
        print(i, v)
        sys.exit(0)
sys.exit(1)
' "$1"
}

log_refused() {
  awk -v l="$1" '{ i = index($0, "refused: "); if (i && substr($0, i + 9) == l) f = 1 } END { exit !f }' \
    "$D/refused.txt" 2>/dev/null && return 0
  printf '%s refused: %s\n' "$(date -Is)" "$1" >> "$D/refused.txt"
}

record() { printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" >> "$C"; }

# consume <head> <dir>: 0 = confirmed (drop the line), 1 = leave the line in place
consume() {
  local head="$1" dir="$2" out j info id rev flat
  if [ -f "$C" ] && awk -F'\t' -v h="$head" '$2==h{f=1} END{exit !f}' "$C"; then
    return 0
  fi
  if ! j="$(wa asks query --status all --text "lock refresh head $head" --json 2>/dev/null)"; then
    echo "wm-asks pre-check query failed for head $head" >&2; return 1
  fi
  flat="$(printf '%s' "$j" | tr -d '[:space:]')"
  if [ -n "$flat" ] && [ "$flat" != "[]" ]; then
    if info="$(printf '%s' "$j" | rowinfo '')"; then
      record "$head" "${info% *}" "${info#* }" || return 1
      return 0
    fi
    echo "wm-asks pre-check returned unreadable rows for head $head" >&2; return 1
  fi
  if ! out="$(wa asks add --by rb --owner rb --due "$(date -d '+2 hours' +%Y-%m-%dT%H:%M)" \
    --what "push agorabus lock refresh head $head from $dir as a PR (no force) and route to verifier" \
    --check "gh pr list -R j0yen/dotfiles --search $head --json number -q length | grep -qv '^0\$'" 2>/dev/null)"; then
    echo "wm-asks add failed for head $head" >&2; return 1
  fi
  id="$(printf '%s' "$out" | tr -d '[:space:]')"
  if [ "$(printf '%s\n' "$out" | grep -c '[^[:space:]]')" != 1 ] || ! printf '%s' "$id" | grep -Eq '^[A-Z][0-9]+$'; then
    echo "wm-asks add output is not a single ask id for head $head" >&2; return 1
  fi
  if ! j="$(wa asks query --ids "$id" --json 2>/dev/null)" || ! info="$(printf '%s' "$j" | rowinfo "$id")"; then
    echo "wm-asks readback failed for $id (head $head)" >&2; return 1
  fi
  rev="${info#* }"
  record "$head" "$id" "$rev" || return 1
  return 0
}

rc=0; keep=(); done_n=0
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s' "$line" | grep -q '[^[:space:]]' || continue
  head=""; dir=""
  for w in $line; do
    case "$w" in head=*) head="${w#head=}";; dir=*) dir="${w#dir=}";; esac
  done
  green=1
  case " $line " in *" deny=green "*) ;; *) green=0;; esac
  case " $line " in *" refreshed=yes "*) ;; *) green=0;; esac
  case " $line " in *" tests=pass "*) ;; *) green=0;; esac
  case "$head" in ''|none|*[!0-9a-f]*) green=0;; esac
  [ -n "$dir" ] || green=0
  if [ "$green" = 0 ]; then log_refused "$line"; keep+=("$line"); continue; fi
  if consume "$head" "$dir"; then
    printf '%s\n' "$line" >> "$D/pending.consumed-$head.txt"; done_n=$((done_n+1))
  else
    keep+=("$line"); rc=1
  fi
done < "$P"

if [ "${#keep[@]}" -eq 0 ]; then
  rm -f "$P"
elif [ "$done_n" -gt 0 ]; then
  printf '%s\n' "${keep[@]}" > "$P.tmp.$$" && mv "$P.tmp.$$" "$P" || rc=1
fi
exit $rc
