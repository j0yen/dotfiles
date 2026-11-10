#!/usr/bin/env bash
# agorabus-lock-refresh-consume.sh: stub wm-asks mimicking the real contract (A1493).
# add prints exactly one line (the new ask id); query --json prints a JSON list of rows (ask_id,status,owner,due,rev,what).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="${LOCKREF_CONSUME_SCRIPT:-$here/.local/bin/agorabus-lock-refresh-consume.sh}"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok() { echo "ok - $1"; }
no() { echo "NOT OK - $1"; fail=1; }
G='2026-11-09T22:30:01-08:00 deny=green refreshed=yes tests=pass dir=/x/20261109 head=71b4e63'
G2='2026-11-09T23:30:01-08:00 deny=green refreshed=yes tests=pass dir=/x/20261110 head=9c0ffee'

# setup <name>: dir with a stub wm-asks (flag files in the dir switch failure modes) and a stub ssh
setup() {
  local d="$tmp/$1"; rm -rf "$d"; mkdir -p "$d/state"
  cat > "$d/stub" <<T
#!/bin/sh
SD="$d"
echo "\$*" >> "\$SD/asklog"
row() { printf '{"ask_id": "%s", "status": "open", "owner": "rb", "due": "2026-11-10T01:30", "rev": %s, "what": "%s"}' "\$1" "\${3:-1}" "\$2"; }
[ "\$1" = asks ] || exit 2
case "\$2" in
add)
  [ -e "\$SD/add_fail" ] && exit 1
  [ -e "\$SD/add_junk" ] && { echo "queued ok"; exit 0; }
  [ -e "\$SD/add_empty" ] && exit 0
  w=""; while [ \$# -gt 0 ]; do [ "\$1" = --what ] && w="\$2"; shift; done
  n=\$(cat "\$SD/counter" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "\$SD/counter"
  echo "A\$((1530+n))|\$w" >> "\$SD/store"
  echo "A\$((1530+n))" ;;
query)
  case "\$*" in
  *--ids*)
    [ -e "\$SD/rb_none" ] && { echo "[]"; exit 0; }
    id=""; while [ \$# -gt 0 ]; do [ "\$1" = --ids ] && id="\$2"; shift; done
    [ -e "\$SD/rb_mismatch" ] && { echo "[\$(row A9999 x)]"; exit 0; }
    l=\$(grep "^\$id|" "\$SD/store") || { echo "[]"; exit 0; }
    echo "[\$(row "\$id" "\${l#*|}" 3)]" ;;
  *)
    t=""; while [ \$# -gt 0 ]; do [ "\$1" = --text ] && t="\$2"; shift; done
    [ -e "\$SD/pre_fail" ] && exit 1
    [ -e "\$SD/pre_found" ] && { echo "[\$(row A1500 "\$t" 7)]"; exit 0; }
    l=\$(grep -F "\$t" "\$SD/store" 2>/dev/null | head -n 1)
    if [ -n "\$l" ]; then echo "[\$(row "\${l%%|*}" "\$t" 3)]"; else echo "[]"; fi ;;
  esac ;;
esac
T
  chmod +x "$d/stub"
  # stub ssh: first arg = target (logged), second = the remote command string, run with wm-asks resolving to the stub
  cat > "$d/sshstub" <<T
#!/bin/sh
echo "\$1" >> "$d/sshlog"
mkdir -p "$d/bin"; ln -sf "$d/stub" "$d/bin/wm-asks"
PATH="$d/bin:\$PATH" sh -c "\$2"
T
  chmod +x "$d/sshstub"
}
run() { LOCK_REFRESH_DIR="$tmp/$1/state" WM_ASKS_BIN="$tmp/$1/stub" bash "$S" >"$tmp/$1/out" 2>&1; }
adds() { { grep '^asks add ' "$tmp/$1/asklog" 2>/dev/null || true; } | wc -l; }
rows() { [ -f "$tmp/$1/state/consumed.tsv" ] && wc -l < "$tmp/$1/state/consumed.tsv" || echo 0; }

# basic green: one ask, readback rev recorded, line leaves pending
setup g; echo "$G" > "$tmp/g/state/pending.txt"; run g; rc=$?
[ $rc -eq 0 ] && [ "$(adds g)" = 1 ] && ok "green: one ask" || no "green: one ask (rc=$rc n=$(adds g))"
grep -q -- '--by rb --owner rb' "$tmp/g/asklog" && grep -q '71b4e63' "$tmp/g/asklog" && ok "ask args" || no "ask args"
grep -Eq -- '--due [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2} ' "$tmp/g/asklog" && ok "due is ISO minute form" || no "due form"
[ ! -e "$tmp/g/state/pending.txt" ] && [ -f "$tmp/g/state/pending.consumed-71b4e63.txt" ] && ok "pending drained, line archived" || no "pending drained"
awk -F'\t' '$2=="71b4e63" && $3=="A1531" && $4=="3"{f=1} END{exit !f}' "$tmp/g/state/consumed.tsv" && ok "consumed.tsv: ts head id rev" || no "consumed.tsv row"

# e) rerun after success files no second ask
echo "$G" > "$tmp/g/state/pending.txt"; run g; rc=$?
[ $rc -eq 0 ] && [ "$(adds g)" = 1 ] && [ "$(rows g)" = 1 ] && [ ! -e "$tmp/g/state/pending.txt" ] && ok "e: rerun files no second ask" || no "e: rerun (rc=$rc adds=$(adds g))"

# a) two lines, different heads
setup a; printf '%s\n%s\n' "$G" "$G2" > "$tmp/a/state/pending.txt"; run a; rc=$?
[ $rc -eq 0 ] && [ "$(adds a)" = 2 ] && [ "$(rows a)" = 2 ] && [ ! -e "$tmp/a/state/pending.txt" ] \
  && awk -F'\t' '$2=="71b4e63"{x=1} $2=="9c0ffee"{y=1} END{exit !(x&&y)}' "$tmp/a/state/consumed.tsv" \
  && ok "a: two heads, one ask each" || no "a: two heads (rc=$rc adds=$(adds a) rows=$(rows a))"

# b) green + red: green consumed, red stays, logged once
setup b; printf '%s\n%s\n' "$G" "${G2/deny=green/deny=red}" > "$tmp/b/state/pending.txt"; run b; rc=$?
run b; rc2=$?
[ "$(adds b)" = 1 ] && [ "$(rows b)" = 1 ] && [ "$(cat "$tmp/b/state/pending.txt")" = "${G2/deny=green/deny=red}" ] \
  && [ "$(wc -l < "$tmp/b/state/refused.txt")" = 1 ] && [ $rc -eq 0 ] && [ $rc2 -eq 0 ] \
  && ok "b: green consumed, red stays, logged once over two runs" || no "b: mixed (adds=$(adds b) refused=$(wc -l < "$tmp/b/state/refused.txt"))"

# refusals: tests=fail, malformed
setup t; echo "${G/tests=pass/tests=fail}" > "$tmp/t/state/pending.txt"; run t
[ "$(adds t)" = 0 ] && [ -s "$tmp/t/state/pending.txt" ] && [ -s "$tmp/t/state/refused.txt" ] && ok "tests=fail refused" || no "tests=fail"
setup m; echo "garbage line" > "$tmp/m/state/pending.txt"; run m
[ "$(adds m)" = 0 ] && [ -s "$tmp/m/state/pending.txt" ] && [ -s "$tmp/m/state/refused.txt" ] && ok "malformed refused" || no "malformed"

# add failure
setup f; touch "$tmp/f/add_fail"; echo "$G" > "$tmp/f/state/pending.txt"; run f; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$tmp/f/state/pending.txt")" = "$G" ] && [ ! -e "$tmp/f/state/consumed.tsv" ] && ok "add failure: untouched, rc!=0" || no "add failure (rc=$rc)"

