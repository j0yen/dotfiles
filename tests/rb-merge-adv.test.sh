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

OID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # = the default COMMIT of the fixture rows: the PR head the ADV rows vouch for
HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
  "pr merge") mh=""; prev=""; for a in "$@"; do [ "$prev" = "--match-head-commit" ] && mh="$a"; prev="$a"; done
    [ "$mh" = "$STUB_HEAD" ] || { echo "gh: head commit does not match --match-head-commit" >&2; exit 1; }   # like GitHub: a merge pinned to a stale oid is refused
    exit 0 ;;
  "pr view") case "$*" in
      *mergeCommit*) echo "b1b2c3d4e5f60123456789abcdef0123456789ab" ;;
      *headRefOid*) echo "$STUB_HEAD" ;;
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
export STUB_LOG="$tmp" STUB_OID="$OID" STUB_HEAD="$OID" WM_DECIDE_BIN="$tmp/wm-decide" RB_MERGE_GH="$tmp/gh"
PASSLOG="$tmp/adv-pass.log"; echo "adversarial verifier output" > "$PASSLOG"
EMPTYLOG="$tmp/adv-empty.log"; : > "$EMPTYLOG"
ABSENTLOG="$tmp/adv-absent.log"
PASSW='ADV-PASS {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': checked the brief items'
FAILW='ADV-FAIL {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': item 3 not met'
UNVW='ADV-UNVERIFIED {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': could not run'
adv() { printf '{"role":"adv","what":%s%s}' "$(jq -Rn --arg w "$1" '$w')" "${2:+,$2}"; }   # adv WHAT [extra json members]
rawj() { jq -Rn --arg r "$1" '$r'; }   # a JSON string literal holding TEXT verbatim (for a malformed-JSON column value)
wv()  { printf '{"role":"waiver","what":%s%s}' "$(jq -Rn --arg w "$1" '$w')" "${2:+,$2}"; }

# case NAME REPO PR ROWS_JSON_ARRAY [brief_in-json] [brief_tok] -> runs rb-merge.sh against a fresh ledger; sets rc, err, ids (G V rows...); fresh calls log
case_run() {
  local name=$1 repo=$2 pr=$3 rows=$4 bin=${5:-[]} btok=${6:-} st="$tmp/st-$1"
  mkdir -p "$st"
  ids="$(python3 -I "$fx/mkledger.py" "$st" "{\"repo\":\"$repo\",\"pr\":$pr,\"suffix\":\"$(( ++caseno ))\"${CASE_COMMIT:+,\"commit\":\"$CASE_COMMIT\"},\"rows\":$rows,\"brief_in\":$bin,\"brief_tok\":\"$btok\"}")" || { bad "$name: ledger fixture failed"; return 1; }
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
check "$(grep -c '^ADV-OK ' "$tmp/err")" 0 "(a) no ADV-OK marker when the trigger does not fire"
REPO=j0yen/synthorg; PR=434
# (b)..(j)
case_run b $REPO $PR '[]'; refused "(b) synthorg PR with no ADV row: ADV-MISSING" ADV-MISSING
case_run c $REPO $PR "[$(adv "$FAILW")]"; refused "(c) newest ADV row is ADV-FAIL: ADV-NOT-PASS" ADV-NOT-PASS
case_run d $REPO $PR "[$(adv "$PASSW" '"commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"')]"; refused "(d) the ADV-PASS names another COMMIT: ADV-STALE" ADV-STALE
case_run e $REPO $PR "[$(adv "$PASSW")]"; passed "(e) a valid ADV-PASS for (G, COMMIT): proceeds to merge"
check "$(grep -c "GATE_OK=$V\] pr merge" "$tmp/calls")" 1 "(e) gh pr merge carries WM_DECIDE_GATE_OK"
check "$(grep '^ADV-OK ' "$tmp/err")" "ADV-OK ${rowids[0]} 2026-10-24T11:01:00-07:00 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa $REPO#$PR" "(e) the triggered pass prints ADV-OK <A-id> <A-ts> <H> <owner/name>#<pr> (one line)"
check "$(grep -c '^ADV-OK ' "$tmp/err")" 1 "(e) exactly one ADV-OK marker"
# G1: a row that ends right after the log path (no ':' or space) matches the grammar (red at 33924c6: ADV_RE ended (:| ))
ENDW='ADV-PASS {repo}#{pr} COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"
case_run e2 $REPO $PR "[$(adv "$ENDW")]"; passed "(e2) G1: an ADV-PASS whose what ends right after the log path proceeds"
case_run e3 $REPO $PR "[$(adv "${ENDW/$PASSLOG/$ABSENTLOG}")]"; refused "(e3) G1: a path-terminated row naming an absent log is ADV-NOLOG (it matched the grammar)" ADV-NOLOG
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

