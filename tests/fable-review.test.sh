#!/usr/bin/env bash
# fable-review.sh + p11-tally.sh: fake claude and wm-decide, fixture sqlite db; nothing touches live state.
set -u
here=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; chk() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1 ($3)"; fail=1; fi; }
printf '# plan\nbody line\n' > "$T/page.md"
cat > "$T/claude" <<'X'
#!/usr/bin/env bash
cat > "$FAKE_STDIN"; printf '%s\n' "$@" > "$FAKE_ARGS"; echo "1. edit one"; echo "${FAKE_VERDICT-VERDICT: APPROVE-WITH-EDITS}"
X
cat > "$T/wm-decide" <<'X'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_REC"; echo d-20261101-000000-aide-ab12
X
chmod +x "$T/claude" "$T/wm-decide"
export FAKE_STDIN="$T/stdin" FAKE_ARGS="$T/args" FAKE_REC="$T/rec" FABLE_REVIEW_CLAUDE="$T/claude" WM_DECIDE_BIN="$T/wm-decide" FABLE_REVIEW_LAUNCH=env FABLE_REVIEW_OUT="$T/out.txt"
R="$here/.local/bin/fable-review.sh"
res=$("$R" "$T/page.md" 2>"$T/err"); rc=$?
chk "exit 0 and row id printed" "$([ $rc = 0 ] && grep -q '^d-2026.* VERDICT: APPROVE-WITH-EDITS' <<<"$res" && echo 0 || echo 1)" "rc=$rc res=$res"
chk "page inline on stdin" "$(grep -q 'body line' "$T/stdin" && echo 0 || echo 1)" ""
chk "fable model + high + empty tools" "$(grep -qx claude-fable-5-1 "$T/args" && grep -qx high "$T/args" && grep -qx -- --tools "$T/args" && echo 0 || echo 1)" "$(cat "$T/args")"
chk "row kind design, via fable-review, verdict in what" "$(grep -qx design "$T/rec" && grep -qx fable-review "$T/rec" && grep -q 'VERDICT: APPROVE-WITH-EDITS' "$T/rec" && echo 0 || echo 1)" "$(cat "$T/rec")"
rm -f "$T/rec"; FAKE_VERDICT="no verdict here" "$R" "$T/page.md" >/dev/null 2>"$T/err"; rc=$?
chk "unparseable: exit 3, no row" "$([ $rc = 3 ] && [ ! -e "$T/rec" ] && echo 0 || echo 1)" "rc=$rc"
"$R" "$T/missing.md" >/dev/null 2>&1; chk "missing page: exit 2" "$([ $? = 2 ] && echo 0 || echo 1)" ""
# p11-tally
db="$T/d.sqlite"; sqlite3 "$db" "create table decisions(id,ts,via,model,regrade,outcome);"
for i in $(seq 1 20); do
  v='{"verdict":"CONFIRM"}'; [ $i -le 2 ] && v='{"verdict":"CORRECT"}'
  sqlite3 "$db" "insert into decisions values('d$i','2026-11-0$((i%9+1))T10:00','verifier','claude-opus-5-5','$v','{}');"
done
sqlite3 "$db" "insert into decisions values('x1','2026-11-01T11:00','verifier','claude-sonnet-5-5','{\"verdict\":\"CORRECT\"}','{}'),('x2','2026-10-30T10:00','verifier','claude-opus-5-5','{\"verdict\":\"CORRECT\"}','{}');"
P="$here/.local/bin/p11-tally.sh"
o=$(P11_DB="$db" "$P"); chk "tally 20 graded, 2 corrected = KEEP" "$(grep -q 'rows=20/20 graded=20 corrected=2 .*state=KEEP' <<<"$o" && echo 0 || echo 1)" "$o"
sqlite3 "$db" "update decisions set outcome='{\"state\":\"bad\"}' where id in('d5','d6');"
o=$(P11_DB="$db" "$P"); chk "4 corrected = REVERT" "$(grep -q 'corrected=4 .*state=REVERT' <<<"$o" && echo 0 || echo 1)" "$o"
sqlite3 "$db" "update decisions set regrade=null where id in('d7');"
o=$(P11_DB="$db" "$P"); chk "ungraded row = PENDING" "$(grep -q 'graded=19 .*state=PENDING' <<<"$o" && echo 0 || echo 1)" "$o"
P11_DB="$T/none" "$P" >/dev/null 2>&1; chk "missing db exit 2" "$([ $? = 2 ] && echo 0 || echo 1)" ""
exit $fail
