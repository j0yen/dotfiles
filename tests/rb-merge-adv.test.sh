#!/usr/bin/env bash
# tests/rb-merge-adv.test.sh -- the ADV (adversarial-pass) pre-check in .local/bin/rb-merge.sh (merge-gate-adv). INTERIM check, not the gate: see rb-merge.sh's header.
# Hermetic: a mktemp root holds HOME / XDG_CONFIG_HOME / XDG_STATE_HOME / WM_DECIDE_STATE, one sqlite ledger per case, and a fake wm-decide + fake gh
# (WM_DECIDE_BIN / RB_MERGE_GH). The ledger rows are COPIES of captured real rows (fixtures/rb-merge-adv/real-rows.json: G = d-20261024-101751-r7-d001, V = d-20261024-101957-r7-2b5b);
# only id, COMMIT, repo#pr and target fields are edited (fixtures/rb-merge-adv/mkledger.py). The real ledger and the real wm-decide are never touched.
# Run from the repo root:  bash tests/rb-merge-adv.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="$here/.local/bin/rb-merge.sh"
fx="$here/tests/fixtures/rb-merge-adv"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rbmergeadv.XXXXXX")" || exit 2
case "$tmp" in */rbmergeadv.*) trap 'rm -rf "$tmp"' EXIT ;; *) exit 2 ;; esac
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_STATE_HOME="$tmp/home/.local/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
. "$here/.local/lib/adv-grammar.sh"
fail=0; n=0
ok()  { n=$((n+1)); echo "ok - rb-merge-adv: $1"; }
bad() { n=$((n+1)); echo "NOT OK - rb-merge-adv: $1"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

OID=a1b2c3d4e5f60123456789abcdef0123456789ab
cat > "$tmp/wm-decide" <<'S'
#!/usr/bin/env bash
printf 'wmd %s\n' "$*" >> "$STUB_LOG/calls"
case "$1" in
  merge-gate) echo "PASS verdict=$2 pr=$5#$4 oid=$STUB_OID"; exit 0 ;;
  merge-done) exit 0 ;;
esac
S
cat > "$tmp/gh" <<'S'
#!/usr/bin/env bash
printf 'gh [GATE_OK=%s] %s\n' "${WM_DECIDE_GATE_OK:-}" "$*" >> "$STUB_LOG/calls"
case "$1 $2" in
  "pr view") case "$*" in
      *mergeCommit*) echo "b1b2c3d4e5f60123456789abcdef0123456789ab" ;;
      *) printf '{"title":"Fix the thing","body":"line one"}\n' ;;
    esac; exit 0 ;;
  "api repos/"*"/pulls/"*"/commits")
    q=""; prev=""; for a in "$@"; do { [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; } && q="$a"; prev="$a"; done
    printf '%s' '[{"sha":"aaaaaaaaaaaa0000","commit":{"message":"Fix the thing"}}]' | jq -r "$q"; exit $? ;;
  "api repos/"*) echo "Fix the thing"; exit 0 ;;
esac
exit 0
S
chmod +x "$tmp/wm-decide" "$tmp/gh"
export STUB_LOG="$tmp" STUB_OID="$OID" WM_DECIDE_BIN="$tmp/wm-decide" RB_MERGE_GH="$tmp/gh"
PASSLOG="$tmp/adv-pass.log"; echo "adversarial verifier output" > "$PASSLOG"
EMPTYLOG="$tmp/adv-empty.log"; : > "$EMPTYLOG"
ABSENTLOG="$tmp/adv-absent.log"
PASSW='ADV-PASS {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': checked the brief items'
FAILW='ADV-FAIL {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': item 3 not met'
UNVW='ADV-UNVERIFIED {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': could not run'
adv() { printf '{"role":"adv","what":%s%s}' "$(jq -Rn --arg w "$1" '$w')" "${2:+,$2}"; }   # adv WHAT [extra json members]
wv()  { printf '{"role":"waiver","what":%s%s}' "$(jq -Rn --arg w "$1" '$w')" "${2:+,$2}"; }

