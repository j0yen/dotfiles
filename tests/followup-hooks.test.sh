#!/usr/bin/env bash
# follow-up tracker parts D + E (approvals #114): SessionStart prints a seat's owed ids; the Stop gate refuses a sweep that ends with an uncited
# overdue id; ctl is checked against every seat. wm-decide is a fixture (the part-A contract), never the live ledger; state lives under a tmp dir.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
if [ -n "${FUP_TEST_TMP:-}" ]; then base="$FUP_TEST_TMP"; fup_base_mktemp=0
else base="$(mktemp -d "${TMPDIR:-/tmp}/followup-hooks.XXXXXX")"; fup_base_mktemp=1; fi
mkdir -p "$base"; echo "base=$base"; export FUP_TEST_TMP="$base"
tmp="$(mktemp -d -p "$base")"
trap 'rm -rf "$tmp"; if [ "${fup_base_mktemp:-0}" = 1 ] && [ -n "${base:-}" ]; then case "$base" in */followup-hooks.*) rm -rf "$base" ;; esac; fi' EXIT
fail=0; pass=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
SS="$here/.claude/hooks/seat-context-start.sh"; GATE="$here/.claude/hooks/followup-stop-gate.sh"
bash -n "$SS" && bash -n "$GATE" && bash -n "$here/.claude/hooks/followup-lib.sh" && bash -n "$here/.local/bin/seat-tick.sh"; chk "bash -n hooks, lib, seat-tick" $?
[ -x "$GATE" ]; chk "followup-stop-gate.sh executable" $?

# fake wm-decide: `followups --json [--agent X]` over $FU_FIXTURE (a list of id objects), the part-A shape
cat >"$tmp/wm-decide" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = followups ] || exit 2
agent=""; [ "${3:-}" = --agent ] && agent="$4"
[ -n "${FU_FAIL:-}" ] && exit "$FU_FAIL"
[ -n "${FU_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
jq -c --arg a "$agent" '[.[] | select($a=="" or .owner==$a)] as $i | {owed:($i|length), overdue:([$i[]|select(.state=="overdue")]|length), escalated:([$i[]|select(.state=="escalated")]|length), oldest:($i[0].id // ""), by_agent:($i|group_by(.owner)|map({(.[0].owner):length})|add // {}), ids:$i}' "$FU_FIXTURE"
FAKE
chmod +x "$tmp/wm-decide"
export WM_DECIDE_BIN="$tmp/wm-decide" FU_FIXTURE="$tmp/fix.json" HOME="$tmp/home" SEATS_TABLE="$tmp/none.tsv" FOLLOWUP_STOP_FIRES_LOG="$tmp/state/fires.log"
mkdir -p "$HOME"; unset TMUX
echo '[{"id":"d-rb01","owner":"rb","age_h":3.1,"state":"owed"},{"id":"d-r701","owner":"r7","age_h":30.5,"state":"overdue"}]' >"$FU_FIXTURE"

# a. SessionStart
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"
grep -qF 'FOLLOW-UPS OWED (seat rb): 1 owed, 0 overdue: d-rb01 3.1h owed' <<<"$o"; chk "a: seat rb SessionStart prints its owed id" $?
! grep -q 'd-r701' <<<"$o"; chk "a: seat rb does not see r7's id" $?
o="$(WM_SEAT=r7 bash "$SS" 2>&1 </dev/null)"
grep -qF 'FOLLOW-UPS OWED (seat r7): 1 owed, 1 overdue: d-r701 30.5h overdue' <<<"$o" && ! grep -q 'd-rb01' <<<"$o"; chk "a: seat r7 sees only its own overdue id" $?
many="$(jq -nc '[range(0;12) | {id:("d-m\(.)"),owner:"rb",age_h:1,state:"owed"}]')"; echo "$many" >"$FU_FIXTURE"
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null | grep 'FOLLOW-UPS')"
grep -q 'd-m9 1h owed and 2 more$' <<<"$o" && ! grep -q 'd-m10' <<<"$o"; chk "a: capped at 10 ids + 'and 2 more'" $?
echo '[]' >"$FU_FIXTURE"
o="$(WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; ! grep -q 'FOLLOW-UPS\|unmeasured' <<<"$o"; chk "a: nothing owed -> silent" $?
# d. SessionStart unmeasured
o="$(WM_DECIDE_BIN="$tmp/missing" WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"
grep -q '^follow-ups: unmeasured (.*absent)' <<<"$o"; chk "d: WM_DECIDE_BIN missing -> SessionStart prints unmeasured" $?
o="$(FU_FAIL=3 WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; grep -q '^follow-ups: unmeasured (exit 3)' <<<"$o"; chk "d: non-zero exit -> unmeasured (exit 3)" $?
o="$(FU_GARBAGE=1 WM_SEAT=rb bash "$SS" 2>&1 </dev/null)"; grep -q '^follow-ups: unmeasured (non-JSON output)' <<<"$o"; chk "d: non-JSON -> unmeasured" $?

# The Stop gate cite-or-clear cases (b-g) were superseded by the fingerprinted canonical gate (ledger ask A1307); see tests/followup-loop.test.sh.

# registration
S="$here/.claude/settings.json"
n="$(jq -r '[.hooks.Stop[] | select(.matcher=="") | .hooks[] | select(.type=="command" and .command=="/home/jsy/.claude/hooks/followup-stop-gate.sh")] | length' "$S")"
[ "$n" = 1 ]; chk "followup-stop-gate.sh registered once under Stop (matcher \"\", same shape as seat-ask-inject.sh)" $?
[ "$(grep -c 'followup-stop-gate\|followup-lib\|D1\|D2\|^- \*\*E ' "$here/docs/mechanisms.md")" -ge 3 ]; chk "docs/mechanisms.md has the D1, D2 and E lines" $?
echo "followup-hooks: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
