#!/usr/bin/env bash
# agorabus-lock-refresh-consume.sh: turns a green lock refresh in pending.txt into ONE canonical ask (A1493).
# Acts only on deny=green refreshed=yes tests=pass; any other line stays in place and is logged to refused.txt.
# Idempotent per head=<sha> via consumed.tsv (ts, head, ask id). Sends nothing; a wm-asks failure leaves pending.txt untouched.
# Env: LOCK_REFRESH_DIR (default ~/.cache/rb-seat/lock-refresh), WM_ASKS_BIN (default wm-asks).
set -u
D="${LOCK_REFRESH_DIR:-$HOME/.cache/rb-seat/lock-refresh}"
ASKS="${WM_ASKS_BIN:-wm-asks}"
P="$D/pending.txt"
[ -s "$P" ] || exit 0
line="$(grep -v '^[[:space:]]*$' "$P" | tail -n 1)"
[ -n "$line" ] || exit 0
refuse() { printf '%s refused: %s\n' "$(date -Is)" "$line" >> "$D/refused.txt"; exit 0; }
case " $line " in *" deny=green "*) ;; *) refuse;; esac
case " $line " in *" refreshed=yes "*) ;; *) refuse;; esac
case " $line " in *" tests=pass "*) ;; *) refuse;; esac
head=""; dir=""
for w in $line; do
  case "$w" in head=*) head="${w#head=}";; dir=*) dir="${w#dir=}";; esac
done
case "$head" in ''|none|*[!0-9a-f]*) refuse;; esac
[ -n "$dir" ] || refuse
C="$D/consumed.tsv"
if [ -f "$C" ] && awk -F'\t' -v h="$head" '$2==h{f=1} END{exit !f}' "$C"; then
  mv "$P" "$D/pending.consumed-$head.txt"
  exit 0
fi
due="$(date -Is -d '+2 hours')"
out="$("$ASKS" asks add --by rb --owner rb --due "$due" \
  --what "push agorabus lock refresh head $head from $dir as a PR (no force) and route to verifier" \
  --check "gh pr list -R j0yen/dotfiles --search $head --json number -q length | grep -qv '^0\$'" 2>&1)" || {
  echo "wm-asks failed: $out" >&2; exit 1; }
id="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | awk '{print $1}')"
printf '%s\t%s\t%s\n' "$(date -Is)" "$head" "${id:-unknown}" >> "$C" || exit 1
mv "$P" "$D/pending.consumed-$head.txt"
exit 0