# case NAME REPO PR ROWS_JSON_ARRAY [brief_in-json] [brief_tok] -> runs rb-merge.sh against a fresh ledger; sets rc, err, ids (G V rows...); fresh calls log
case_run() {
  local name=$1 repo=$2 pr=$3 rows=$4 bin=${5:-[]} btok=${6:-} st="$tmp/st-$1"
  mkdir -p "$st"
  ids="$(python3 -I "$fx/mkledger.py" "$st" "{\"repo\":\"$repo\",\"pr\":$pr,\"suffix\":\"$(( ++caseno ))\",\"rows\":$rows,\"brief_in\":$bin,\"brief_tok\":\"$btok\"}")" || { bad "$name: ledger fixture failed"; return 1; }
  G="${ids%% *}"; rest="${ids#* }"; V="${rest%% *}"; rowids=(${rest#* })
  : > "$tmp/calls"
  WM_DECIDE_STATE="$st" bash "$wrap" "$V" "$pr" "$repo" >"$tmp/out" 2>"$tmp/err"; rc=$?
  err="$(cat "$tmp/err")"
}
caseno=0
merged() { grep -c 'pr merge' "$tmp/calls"; }
gated()  { grep -c '^wmd merge-gate' "$tmp/calls"; }
# refused NAME TOKEN: rc 4, the one stderr line `TOKEN <G> <repo>#<pr>`, no gh pr merge, no merge-gate call
refused() {
  local line; line="$(grep -E '^ADV-' "$tmp/err" | head -1)"
  check "$rc:$(merged):$(gated):$line" "4:0:0:$2 $G $REPO#$PR" "$1"
}
passed() { check "$rc:$(merged):$(gated)" "0:1:1" "$1"; }
REPO=j0yen/synthorg; PR=434

# (a) a non-trigger repo with no brief passes through to merge-gate and merges
REPO=j0yen/swarm-decide; PR=7
case_run a $REPO $PR '[]'; passed "(a) non-trigger repo, no brief, no ADV row: passes through to merge-gate and merges"
REPO=j0yen/synthorg; PR=434
# (b)..(j)
case_run b $REPO $PR '[]'; refused "(b) synthorg PR with no ADV row: ADV-MISSING" ADV-MISSING
case_run c $REPO $PR "[$(adv "$FAILW")]"; refused "(c) newest ADV row is ADV-FAIL: ADV-NOT-PASS" ADV-NOT-PASS
case_run d $REPO $PR "[$(adv "$PASSW" '"commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"')]"; refused "(d) the ADV-PASS names another COMMIT: ADV-STALE" ADV-STALE
case_run e $REPO $PR "[$(adv "$PASSW")]"; passed "(e) a valid ADV-PASS for (G, COMMIT): proceeds to merge"
check "$(grep -c "GATE_OK=$V\] pr merge" "$tmp/calls")" 1 "(e) gh pr merge carries WM_DECIDE_GATE_OK"
case_run f $REPO $PR "[$(adv "$PASSW" '"min":1'),$(adv "$FAILW" '"min":2')]"; refused "(f) ADV-PASS then ADV-FAIL: the newest decides, refused (ADV-NOT-PASS)" ADV-NOT-PASS
case_run g $REPO $PR "[$(adv "$FAILW" '"min":1'),$(adv "$PASSW" '"min":2')]"; passed "(g) ADV-FAIL then ADV-PASS: proceeds"
case_run h $REPO $PR '[]'; echo "not a database" > "$tmp/st-h/decisions.sqlite"
: > "$tmp/calls"; WM_DECIDE_STATE="$tmp/st-h" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?; G=-
refused "(h) the ledger file is not readable (garbage): ADV-UNCHECKED" ADV-UNCHECKED
rm -f "$tmp/st-h/decisions.sqlite"; : > "$tmp/calls"; WM_DECIDE_STATE="$tmp/st-h" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?; G=-
refused "(h) the ledger file is absent: ADV-UNCHECKED" ADV-UNCHECKED
case_run h3 $REPO $PR '[]'; : > "$tmp/calls"; WM_DECIDE_STATE="$tmp/st-h3" bash "$wrap" d-20261024-000000-r7-ffff $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?; G=-
refused "(h) the verdict row is not in the ledger: ADV-UNCHECKED" ADV-UNCHECKED
case_run i $REPO $PR "[$(adv "$PASSW" '"gates":"other"')]"; refused "(i) the ADV-PASS gates a different row: ADV-MISSING" ADV-MISSING
case_run j $REPO $PR "[$(adv "$UNVW")]"; refused "(j) ADV-UNVERIFIED: ADV-NOT-PASS" ADV-NOT-PASS

# log= (ctl bcc6 CORRECT 2)
NOLOGW='ADV-PASS {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial: checked the brief items'
case_run m1 $REPO $PR "[$(adv "$NOLOGW")]"; refused "(m1) an ADV-PASS without log= does not match the grammar: ADV-MISSING" ADV-MISSING
case_run m2 $REPO $PR "[$(adv "${PASSW/$PASSLOG/$ABSENTLOG}")]"; refused "(m2) log= names an absent file: ADV-NOLOG" ADV-NOLOG
case_run m3 $REPO $PR "[$(adv "${PASSW/$PASSLOG/$EMPTYLOG}")]"; refused "(m3) log= names an empty file: ADV-NOLOG" ADV-NOLOG
case_run m4 $REPO $PR "[$(adv "${PASSW/$PASSLOG/$tmp}")]"; refused "(m4) log= names a directory: ADV-NOLOG" ADV-NOLOG
case_run m5 $REPO $PR "[$(adv "${PASSW/log=$PASSLOG/log=relative.log}")]"; refused "(m5) a relative log= path does not match the grammar: ADV-MISSING" ADV-MISSING
case_run m6 $REPO $PR "[$(adv "${PASSW/COMMIT=\{commit\}/COMMIT=abc123}")]"; refused "(m6) a short COMMIT= in the ADV row does not match the grammar: ADV-MISSING" ADV-MISSING
case_run m7 $REPO 43 "[$(adv "$PASSW")]"; PR=43
case_run m8 $REPO 4 "[]"; PR=4; : > "$tmp/calls"
# an ADV-PASS for #43 (m7 ledger rows retargeted by hand: same ledger, PR 4 asked)
python3 -I "$fx/mkledger.py" "$tmp/st-m9" "{\"repo\":\"$REPO\",\"pr\":43,\"suffix\":\"91\",\"rows\":[$(adv "$PASSW")]}" >/dev/null
V9="$(python3 -I -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select id from decisions where id like \"%bb91\"").fetchone()[0])' "$tmp/st-m9/decisions.sqlite")"
: > "$tmp/calls"; WM_DECIDE_STATE="$tmp/st-m9" bash "$wrap" "$V9" 4 $REPO >/dev/null 2>"$tmp/err"; rc=$?; G=$(sed -n 's/^ADV-MISSING \([^ ]*\) .*/\1/p' "$tmp/err"); PR=4
check "$rc:$(merged):$(grep -c "^ADV-MISSING $G $REPO#4\$" "$tmp/err")" "4:0:1" "(m9) an ADV-PASS for #43 does not satisfy PR #4 (ADV-MISSING)"
PR=434

