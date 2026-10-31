#!/usr/bin/env bash
# tests/rb-land-push.test.sh -- .local/bin/rb-land-push.sh: a land-branch push needs a LIVE controller CONFIRM row that names HEAD (commit or tree 8-hex, whole token);
# every refusal prints exactly one `REFUSED <reason>` line, exits 2, and leaves the origin ref unchanged; a valid row pushes (fast-forward only) and logs pushing -> pushed.
# Throwaway HOME + a temp sqlite built from the decisions schema (id/ts/agent/kind/what/regrade columns) + a bare origin and a clone. No network, never the live db.
# Remote mode (--host) runs over a FAKE ssh first on PATH (strips `-o BatchMode=yes <h>`, runs the rest as bash -c "$*" like a remote shell); the real ssh is never reached.
# Plain bash, run from the repo root:  bash tests/rb-land-push.test.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hermetic_sqlite3.sh"   # PATH sqlite3 that cannot create a db (ryzen7 ro wrapper) -> rw stand-in, else FAIL
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="${RB_LAND_PUSH_UNDER_TEST:-$here/.local/bin/rb-land-push.sh}"   # a mutation proof points this at a throwaway copy
T="$(mktemp -d "${TMPDIR:-/tmp}/rblp.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok - rb-land-push: $1"; }
bad() { n=$((n+1)); echo "NOT OK - rb-land-push: $1"; fail=1; }
export HOME="$T/home" WM_DECISIONS_DB="$T/d.sqlite" RB_LAND_PUSH_LOG="$T/home/.local/state/rb-seat/land-push.log" WM_SEAT=rb-test RB_LAND_PUSH_TEST_ORIGIN=1 RB_LAND_PUSH_REPO_PREFIXES="$T/"; unset CLAUDE_AGENT_ID
mkdir -p "$HOME"; g=(git -c user.name=t -c user.email=t@t)
# the schema line from `sqlite3 decisions.sqlite '.schema decisions'` (columns the wrapper reads)
sqlite3 "$WM_DECISIONS_DB" "create table decisions (id TEXT PRIMARY KEY, ts TEXT NOT NULL, agent TEXT NOT NULL, kind TEXT NOT NULL, what TEXT NOT NULL, regrade TEXT);"
git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/wt" 2>/dev/null
( cd "$T/wt" && echo a > f && "${g[@]}" add f && "${g[@]}" commit -qm a && git push -q origin HEAD:refs/heads/main && git push -q origin HEAD:refs/heads/wm-build/x && git checkout -q -b wm-build/x && echo b >> f && "${g[@]}" commit -qam b )
HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD); H8=${HEAD_SHA:0:8}; TREE=$(git -C "$T/wt" rev-parse 'HEAD^{tree}'); T8=${TREE:0:8}
mkdir -p "$T/bin"; : > "$T/ssh.log"; export FAKE_SSH_LOG="$T/ssh.log"
cat > "$T/bin/ssh" <<'EOS'
#!/usr/bin/env bash
[ -n "${FAKE_SSH_RC:-}" ] && exit "$FAKE_SSH_RC"
[ "${1:-}" = -o ] && [ "${2:-}" = BatchMode=yes ] && [ "${3:-}" = -o ] && [ "${4:-}" = StrictHostKeyChecking=yes ] && [ "${5:-}" = -- ] || exit 97
shift 6; printf 'call %s\n' "$(printf %s "$*" | tr '\n' ' ')" >> "$FAKE_SSH_LOG"
bash -c "$*"; rc=$?
[ -n "${FAKE_SSH_AFTER_PUSH:-}" ] && [[ "$*" == *"push -q origin"* ]] && eval "$FAKE_SSH_AFTER_PUSH"
exit $rc
EOS
chmod +x "$T/bin/ssh"; export PATH="$T/bin:$PATH"; [ "$(command -v ssh)" = "$T/bin/ssh" ] || { echo "abort: fake ssh not first on PATH"; exit 1; }
XA=(); REPO="$T/wt"
B=wm-build/x; ID=d-20261024-100000-controller-abcd; TS=2026-10-24T10:00:00-07:00
row() { sqlite3 "$WM_DECISIONS_DB" "insert into decisions values ('$1','$2','$3','$4','$5',${6:-NULL});"; }
clear() { sqlite3 "$WM_DECISIONS_DB" "delete from decisions;"; }
tip() { git -C "$T/origin.git" rev-parse "refs/heads/$1" 2>/dev/null || echo none; }
# refused <name> <reason> <id> [branch]: one REFUSED line, rc 2, origin ref unchanged
refused() {
  local name=$1 want=$2 id=$3 br=${4:-$B} b a out rc
  b=$(tip "$br"); out=$(bash "$wrap" --confirm "$id" --repo "$REPO" --branch "$br" ${XA[@]+"${XA[@]}"} 2>&1); rc=$?; a=$(tip "$br")
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
# the push is the captured sha, never HEAD (TOCTOU), never a bare branch name
pl=$(sed -n '/^run_push() {/,/^selftest() {/p' "$wrap" | grep -E 'push -q origin' | grep -vE '^\s*#')
[[ "$pl" == *'origin $head:refs/heads/'* ]] && [[ "$pl" != *HEAD:* ]] && [ "$(printf '%s\n' "$pl" | wc -l)" = 1 ] && ok "push refspec is <sha>:refs/heads/<branch>, not HEAD" || bad "push refspec is not the captured sha: $pl"
# --- branch binding: the repo must be ON --branch unless the row names it as a whole word
git -C "$T/wt" worktree add -q --detach "$T/wtd" HEAD
git -C "$T/origin.git" update-ref refs/heads/wm-build/y "$(git -C "$T/wt" rev-parse HEAD~1)"
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8";                                             refused "repo on wm-build/x, --branch wm-build/y, row does not name y" branch-mismatch "$ID" wm-build/y
REPO="$T/wtd";                                                                                          refused "detached HEAD, branch not named in the row" branch-mismatch "$ID"; REPO="$T/wt"
clear; row "$ID" $TS controller verdict "CONFIRM wm-build/y tree $T8"
out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch wm-build/y 2>&1); rc=$?
[ $rc = 0 ] && [ "$(tip wm-build/y)" = "$HEAD_SHA" ] && ok "a row naming the branch as a whole word overrides the binding -> pushed" || bad "named-branch push failed: rc=$rc out=$out"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
# --- remote mode (--host) over the fake ssh; db checks stay local, git runs through ssh
clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"; : > "$T/ssh.log"; : > "$RB_LAND_PUSH_LOG"
out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron 2>&1); rc=$?
[ $rc = 0 ] && [ "$(tip $B)" = "$HEAD_SHA" ] && ok "remote: happy push through the fake ssh reaches the bare origin" || bad "remote push failed: rc=$rc out=$out"
grep -q " verified $ID sha=$H8 host=redbaron\$" "$RB_LAND_PUSH_LOG" && ok "remote: post-push ls-remote from the caller verified the pinned sha (log: verified sha=<8>)" || bad "no verified line: $(cat "$RB_LAND_PUSH_LOG")"
grep -c 'push -q origin' "$T/ssh.log" | grep -qx 1 && grep 'push -q origin' "$T/ssh.log" | grep -q 'git -c core.hooksPath=/dev/null -C ' && ok "remote: the push call runs git -c core.hooksPath=/dev/null" || bad "push call lacks the hook-disabling -c: $(cat "$T/ssh.log")"
[ "$(wc -l < "$T/ssh.log")" = 2 ] && ok "remote: exactly two ssh round trips (checks, push)" || bad "remote: ssh calls = $(wc -l < "$T/ssh.log")"
[[ "$out" == *" pushed $ID confirm_ts=$TS agent=rb-test $B "*"..$H8 host=redbaron" ]] && grep -q ' pushing .* host=redbaron$' "$RB_LAND_PUSH_LOG" && ok "remote: log lines carry host=redbaron" || bad "remote log line wrong: $out"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
XA=(--host 'x;y');                                                                                      refused "remote: --host 'x;y'" bad-host "$ID"
XA=(--host '');                                                                                         refused "remote: --host '' (empty)" bad-host "$ID"
XA=(--host evil);                                                                                       refused "remote: a host outside RB_LAND_PUSH_HOSTS" host-not-allowed "$ID"
out=$(RB_LAND_PUSH_HOSTS="evil redbaron" bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host evil 2>&1); rc=$?
[[ "$out" != "REFUSED host-not-allowed"* ]] && ok "remote: RB_LAND_PUSH_HOSTS extends the allowlist" || bad "allowlist env ignored: $out"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
XA=(--host redbaron); REPO="$T/w t";                                                                    refused "remote: repo path with a space" bad-repo "$ID"
REPO="$T/w;t";                                                                                          refused "remote: repo path with a ;" bad-repo "$ID"
REPO='relative/path';                                                                                   refused "remote: relative repo path" bad-repo "$ID"
REPO="$T/wt"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/other" rev-parse HEAD)";                 refused "remote: non-fast-forward over the fake ssh" non-ff "$ID"
git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"
lb=$(git ls-remote "$T/origin.git"); out=$(FAKE_SSH_RC=255 bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron 2>&1); rc=$?; la=$(git ls-remote "$T/origin.git")
[ $rc = 2 ] && [[ "$out" == "REFUSED ssh-failed rc=255"* ]] && [ "$lb" = "$la" ] && ok "remote: ssh rc 255 -> REFUSED ssh-failed rc=255; git ls-remote on the origin identical before/after" || bad "ssh-failed: rc=$rc out=$out"
XA=(--host redbaron); REPO="$T/wtd";                                                                    refused "remote: detached HEAD not named -> branch-mismatch" branch-mismatch "$ID"; REPO="$T/wt"
# --- --check: runs checks 0-4 + ls-remote, prints CHECK-OK, never pushes, never logs
: > "$RB_LAND_PUSH_LOG"; lb=$(git ls-remote "$T/origin.git")
out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron --check 2>&1); rc=$?; la=$(git ls-remote "$T/origin.git")
[ $rc = 0 ] && [ "$out" = "CHECK-OK sha=$H8 host=redbaron" ] && [ "$lb" = "$la" ] && [ ! -s "$RB_LAND_PUSH_LOG" ] && ok "--check --host: CHECK-OK sha=<8> host=redbaron, origin unchanged, nothing logged" || bad "--check: rc=$rc out=$out"
out=$(bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --check 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "CHECK-OK sha=$H8 host=local" ] && ok "--check without --host (local): CHECK-OK ... host=local" || bad "local --check: rc=$rc out=$out"
XA=(--host redbaron --check);                                                                           refused "--check still refuses (branch-mismatch)" branch-mismatch "$ID" wm-build/y
XA=(); clear
# --- rlp1c v0.4: hardening, origin + path allowlists, post-push proof, --check never pushes
reset_tip() { git -C "$T/origin.git" update-ref refs/heads/$B "$(git -C "$T/wt" rev-parse HEAD~1)"; }
reset_tip; clear; row "$ID" $TS controller verdict "CONFIRM tree $T8"; XA=(--host redbaron)
# (g) --check makes zero push calls (argv log of the fake ssh)
: > "$T/ssh.log"; bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron --check >/dev/null 2>&1
[ "$(wc -l < "$T/ssh.log")" = 1 ] && ! grep -q ' push ' "$T/ssh.log" && ok "(g) --check: one ssh call, zero push calls in the fake-ssh argv log" || bad "(g) --check pushed or made extra calls: $(cat "$T/ssh.log")"
# (h) origin allowlist: a non-github, a github-but-not-j0yen, and (without RB_LAND_PUSH_TEST_ORIGIN) a local push url are all refused; the fetch never runs against them
git clone -q "$T/origin.git" "$T/wto" 2>/dev/null; REPO="$T/wto"
git -C "$T/wto" remote set-url origin https://evil.example/j0yen/x.git;                                refused "(h) origin https://evil.example/j0yen/x.git" origin-not-allowed "$ID"
git -C "$T/wto" remote set-url origin https://github.com/other/x.git;                                  refused "(h) origin github.com/other/x.git (not j0yen)" origin-not-allowed "$ID"
git -C "$T/wto" remote set-url origin "$T/origin.git"; git -C "$T/wto" remote set-url --push origin https://evil.example/j0yen/x.git
refused "(h) a hostile pushurl is the one checked (git remote get-url --push)" origin-not-allowed "$ID"; REPO="$T/wt"
out=$(env -u RB_LAND_PUSH_TEST_ORIGIN bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" 2>&1); rc=$?
[ $rc = 2 ] && [[ "$out" == "REFUSED origin-not-allowed"* ]] && ok "(h) a local-path push url is refused without RB_LAND_PUSH_TEST_ORIGIN=1" || bad "local origin not refused: rc=$rc out=$out"
# (i) repo prefix allowlist (--host mode only)
REPO=/usr/local/src/x;                                                                                  refused "(i) --host repo outside RB_LAND_PUSH_REPO_PREFIXES" repo-not-allowed "$ID"
REPO="$T/../x";                                                                                         refused "(i) a .. component is refused" repo-not-allowed "$ID"
# host-independent: $T lives under TMPDIR, which is /mnt/data/tmp/... on RedBaron and so sits INSIDE the default /mnt/data/ prefix; a repo outside it is refused on every host
out=$(env -u RB_LAND_PUSH_REPO_PREFIXES bash "$wrap" --confirm "$ID" --repo /usr/local/src/x --branch "$B" --host redbaron 2>&1)
[[ "$out" == "REFUSED repo-not-allowed"* ]] && ok "(i) the default prefix is /mnt/data/" || bad "default prefix not enforced: $out"
REPO="$T/wt"
# repo config holding include.* keys is refused (git cannot unset a repo's own includes with -c)
git -C "$T/wt" config include.path /dev/null;                                                           refused "repo config with include.path" repo-config-include "$ID"; git -C "$T/wt" config --unset include.path
# (j) post-push mismatch: the origin ref is moved after the push -> exit 3 + push-verify-mismatch, no verified line
reset_tip; : > "$RB_LAND_PUSH_LOG"
out=$(FAKE_SSH_AFTER_PUSH="git -C $T/origin.git update-ref refs/heads/$B $(git -C "$T/wt" rev-parse HEAD~1)" bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron 2>&1); rc=$?
[ $rc = 3 ] && [[ "$out" == *" push-verify-mismatch $ID sha=$H8 got="* ]] && grep -q ' push-verify-mismatch ' "$RB_LAND_PUSH_LOG" && ! grep -q ' verified ' "$RB_LAND_PUSH_LOG" && ok "(j) moved origin ref after the push -> exit 3, push-verify-mismatch logged, not verified" || bad "(j) rc=$rc out=$out log=$(cat "$RB_LAND_PUSH_LOG")"
# (k) a core.hooksPath pre-push hook must NOT run (control: a plain git push does run it)
mkdir -p "$T/hooks"; printf '#!/bin/sh\ntouch "%s/marker"\nexit 0\n' "$T" > "$T/hooks/pre-push"; chmod +x "$T/hooks/pre-push"; git -C "$T/wt" config core.hooksPath "$T/hooks"
git -C "$T/wt" push -q origin HEAD~1:refs/heads/hookctl >/dev/null 2>&1; [ -e "$T/marker" ] && ok "(k) control: the planted pre-push hook fires on a plain git push" || bad "(k) control: hook did not fire; test is vacuous"
rm -f "$T/marker"; reset_tip
bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" --host redbaron >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(tip $B)" = "$HEAD_SHA" ] && [ ! -e "$T/marker" ] && ok "(k) remote push: planted pre-push hook did NOT run (marker absent), push landed" || bad "(k) remote: rc=$rc marker=$([ -e "$T/marker" ] && echo present || echo absent)"
reset_tip; XA=(); bash "$wrap" --confirm "$ID" --repo "$T/wt" --branch "$B" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$T/marker" ] && ok "(k) local push: planted pre-push hook did NOT run (marker absent)" || bad "(k) local: rc=$rc"
git -C "$T/wt" config --unset core.hooksPath; reset_tip; clear
# no force anywhere in the push path
grep -nE -- '--force|--force-with-lease|push .*\+' "$wrap" | grep -vE '^[0-9]+:\s*#' | grep -q . && bad "wrapper source contains a force push" || ok "no --force / --force-with-lease / + refspec in the push path"
# selftest
st=$(bash "$wrap" --selftest 2>&1); src=$?; echo "$st" | tail -1
[ $src = 0 ] && echo "$st" | tail -1 | grep -Eq '^selftest ok ([0-9]+)/\1$' && ok "--selftest passes (selftest ok N/N)" || bad "--selftest failed (rc=$src): $(echo "$st" | tail -3)"
echo "rb-land-push: $n checks, fail=$fail"; exit $fail