# c) add output not an id
for mode in add_junk add_empty; do
  setup c; touch "$tmp/c/$mode"; echo "$G" > "$tmp/c/state/pending.txt"; run c; rc=$?
  [ $rc -ne 0 ] && [ "$(cat "$tmp/c/state/pending.txt")" = "$G" ] && [ ! -e "$tmp/c/state/consumed.tsv" ] && ok "c: $mode leaves pending untouched" || no "c: $mode (rc=$rc)"
  grep -q unknown "$tmp/c/state/consumed.tsv" 2>/dev/null && no "c: unknown written"
done

# d) readback empty or mismatched
for mode in rb_none rb_mismatch; do
  setup d; touch "$tmp/d/$mode"; echo "$G" > "$tmp/d/state/pending.txt"; run d; rc=$?
  [ $rc -ne 0 ] && [ "$(cat "$tmp/d/state/pending.txt")" = "$G" ] && [ ! -e "$tmp/d/state/consumed.tsv" ] && ok "d: $mode leaves pending untouched" || no "d: $mode (rc=$rc)"
done

# f) pre-check finds an existing ask
setup p; touch "$tmp/p/pre_found"; echo "$G" > "$tmp/p/state/pending.txt"; run p; rc=$?
[ $rc -eq 0 ] && [ "$(adds p)" = 0 ] && awk -F'\t' '$2=="71b4e63" && $3=="A1500" && $4=="7"{f=1} END{exit !f}' "$tmp/p/state/consumed.tsv" \
  && [ ! -e "$tmp/p/state/pending.txt" ] && ok "f: existing ask found, no add, id and rev recorded" || no "f: pre-check (rc=$rc adds=$(adds p))"