# (k) waivers
WOK='ADV-WAIVE {repo}#{pr} until=2999-01-01T00:00:00Z reason=ctl bcc6 test'
waive_case() {   # waive_case NAME REPO PR ROW_JSON WANT(ok|bad) MSG
  case_run "$1" "$2" "$3" "[$4]"
  local wid=${rowids[0]}
  : > "$tmp/calls"; RB_MERGE_ADV_WAIVE="$wid" WM_DECIDE_STATE="$tmp/st-$1" bash "$wrap" "$V" "$3" "$2" >/dev/null 2>"$tmp/err"; rc=$?
  if [ "$5" = ok ]; then
    check "$rc:$(merged):$(gated):$(grep -cx "ADV-WAIVED $wid" "$tmp/err")" "0:1:1:1" "$6"
  else
    check "$rc:$(merged):$(gated):$(grep -cx "ADV-WAIVER-BAD - $2#$3" "$tmp/err")" "4:0:0:1" "$6"
  fi
}
waive_case k1 $REPO $PR "$(wv "$WOK")" ok "(k1) a valid controller waiver proceeds, logs ADV-WAIVED <id>, merge-done runs"
check "$(grep -c '^wmd merge-done' "$tmp/calls")" 1 "(k1) merge-done ran after the waived merge"
waive_case k2 $REPO $PR "$(wv "$WOK" '"agent":"r7"')" bad "(k2) an r7-authored waiver is refused (ADV-WAIVER-BAD)"
waive_case k3 $REPO $PR "$(wv "$WOK agent=controller" '"agent":"r7"')" bad "(k3) what says agent=controller but the author column is r7: refused"
waive_case k3b $REPO $PR "$(wv "$WOK agent=ctl" '"agent":"r7"')" bad "(k3b) what says agent=ctl but the author column is r7: refused"
waive_case k4 $REPO $PR "$(wv 'ADV-WAIVE {repo}#999 until=2999-01-01T00:00:00Z')" bad "(k4) a waiver for another PR is refused"
waive_case k4b $REPO $PR "$(wv 'ADV-WAIVE {repo}#43 until=2999-01-01T00:00:00Z')" bad "(k4b) a waiver for PR 43 does not cover PR 434"
waive_case k5 $REPO $PR "$(wv "$WOK" '"kind":"verdict"')" bad "(k5) a waiver row of kind verdict is refused"
waive_case k6 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} until=2020-01-01T00:00:00Z')" bad "(k6) an expired until= is refused"
waive_case k7 $REPO $PR "$(wv "$WOK" '"agent":"ctl"')" bad "(k7) a waiver whose agent column is ctl (not the recorder-set controller) is refused: pins the real value"
waive_case k8 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} no deadline')" bad "(k8) a waiver with no until= is refused"
waive_case k9 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} until=2999-01-01')" bad "(k9) an until= with no time part is refused"
case_run k10 $REPO $PR '[]'; : > "$tmp/calls"; RB_MERGE_ADV_WAIVE=d-20261024-000000-r7-ffff WM_DECIDE_STATE="$tmp/st-k10" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(merged):$(grep -cx "ADV-WAIVER-BAD - $REPO#$PR" "$tmp/err")" "4:0:1" "(k10) a waiver id that is not in the ledger is refused"