# same-second tie fails closed: order by ts only, the id never breaks a tie (red at 33924c6: PASS with the higher id won)
case_run t1 $REPO $PR "[$(adv "$PASSW" '"min":5'),$(adv "$FAILW" '"min":5')]"; refused "(t1) PASS (lower id) and FAIL (higher id) at the same ts: refused" ADV-NOT-PASS
case_run t2 $REPO $PR "[$(adv "$FAILW" '"min":5'),$(adv "$PASSW" '"min":5')]"; refused "(t2) FAIL (lower id) and PASS (higher id) at the same ts: refused" ADV-NOT-PASS
case_run t3 $REPO $PR "[$(adv "$PASSW" '"min":5'),$(adv "$UNVW" '"min":5')]"; refused "(t3) PASS and ADV-UNVERIFIED at the same ts: refused" ADV-NOT-PASS
case_run t4 $REPO $PR "[$(adv "$PASSW" '"min":5'),$(adv "$PASSW" '"min":5')]"; passed "(t4) two PASS rows at the same ts: proceeds"
case_run t5 $REPO $PR "[$(adv "$FAILW" '"min":4'),$(adv "$PASSW" '"min":5'),$(adv "$PASSW" '"min":5')]"; passed "(t5) an older FAIL under two same-ts PASS rows: proceeds"