setup q; touch "$tmp/q/pre_fail"; echo "$G" > "$tmp/q/state/pending.txt"; run q; rc=$?
[ $rc -ne 0 ] && [ "$(adds q)" = 0 ] && [ -s "$tmp/q/state/pending.txt" ] && ok "pre-check failure: no add, pending kept" || no "pre-check failure"

# g) wm-asks absent, no remote
setup x; echo "$G" > "$tmp/x/state/pending.txt"
LOCK_REFRESH_DIR="$tmp/x/state" WM_ASKS_BIN="$tmp/x/missing-wm-asks" bash "$S" >"$tmp/x/out" 2>&1; rc=$?
[ $rc -eq 1 ] && [ "$(cat "$tmp/x/state/pending.txt")" = "$G" ] && grep -q 'not found' "$tmp/x/out" && [ ! -e "$tmp/x/state/consumed.tsv" ] && ok "g: absent, no remote: exit 1, pending untouched" || no "g: absent (rc=$rc)"

# h) remote mode through a stub ssh
setup h; echo "$G" > "$tmp/h/state/pending.txt"
LOCK_REFRESH_DIR="$tmp/h/state" WM_ASKS_BIN="$tmp/h/missing" WM_ASKS_REMOTE=carbon-stub WM_SSH_BIN="$tmp/h/sshstub" bash "$S" >"$tmp/h/out" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(adds h)" = 1 ] && grep -qx carbon-stub "$tmp/h/sshlog" && awk -F'\t' '$3=="A1531" && $4=="3"{f=1} END{exit !f}' "$tmp/h/state/consumed.tsv" \
  && grep -q -- '--check gh pr list -R j0yen/dotfiles' "$tmp/h/asklog" && ok "h: remote mode, quoted args reach wm-asks, readback ok" || no "h: remote (rc=$rc)"
setup i; touch "$tmp/i/rb_none"; echo "$G" > "$tmp/i/state/pending.txt"
LOCK_REFRESH_DIR="$tmp/i/state" WM_ASKS_REMOTE=carbon-stub WM_SSH_BIN="$tmp/i/sshstub" bash "$S" >"$tmp/i/out" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$tmp/i/state/pending.txt")" = "$G" ] && [ ! -e "$tmp/i/state/consumed.tsv" ] && ok "h: remote readback failure fails closed" || no "h: remote readback (rc=$rc)"

# empty / absent pending
setup e; : > "$tmp/e/state/pending.txt"; run e; rc=$?
[ $rc -eq 0 ] && [ "$(adds e)" = 0 ] && ok "empty: no-op" || no "empty"
setup n; run n; rc=$?
[ $rc -eq 0 ] && [ "$(adds n)" = 0 ] && ok "absent: no-op" || no "absent"

exit $fail
