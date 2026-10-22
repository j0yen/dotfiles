#!/usr/bin/env bash
# fleet-status-write.sh: the controller's end-of-sweep write of the FLEET STATUS report.
# Reads the report on stdin, writes $FLEET_STATUS_DIR/fleet-status.md atomically (tmp in the same dir, then mv)
# with a header line `# FLEET STATUS <12-h local time> <date> session=<name>`, a `boundary: closed` line, a blank line, the body.
# The controller's body carries one `owed: <seat> ...` line per seat (not enforced here).
# `--open` = "sweep started": writes header + `boundary: open` only (stdin optional); ctl-sweep.sh treats an open file
# as a sweep still running whatever its mtime, and the closing write at the end of the sweep flips it to closed.
# Empty (or whitespace-only) stdin without --open: exit 2, previous file untouched. The aide session reads this file;
# ctl-sweep.sh also uses its mtime to decide whether the last sweep finished.
#   fleet-status-write.sh < report.md     write (boundary: closed)
#   fleet-status-write.sh --open </dev/null   mark the sweep open
#   fleet-status-write.sh --path          print the file path
#   fleet-status-write.sh --selftest      run the checks in a temp dir
set -u
DIR="${FLEET_STATUS_DIR:-$HOME/.cache/fleet-dash}"
FILE="$DIR/fleet-status.md"

selftest() {
  local self T fail=0 out
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' RETURN
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  export FLEET_STATUS_DIR="$T/dash"
  export FLEET_STATUS_SESSION=selftest-sess

  local sample; sample="$(printf 'FLEET: rb running 2 runs, r7 running 3\nowed: rb land of 1031 after main green (since 2:10 PM)\nowed: r7 amend 1044 AC3 (since 1:50 PM)\nline two')"
  printf '%s\n' "$sample" | "$self"; chk "write exits 0" $?
  head -n1 "$T/dash/fleet-status.md" | grep -Eq '^# FLEET STATUS [0-9]{1,2}:[0-9]{2} (AM|PM) [A-Za-z0-9+-]+ [0-9]{4}-[0-9]{2}-[0-9]{2} session=selftest-sess$'; chk "header line present and shaped" $?
  [ "$(sed -n 2p "$T/dash/fleet-status.md")" = "boundary: closed" ]; chk "boundary: closed on line 2 by default" $?
  [ -z "$(sed -n 3p "$T/dash/fleet-status.md")" ]; chk "blank line after boundary" $?
  [ "$(tail -n +4 "$T/dash/fleet-status.md")" = "$sample" ]; chk "body preserved verbatim" $?
  [ "$(grep -c '^owed: ' "$T/dash/fleet-status.md")" = 2 ] && grep -q '^owed: rb land of 1031' "$T/dash/fleet-status.md" && grep -q '^owed: r7 amend 1044' "$T/dash/fleet-status.md"; chk "owed: rb / owed: r7 lines round-trip" $?

  local before; before="$(cksum <"$T/dash/fleet-status.md")"
  printf '' | "$self" 2>"$T/err"; local rc=$?
  [ "$rc" = 2 ]; chk "empty stdin exits 2" $?
  [ -s "$T/err" ]; chk "empty stdin message on stderr" $?
  [ "$(cksum <"$T/dash/fleet-status.md")" = "$before" ]; chk "empty stdin leaves previous file untouched" $?
  printf ' \n\n' | "$self" 2>/dev/null; [ $? = 2 ]; chk "whitespace-only stdin refused" $?

  "$self" --open </dev/null; chk "--open with empty stdin exits 0" $?
  [ "$(sed -n 2p "$T/dash/fleet-status.md")" = "boundary: open" ] && [ "$(wc -l <"$T/dash/fleet-status.md")" = 2 ]; chk "--open writes header + 'boundary: open' only" $?
  printf 'x\n' | "$self"; [ "$(sed -n 2p "$T/dash/fleet-status.md")" = "boundary: closed" ]; chk "next normal write flips back to closed" $?
  before="$(cksum <"$T/dash/fleet-status.md")"

  # atomic: a 4 MB rewrite must only ever be observed as the old file or the whole new file
  local oldsz newsz s seen="$T/seen" polls
  oldsz="$(stat -c %s "$T/dash/fleet-status.md")"
  head -c 4000000 /dev/zero | tr '\0' 'x' >"$T/big"; echo >>"$T/big"
  ( "$self" <"$T/big" ) &
  local wp=$!
  : >"$seen"
  while kill -0 "$wp" 2>/dev/null; do
    stat -c %s "$T/dash/fleet-status.md" 2>/dev/null >>"$seen" || echo gone >>"$seen"
  done
  wait "$wp"
  newsz="$(stat -c %s "$T/dash/fleet-status.md")"
  polls="$(wc -l <"$seen")"
  [ "$newsz" -gt 4000000 ] && ! grep -qvxE "$oldsz|$newsz" "$seen"; chk "atomic: only the old or the complete new size seen in $polls polls (old=$oldsz new=$newsz)" $?
  [ -z "$(ls -A "$T/dash" | grep -v '^fleet-status.md$')" ]; chk "no tmp files left behind" $?

  [ "$("$self" --path)" = "$T/dash/fleet-status.md" ]; chk "--path prints the file path" $?
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"
  return "$fail"
}

OPEN=0
case "${1:-}" in
  --path) echo "$FILE"; exit 0 ;;
  --selftest) selftest; exit $? ;;
  --open) OPEN=1 ;;
  "") ;;
  *) echo "usage: fleet-status-write.sh [--open|--path|--selftest] < report" >&2; exit 64 ;;
esac

mkdir -p "$DIR" || exit 1
BODY="$(mktemp "$DIR/.fleet-status.body.XXXXXX")" || exit 1
OUT="$(mktemp "$DIR/.fleet-status.out.XXXXXX")" || { rm -f "$BODY"; exit 1; }
trap 'rm -f "$BODY" "$OUT"' EXIT
if [ "$OPEN" = 1 ] && [ -t 0 ]; then : >"$BODY"; else cat >"$BODY"; fi
HAS_BODY=1; grep -q '[^[:space:]]' "$BODY" || HAS_BODY=0
if [ "$HAS_BODY" = 0 ] && [ "$OPEN" = 0 ]; then
  echo "fleet-status-write: empty report on stdin, refusing (previous $FILE left untouched)" >&2
  exit 2
fi
SESS="${FLEET_STATUS_SESSION:-${CLAUDE_SESSION_NAME:-unknown}}"
BND=closed; [ "$OPEN" = 1 ] && BND=open
{ printf '# FLEET STATUS %s %s session=%s\nboundary: %s\n' "$(date '+%-I:%M %p %Z')" "$(date +%Y-%m-%d)" "$SESS" "$BND"
  if [ "$HAS_BODY" = 1 ]; then printf '\n'; cat "$BODY"; fi; } >"$OUT" || exit 1
chmod 644 "$OUT"
mv -f "$OUT" "$FILE" || exit 1