# provenance: an ADV row counts only with ledger via=verifier (a caller-set --via flag: residual risk named in the PR body)
case_run p1 $REPO $PR "[$(adv "$PASSW" '"via":"seat-tick"')]"; refused "(p1) an ADV-PASS recorded via=seat-tick: ADV-MISSING" ADV-MISSING
case_run p2 $REPO $PR "[$(adv "$PASSW" '"via":"r7"')]"; refused "(p2) an ADV-PASS recorded via=r7: ADV-MISSING" ADV-MISSING
case_run p3 $REPO $PR "[$(adv "$PASSW" '"via":"verifier"')]"; passed "(p3) an ADV-PASS recorded via=verifier: proceeds"
# filter BEFORE select: a newer non-verifier PASS must not hide (or replace) an older verifier FAIL
case_run p4 $REPO $PR "[$(adv "$FAILW" '"min":1'),$(adv "$PASSW" '"min":2,"via":"seat-tick"')]"; refused "(p4) older verifier FAIL + newer seat-tick PASS: ADV-NOT-PASS (not MISSING, not a pass)" ADV-NOT-PASS
case_run p5 $REPO $PR "[$(adv "$PASSW" '"min":1'),$(adv "$FAILW" '"min":2,"commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"')]"; passed "(p5) a newer FAIL for another COMMIT does not decide: the older PASS for this COMMIT proceeds"
OTHERPR='ADV-FAIL {repo}#999 COMMIT={commit} agent=verifier:v434-adv scope=adversarial log='"$PASSLOG"': other pr'
case_run p6 $REPO $PR "[$(adv "$PASSW" '"min":1'),$(adv "$OTHERPR" '"min":2')]"; passed "(p6) a newer FAIL for another PR does not decide"
# M1 holes: rows the mutations h (scope=adversarial dropped) and i (agent=verifier: prefix dropped) would turn green
case_run s1 $REPO $PR "[$(adv "${PASSW/scope=adversarial/scope=suite}")]"; refused "(s1) an otherwise valid PASS with scope=suite: ADV-MISSING" ADV-MISSING
case_run s2 $REPO $PR "[$(adv "${PASSW/agent=verifier:v434-adv/agent=seat:r7}")]"; refused "(s2) an otherwise valid PASS with agent=seat:r7: ADV-MISSING" ADV-MISSING

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
  else   # bad:<reason> -- the one refusal line AND the reason line (so a refusal for the wrong reason is red)
    check "$rc:$(merged):$(gated):$(grep -cx "ADV-WAIVER-BAD - $2#$3" "$tmp/err"):$(grep -cx "ADV-REASON ${5#bad:}" "$tmp/err")" "4:0:0:1:1" "$6 [reason ${5#bad:}]"
  fi
}
waive_case k1 $REPO $PR "$(wv "$WOK")" ok "(k1) a valid controller waiver proceeds, logs ADV-WAIVED <id>, merge-done runs"
check "$(grep -c '^wmd merge-done' "$tmp/calls")" 1 "(k1) merge-done ran after the waived merge"
waive_case k2 $REPO $PR "$(wv "$WOK" '"agent":"r7"')" bad:agent "(k2) an r7-authored waiver is refused (ADV-WAIVER-BAD)"
waive_case k3 $REPO $PR "$(wv "$WOK agent=controller" '"agent":"r7"')" bad:agent "(k3) what says agent=controller but the author column is r7: refused"
waive_case k3b $REPO $PR "$(wv "$WOK agent=ctl" '"agent":"r7"')" bad:agent "(k3b) what says agent=ctl but the author column is r7: refused"
waive_case k4 $REPO $PR "$(wv 'ADV-WAIVE {repo}#999 until=2999-01-01T00:00:00Z')" bad:pr-text "(k4) a waiver for another PR is refused"
waive_case k4b $REPO $PR "$(wv 'ADV-WAIVE {repo}#43 until=2999-01-01T00:00:00Z')" bad:pr-text "(k4b) a waiver for PR 43 does not cover PR 434"
waive_case k5 $REPO $PR "$(wv "$WOK" '"kind":"verdict"')" bad:kind "(k5) a waiver row of kind verdict is refused"
waive_case k6 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} until=2020-01-01T00:00:00Z')" bad:until-past "(k6) an expired until= is refused"
waive_case k7 $REPO $PR "$(wv "$WOK" '"agent":"ctl"')" bad:agent "(k7) a waiver whose agent column is ctl (not the recorder-set controller) is refused: pins the real value"
waive_case k8 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} no deadline')" bad:no-until "(k8) a waiver with no until= is refused"
waive_case k9 $REPO $PR "$(wv 'ADV-WAIVE {repo}#{pr} until=2999-01-01')" bad:no-until "(k9) an until= with no time part is refused"
waive_case k11 $REPO $PR "$(wv "$WOK" '"via":"runner"')" bad:via "(k11) a controller waiver recorded via=runner is refused"
waive_case k11b $REPO $PR "$(wv "$WOK" '"via":"controller"')" bad:via "(k11b) a controller waiver recorded via=controller (not seat-tick) is refused"
waive_case k12 $REPO $PR "$(wv "$WOK" '"regrade":null')" bad:no-regrade "(k12) a waiver with no Fable regrade is refused"
waive_case k13 $REPO $PR "$(wv "$WOK" '"regrade":{"verdict":"CORRECT"}')" bad:regrade-not-confirm "(k13) a waiver whose regrade is CORRECT is refused"
waive_case k13b $REPO $PR "$(wv "$WOK" '"regrade":{"verdict":"ESCALATE"}')" bad:regrade-not-confirm "(k13b) a waiver whose regrade is ESCALATE is refused"
waive_case k13c $REPO $PR "$(wv "$WOK" '"regrade":{"verdict":"DISAGREE"}')" bad:regrade-not-confirm "(k13c) a waiver whose regrade is DISAGREE is refused"
waive_case k14 $REPO $PR "$(wv "$WOK" '"regrade":{"by":"controller"}')" bad:regrade-agent "(k14) a CONFIRM regrade by a non-regrader agent (controller) is refused"
waive_case k14b $REPO $PR "$(wv "$WOK" '"regrade":{"by":"r7"}')" bad:regrade-agent "(k14b) a CONFIRM regrade by r7 is refused"
waive_case k1b $REPO $PR "$(wv "$WOK" '"regrade":{"ts":"2026-10-24T11:30:00-08:00"}')" ok "(k1b) a regrade.ts later by epoch in another offset (19:30Z > 18:01Z) is accepted"
waive_case k1c $REPO $PR "$(wv "$WOK" '"graded_at":"2026-10-24T10:00:00-07:00"')" ok "(k1c) graded_at is not the comparator: a graded_at earlier than ts with a later regrade.ts is accepted"
waive_case k15 $REPO $PR "$(wv "$WOK" '"regrade":{"ts":"2026-10-24T10:00:00-07:00"}')" bad:regrade-ts "(k15) a CONFIRM whose regrade.ts is EARLIER than the waiver row's ts is refused"
waive_case k15e $REPO $PR "$(wv "$WOK" '"min":1,"regrade":{"ts":"2026-10-24T11:01:00-07:00"}')" bad:regrade-ts "(k15e) a CONFIRM whose regrade.ts EQUALS the waiver row's ts is refused (strictly later)"
waive_case k15f $REPO $PR "$(wv "$WOK" '"min":1,"regrade":{"ts":"2026-10-24T18:01:00+00:00"}')" bad:regrade-ts "(k15f) the same instant written in another offset is equal by epoch: refused (a text compare would call it later)"
waive_case k15g $REPO $PR "$(wv "$WOK" '"min":1,"regrade":{"ts":"2026-10-24T11:30:00+05:00"}')" bad:regrade-ts "(k15g) a regrade.ts that sorts later as text but is earlier by epoch (06:30Z < 18:01Z) is refused"
waive_case k15b $REPO $PR "$(wv "$WOK" '"regrade":{"ts":"not-a-time"}')" bad:regrade-ts "(k15b) a CONFIRM with an unparsable regrade.ts is refused"
waive_case k15c $REPO $PR "$(wv "$WOK" '"regrade_del":["ts"]')" bad:regrade-ts "(k15c) a CONFIRM with no regrade.ts is refused"
waive_case k15d $REPO $PR "$(wv "$WOK" '"regrade":{"ts":5}')" bad:regrade-ts "(k15d) a CONFIRM whose regrade.ts is not a string is refused"
waive_case k17 $REPO $PR "$(wv "$WOK" '"regrade":'"$(rawj '{"by": "fable-regrader", "verdict": "CONFIRM", "ts": "2026-10-24T12:00:00-07:00"')")" bad:no-regrade "(k17) X1: a MALFORMED-JSON regrade is refused (ADV-WAIVER-BAD)"
waive_case k18 $REPO $PR "$(wv "$WOK" '"regrade":""')" bad:no-regrade "(k18) X1: an empty-string regrade is refused"
waive_case k19 $REPO $PR "$(wv "$WOK" '"regrade":["fable-regrader","CONFIRM"]')" bad:no-regrade "(k19) X1: a JSON-list regrade is refused"
waive_case k20 $REPO $PR "$(wv "$WOK" '"regrade_del":["by"]')" bad:regrade-agent "(k20) X1: a regrade object missing by is refused"
waive_case k21 $REPO $PR "$(wv "$WOK" '"regrade_del":["verdict"]')" bad:regrade-not-confirm "(k21) X1: a regrade object missing verdict is refused"