# (l) a dotfiles PR (non-trigger repo) whose G cites a brief: each placement triggers the rule
DF=j0yen/dotfiles
for spec in 'what|["what"]|brief=/home/jsy/.cache/r7-seat/briefs/x.md' 'why|["why"]|per the brief: x' 'evidence|["evidence"]|see briefs/merge-gate-adv.md' 'tokeq|["what"]|brief=v434-adv' 'upper|["why"]|BRIEFS/x.md'; do
  IFS='|' read -r nm bin tok <<<"$spec"
  case_run "l-$nm" $DF 7 '[]' "$bin" "$tok"; REPO=$DF; PR=7
  refused "(l) a dotfiles PR whose G has the brief in $nm ('$tok'): triggers, ADV-MISSING" ADV-MISSING
done
case_run lp $DF 7 "[$(adv "$PASSW")]" '["why"]' 'brief: x'; REPO=$DF; PR=7; passed "(l) a brief-triggered PR with a valid ADV-PASS proceeds"
REPO=j0yen/synthorg; PR=434

# no-drift: rb-merge.sh holds no ADV regex literal, only the sourced variables; the helper holds none either
code="$(grep -vE '^[[:space:]]*#' "$wrap" | sed 's/[[:space:]]#[^"'"'"']*$//')"
check "$(printf '%s\n' "$code" | grep -cE 'ADV-(PASS|FAIL|UNVERIFIED)|scope=adversarial|ADV-WAIVE[ _]|briefs\?\[')" 0 "no-drift: rb-merge.sh has ADV-PASS/FAIL/UNVERIFIED, scope=adversarial, ADV-WAIVE, the brief ERE only in comments"
printf '%s\n' "$code" | grep -q 'adv-grammar.sh' && ok "no-drift: rb-merge.sh sources adv-grammar.sh" || bad "rb-merge.sh does not source adv-grammar.sh"
check "$(grep -cE 'ADV-(PASS|FAIL|UNVERIFIED)|scope=adversarial|ADV-WAIVE[ _]|briefs\?\[' "$here/.local/lib/rb-merge-adv-check.py")" 0 "no-drift: rb-merge-adv-check.py holds no copy of the grammar (it reads the environment)"
# bash grep -E and the helper's Python re agree on the grammar (the lib stays in the shared subset)
agree() {   # agree FMT REPO PR TEXT WANT(1|0): grep -E vs python re, both with the placeholders filled
  local ere g p; ere="$(adv_ere "$1" "$2" "$3")"
  printf '%s' "$4" | grep -qE "$ere"; g=$?; [ $g = 0 ] && g=1 || g=0
  p="$(FMT="$1" T="$4" python3 -I -c 'import os,re,sys;print(1 if re.search(os.environ["FMT"].replace("@REPO@",re.escape(sys.argv[1])).replace("@PR@",sys.argv[2]),os.environ["T"]) else 0)' "$2" "$3")"
  check "$g:$p" "$5:$5" "grammar: grep -E and python re agree ($5) on: ${4:0:60}"
}
C40=$(printf 'a%.0s' $(seq 40))
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=/x/y.log: ok" 1
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-FAIL j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=/x/y.log and more" 1
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial: no log" 0
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#43 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=/x/y.log: ok" 0
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yenxsynthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=/x/y.log: ok" 0
agree "$ADV_RE_FMT" j0yen/synthorg 434 "MERGE-OK j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=suite" 0
agree "$ADV_WAIVE_RE_FMT" j0yen/synthorg 434 "x ADV-WAIVE j0yen/synthorg#434 until=2999-01-01T00:00:00Z" 1
agree "$ADV_WAIVE_RE_FMT" j0yen/synthorg 43 "x ADV-WAIVE j0yen/synthorg#434 until=2999-01-01T00:00:00Z" 0
check "$(printf '%s' 'ADV-PASS x COMMIT=a scope=adversarial log=/p/q.log: z' | sed -nE "s#.*$ADV_LOG_RE.*#\1#p")" "/p/q.log" "grammar: ADV_LOG_RE extracts the log path (ERE)"

[ "$fail" = 0 ] && echo "ALL OK - rb-merge-adv ($n checks)" || echo "FAILED - rb-merge-adv"
exit "$fail"
