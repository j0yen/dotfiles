#!/usr/bin/env bash
# tests/rb-land-push.test.sh -- .local/bin/rb-land-push.sh: a land-branch push needs a LIVE controller CONFIRM row that names HEAD (commit or tree 8-hex, whole token);
# every refusal prints exactly one `REFUSED <reason>` line, exits 2, and leaves the origin ref unchanged; a valid row pushes (fast-forward only) and logs pushing -> pushed.
# Throwaway HOME + a temp sqlite built from the decisions schema (id/ts/agent/kind/what/regrade columns) + a bare origin and a clone. No network, no ssh, never the live db.
# Plain bash, run from the repo root:  bash tests/rb-land-push.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="${RB_LAND_PUSH_UNDER_TEST:-$here/.local/bin/rb-land-push.sh}"   # a mutation proof points this at a throwaway copy
T="$(mktemp -d "${TMPDIR:-/tmp}/rblp.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok - rb-land-push: $1"; }
bad() { n=$((n+1)); echo "NOT OK - rb-land-push: $1"; fail=1; }
export HOME="$T/home" WM_DECISIONS_DB="$T/d.sqlite" RB_LAND_PUSH_LOG="$T/home/.local/state/rb-seat/land-push.log" WM_SEAT=rb-test; unset CLAUDE_AGENT_ID
mkdir -p "$HOME"; g=(git -c user.name=t -c user.email=t@t)
# the schema line from `sqlite3 decisions.sqlite '.schema decisions'` (columns the wrapper reads)
sqlite3 "$WM_DECISIONS_DB" "create table decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, kind TEXT NOT NULL, what TEXT NOT NULL, regrade TEXT);"
git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/wt" 2>/dev/null
( cd "$T/wt" && echo a > f && "${g[@]}" add f && "${g[@]}" commit -qm a && git push -q origin HEAD:refs/heads/main && git push -q origin HEAD:refs/heads/wm-build/x && echo b >> f && "${g[@]}" commit -qam b )
HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD); H8=${HEAD_SHA:0:8}; TREE=$(git -C "$T/wt" rev-parse 'HEAD^{tree}'); T8=${TREE:0:8}
B=wm-build/x; ID=d-20261024-100000-controller-abcd; TS=2026-10-24T10:00:00-07:00
row() { sqlite3 "$WM_DECISIONS_DB" "insert into decisions values ('$1','$2','$3','$4','$5',${6:-NULL});"; }
clear() { sqlite3 "$WM_DECISIONS_DB" "delete from decisions;"; }
tip() { git -C "$T/origin.git" rev-parse "refs/heads/$1" 2>/dev/null || echo none; }
# refused <name> <reason> <id> [branch]: one REFUSED line, rc 2, origin ref unchanged
refused() {
  local name=$1 want=$2 id=$3 br=${4:-$B} b a out rc
  b=$(tip "$br"); out=$(bash "$wrap" --confirm "$id" --repo "$T/wt" --branch "$br" 2>&1); rc=$?; a=$(tip "$br")
  if [ $rc = 2 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [[ "$out" == "REFUSED $want"* ]] && [ "$b" = "$a" ]; then ok "$name -> REFUSED $want, origin ref unchanged"; else bad "$name: rc=$rc out='$out' ref $b -> $a (want REFUSED $want)"; fi
}
clear;                                                                                  refused "no row" no-row "$ID"
row "$ID" $TS rb verdict "CONFIRM tree $T8";                                            refused "row by the wrong agent" wrong-agent "$ID"; clear
row "$ID" $TS controller note "CONFIRM tree $T8";                                       refused "kind not verdict" kind-not-verdict "$ID"; clear
row "$ID" $TS controller verdict "confirm tree $T8";                                    refused "lower-case confirm" not-confirm "$ID"; clear
row "$ID" $TS controller verdict "NO: CONFIRM tree $T8";                                refused "what does not START with CONFIRM" not-confirm "$ID"; clear
row "$ID" $TS controller verdict "CONFIRM the patch sha 36f357d0 only";                 refused "sha not named" sha-not-named "$ID"; clear
row "$ID" $TS controller verdict "CONFIRM tree ${T8}9 and ${H8}a";                      refused "an 8-hex prefix of a longer hex run is not a name" sha-not-named "$ID"; clear
row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "WITHDRAWN confirm abcd"; refused "withdrawn by a later row naming the 4-hex suffix" withdrawn "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "CORRECT $ID"; refused "CORRECTed by a later row naming the full d-id" withdrawn "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller note "WITHDRAWN abcd"; refused "a later WITHDRAWN row (note kind) still withdraws" withdrawn "$ID"
# collision (ctl c4ed E3): an UNRELATED later controller row that holds CORRECT and the confirm's 4-hex suffix as a whole token still refuses (fail closed),
# and the REFUSED line names THAT row's id (the collider), not the confirm's, after "by"
COL=d-20261024-103000-controller-9f9f
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row "$COL" 2026-10-24T10:30:00-07:00 controller verdict "CORRECT the unrelated bridge plan, tile abcd"
b=$(tip $B); out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" 2>&1); rc=$?; a=$(tip $B)
if [ $rc = 2 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [[ "$out" == "REFUSED withdrawn "* ]] && [ "${out##* by }" = "$COL" ] && [ "${out##* by }" != "$ID" ] && [ "$b" = "$a" ]; then ok "suffix-collision row refuses (fail closed) and the REFUSED line names the collider $COL: $out"; else bad "collision case: rc=$rc out='$out' (want REFUSED withdrawn ... by $COL)"; fi
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-rb-2222 2026-10-24T10:10:00-07:00 rb verdict "WITHDRAWN abcd"; sqlite3 "$WM_DECISIONS_DB" "select count(*) from decisions" >/dev/null
b=$(tip $B); out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" 2>&1); rc=$?
[ $rc = 0 ] && ok "a later WITHDRAWN row by a non-controller agent does not withdraw" || bad "non-controller withdrawal wrongly refused: $out"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"; : > "$RB_LAND_PUSH_LOG"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "Do NOT push $H8 yet";  refused "later 'Do NOT push <commit 8hex>'" do-not-push "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "CONFIRM $B at tree 0badc0de"; refused "later CONFIRM of a different sha for the same branch" superseded "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"
row d-20261024-101000-controller-1111 2026-10-24T10:10:00-07:00 controller verdict "CONFIRM wm-build/other at tree 0badc0de"
b=$(tip $B); out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" 2>&1); rc=$?
[ $rc = 0 ] && ok "a later CONFIRM for a DIFFERENT branch does not supersede" || bad "other-branch confirm wrongly superseded: $out"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"; : > "$RB_LAND_PUSH_LOG"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8" "'{\"verdict\":\"CORRECT\",\"by\":\"fable\"}'"; refused "regrade CORRECT" regrade-correct "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8" "'{\"verdict\":\"DISAGREE\"}'";                refused "regrade DISAGREE" regrade-disagree "$ID"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8";                                              refused "branch main" branch-protected "$ID" main
refused "branch master" branch-protected "$ID" master
refused "malformed d-id" bad-confirm-id "d-1; drop table decisions"
# non-ff: origin has a commit HEAD lacks
( cd "$T" && git clone -q origin.git other 2>/dev/null && cd other && git checkout -q $B && echo z > z && "${g[@]}" add z && "${g[@]}" commit -qm z && git push -q origin HEAD:refs/heads/$B )
refused "non-fast-forward" non-ff "$ID"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
# valid: the row names the TREE sha -> pushed + logged (pushing BEFORE pushed), agent recorded
out=$(CLAUDE_AGENT_ID=rlp1-test bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(tip $B)" = "$HEAD_SHA" ] && ok "valid row naming the tree sha -> pushed to origin" || bad "valid push failed: rc=$rc out=$out tip=$(tip $B)"
[[ "$out" == *" pushed $ID confirm_ts=$TS agent=rlp1-test $B "*"..$H8" ]] && ok "stdout line: pushed <d-id> confirm_ts agent branch old..new" || bad "pushed line wrong: $out"
[ "$(grep -c ' pushing ' "$RB_LAND_PUSH_LOG")" = 1 ] && [ "$(grep -c ' pushed ' "$RB_LAND_PUSH_LOG")" = 1 ] && [ "$(grep -n ' pushing ' "$RB_LAND_PUSH_LOG" | cut -d: -f1)" -lt "$(grep -n ' pushed ' "$RB_LAND_PUSH_LOG" | cut -d: -f1)" ] && ok "log has pushing then pushed" || bad "log wrong: $(cat "$RB_LAND_PUSH_LOG")"
# valid by the COMMIT sha too
clear; row "$ID" $TS controller verdict "CONFIRM commit $H8"; git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" >/dev/null 2>&1 && [ "$(tip $B)" = "$HEAD_SHA" ] && ok "valid row naming the commit sha -> pushed" || bad "commit-sha push failed"
# the db is opened read-only: sha256 of the db file is unchanged by a push run
s1=$(sha256sum "$WM_DECISIONS_DB" | cut -d' ' -f1); bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" >/dev/null 2>&1; s2=$(sha256sum "$WM_DECISIONS_DB" | cut -d' ' -f1)
[ "$s1" = "$s2" ] && ok "decisions db unchanged by a run" || bad "decisions db changed"
# no force anywhere in the push path
grep -nE -- '--force|--force-with-lease|push .*\+' "$wrap" | grep -vE '^[0-9]+:\s*#' | grep -q . && bad "wrapper source contains a force push" || ok "no --force / --force-with-lease / + refspec in the push path"
# selftest
st=$(bash "$wrap" --selftest 2>&1); src=$?; echo "$st" | tail -1
[ $src = 0 ] && echo "$st" | tail -1 | grep -Eq '^selftest ok ([0-9]+)/\1$' && ok "--selftest passes (selftest ok N/N)" || bad "--selftest failed (rc=$src): $(echo "$st" | tail -3)"
echo "rb-land-push: $n checks, fail=$fail"; exit $fail