# X2: the helper keeps no state between calls -- the regrade is rewritten IN PLACE on one row and the NEWEST value decides at the next merge
RGJ() { printf '{"by": "%s", "verdict": "%s", "ts": "%s"}' "$1" "$2" "$3"; }
waive_run() {   # waive_run NAME WID -> rc / counts of one rb-merge call on the ledger st-NAME
  : > "$tmp/calls"; RB_MERGE_ADV_WAIVE="$2" WM_DECIDE_STATE="$tmp/st-$1" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?
}
overwrite_case() {   # overwrite_case NAME FIRST_JSON SECOND_JSON WANT1(ok|bad) WANT2(ok|bad) MSG -- first_verdict starts as FIRST (the stale value an "ignore later rewrites" bug would read)
  case_run "$1" $REPO $PR "[$(wv "$WOK" '"regrade":'"$(rawj "$2")"',"first_verdict":'"$(rawj "$2")")]"
  local wid=${rowids[0]} w1 w2
  waive_run "$1" "$wid"; [ $rc = 0 ] && w1=ok || w1=bad
  python3 -I -c 'import sqlite3,sys;d=sqlite3.connect(sys.argv[1]);d.execute("UPDATE decisions SET regrade=? WHERE id=?",(sys.argv[2],sys.argv[3]));d.commit()' "$tmp/st-$1/decisions.sqlite" "$3" "$wid"
  waive_run "$1" "$wid"; [ $rc = 0 ] && w2=ok || w2=bad
  check "$w1:$w2" "$4:$5" "$6"
}
overwrite_case x2a "$(RGJ fable-regrader CONFIRM 2026-10-24T12:00:00-07:00)" "$(RGJ fable-regrader CORRECT 2026-10-24T12:30:00-07:00)" ok bad "(x2a) X2: the regrade is rewritten CONFIRM -> CORRECT between two merges: the second is refused"
overwrite_case x2b "$(RGJ fable-regrader CORRECT 2026-10-24T12:00:00-07:00)" "$(RGJ fable-regrader CONFIRM 2026-10-24T12:30:00-07:00)" bad ok "(x2b) X2: CORRECT -> CONFIRM (later grade time, by=fable-regrader): the second is accepted"
overwrite_case x2c "$(RGJ fable-regrader CORRECT 2026-10-24T12:00:00-07:00)" '{"verdict": "CONFIRM", "ts": "2026-10-24T12:30:00-07:00"}' bad bad "(x2c) X2: CORRECT -> CONFIRM with by missing: still refused"
overwrite_case x2d "$(RGJ fable-regrader CORRECT 2026-10-24T12:00:00-07:00)" "$(RGJ r7 CONFIRM 2026-10-24T12:30:00-07:00)" bad bad "(x2d) X2: CORRECT -> CONFIRM by another agent (r7): still refused"
waive_case k16 $REPO $PR "$(wv "$WOK" '"regrade":{"verdict":"CORRECT","by":"r7"}')" bad:regrade-agent "(k16) a CORRECT from a non-regrader is refused (agent checked first)"
case_run k10 $REPO $PR '[]'; : > "$tmp/calls"; RB_MERGE_ADV_WAIVE=d-20261024-000000-r7-ffff WM_DECIDE_STATE="$tmp/st-k10" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?
check "$rc:$(merged):$(grep -cx "ADV-WAIVER-BAD - $REPO#$PR" "$tmp/err")" "4:0:1" "(k10) a waiver id that is not in the ledger is refused"

# X3: the ADV row binds the PR's LIVE head (headRefOid, read once after the ledger read), byte-equal, and the gate's oid must be that head
case_run x3a $REPO $PR "[$(adv "$PASSW")]"; check "$(grep -c 'headRefOid' "$tmp/calls"):$(grep -c -- "--match-head-commit $OID " "$tmp/calls")" "1:1" "(x3a) the one head read, and the merge is pinned --match-head-commit to that same oid"
STUB_HEAD=$HB STUB_OID=$HB case_run x3b $REPO $PR "[$(adv "$PASSW")]"; refused "(x3b) the PR head moved on (the fake gh answers another headRefOid; the gate agrees with it): ADV-STALE-HEAD before the gate" ADV-STALE-HEAD
STUB_OID=$HB case_run x3c $REPO $PR "[$(adv "$PASSW")]"
check "$rc:$(merged):$(gated):$(grep -cx "ADV-STALE-HEAD $G $REPO#$PR" "$tmp/err")" "4:0:1:1" "(x3c) the ADV row matches the head but the gate passed another oid: ADV-STALE-HEAD, no merge"
CASE_COMMIT=aaaaaaaaaaaa STUB_HEAD=aaaaaaaaaaaacccccccccccccccccccccccccccc STUB_OID=aaaaaaaaaaaacccccccccccccccccccccccccccc case_run x3d $REPO $PR "[$(adv "$PASSW" '"commit":"aaaaaaaaaaaacccccccccccccccccccccccccccc"')]"
refused "(x3d) V names a 12-hex COMMIT and the ADV row sits at ANOTHER tip sharing that prefix: ADV-COMMIT-SHORT (was ADV-OK + merge)" ADV-COMMIT-SHORT
CASE_COMMIT=aaaaaaaaaaaa case_run x3e $REPO $PR "[$(adv "$PASSW" '"commit":"'$OID'"')]"; refused "(x3e) a 12-hex V COMMIT is refused even when the ADV row is the head: ADV-COMMIT-SHORT" ADV-COMMIT-SHORT
case_run x3f $REPO $PR "[$(adv "$PASSW")]"; passed "(x3f) a matching full 40-hex COMMIT passes"
check "$(grep -c '^ADV-OK ' "$tmp/err"):$(grep -c "^ADV-OK .* $OID $REPO#$PR\$" "$tmp/err")" "1:1" "(x3f) the ADV-OK marker prints the one head oid"
# the fake gh refuses a merge pinned to a stale oid (so --match-head-commit is what protects the squash): a non-ADV PR whose head moved between the gate and the merge
STUB_HEAD=$HB case_run x3g j0yen/swarm-decide 7 '[]'
check "$rc:$(merged):$(grep -c '^wmd merge-done' "$tmp/calls")" "1:1:0" "(x3g) the merge carries --match-head-commit <gate oid>: a moved head makes gh refuse it, so no merge-done"
# old-schema ledgers refuse (never a traceback): a waiver check needs the regrade and graded_at columns
for col in regrade graded_at; do
  case_run "os-$col" $REPO $PR "[$(wv "$WOK")]"; python3 -I -c 'import sqlite3,sys;d=sqlite3.connect(sys.argv[1]);d.execute("ALTER TABLE decisions DROP COLUMN "+sys.argv[2]);d.commit()' "$tmp/st-os-$col/decisions.sqlite" "$col"
  : > "$tmp/calls"; RB_MERGE_ADV_WAIVE="${rowids[0]}" WM_DECIDE_STATE="$tmp/st-os-$col" bash "$wrap" "$V" $PR $REPO >/dev/null 2>"$tmp/err"; rc=$?
  check "$rc:$(merged):$(grep -cx "ADV-WAIVER-BAD - $REPO#$PR" "$tmp/err"):$(grep -cx 'ADV-REASON old-schema' "$tmp/err"):$(grep -c Traceback "$tmp/err")" "4:0:1:1:0" "(os) a ledger without the $col column: ADV-WAIVER-BAD + ADV-REASON old-schema, exit 4, no traceback"
done

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
# one regex: the string the helper compiles (--dump-re, read from the environment) is byte-equal to adv_ere from the sourced lib
for rp in "j0yen/synthorg 434" "j0yen/mcphost 7" "j0yen/swarm-decide 12" "j0yen/a.b-c 5"; do
  set -- $rp; want="$(adv_ere "$ADV_RE_FMT" "$1" "$2")"
  got="$(env "ADV_RE_FMT=$ADV_RE_FMT" python3 -I "$here/.local/lib/rb-merge-adv-check.py" --dump-re "$1" "$2")"
  check "$got" "$want" "no-drift: the python pattern is byte-equal to adv_ere for $1#$2"
done
check "$(grep -c 'ADV_RE_FMT' "$wrap")" 0 "no-drift: rb-merge.sh names no pattern variable (every ADV_* var reaches the helper by compgen)"
# G1 in both engines: a line ending right after the path matches under grep -E and python re
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=/x/y.log" 1
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=adversarial log=" 0
agree "$ADV_RE_FMT" j0yen/synthorg 434 "ADV-PASS j0yen/synthorg#434 COMMIT=$C40 agent=verifier:v1 scope=suite log=/x/y.log" 0
check "$(printf '%s' 'ADV-PASS x COMMIT=a scope=adversarial log=/p/q.log: z' | sed -nE "s#.*$ADV_LOG_RE.*#\1#p")" "/p/q.log" "grammar: ADV_LOG_RE extracts the log path (ERE)"

[ "$fail" = 0 ] && echo "ALL OK - rb-merge-adv ($n checks)" || echo "FAILED - rb-merge-adv"
exit "$fail"
