#!/usr/bin/env bash
# tests/fd-merge.test.sh -- .local/bin/fd-merge.sh: a fleet-dash branch lands on the remote main only on a separate-session via=verifier CONFIRM row
# whose COMMIT equals the gated row's COMMIT and the remote branch head. Temp bare repo as the remote, temp clone as the repo, stub wm-decide; nothing real is touched.
# Plain bash, run from the repo root:  bash tests/fd-merge.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fd="$here/.local/bin/fd-merge.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fdmerge.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok - fd-merge: $1"; }
bad() { echo "NOT OK - fd-merge: $1"; fail=1; }
check() { if [ -e "$tmp/tripwire" ]; then bad "$3: a real gh/wm-decide on PATH was called (tripwire)"; elif [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

# tripwire shims for the REAL gh / wm-decide; the stub under test is reached only through WM_DECIDE_BIN. HOME is a scratch dir so ~/wintermute/fleet-dash can never resolve to the real repo.
mkdir -p "$tmp/trip" "$tmp/home"
for b in gh wm-decide; do printf '#!/bin/sh\ntouch "%s/tripwire"\nexit 99\n' "$tmp" > "$tmp/trip/$b"; chmod +x "$tmp/trip/$b"; done
export PATH="$tmp/trip:$PATH" HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cat > "$tmp/wm-decide" <<'S'
#!/usr/bin/env bash
printf 'wmd %s\n' "$*" >> "$STUB_LOG/calls"
case "$1" in
  list) [ "${STUB_LIST_RC:-0}" = 0 ] || exit "$STUB_LIST_RC"; cat "$STUB_LOG/rows.json" ;;
  record) exit "${STUB_RECORD_RC:-0}" ;;
esac
exit 0
S
chmod +x "$tmp/wm-decide"
export STUB_LOG="$tmp" WM_DECIDE_BIN="$tmp/wm-decide" FD_MERGE_REMOTE=orch

g() { git -C "$W/repo" "$@"; }
# the seed clone publishes with a plain refspec to the bare remote (fixture setup only)
seedsend() { git -C "$W/seed" "$@"; }
# world: bare remote with main (M0), feat (C = M0 + 1), feat-old (X, a sibling of C off M0); repo = clone on main at M0
newworld() {
  W="$tmp/w$((++n))"; mkdir -p "$W"
  git init -q --bare -b main "$W/remote.git"
  git init -q -b main "$W/seed"
  echo base > "$W/seed/f"; seedsend add f; seedsend commit -q -m base
  M0="$(seedsend rev-parse HEAD)"
  seedsend checkout -q -b feat; echo feat > "$W/seed/f"; seedsend commit -qam feat; C="$(seedsend rev-parse HEAD)"
  seedsend checkout -q main; seedsend checkout -q -b feat-old; echo old > "$W/seed/g"; seedsend add g; seedsend commit -q -m old; X="$(seedsend rev-parse HEAD)"
  seedsend remote add origin "$W/remote.git"
  seedsend push -q origin main feat feat-old 2>/dev/null
  git clone -q -o orch "$W/remote.git" "$W/repo" 2>/dev/null
  export FD_MERGE_REPO="$W/repo"; : > "$tmp/calls"; rm -f "$tmp/err"
}
# rows: V = verdict d-v gating d-g; per-case overrides through VWHAT (whole verdict text) VIA VWORD VTOK GTOK GPFX VSESS GSESS KINDV KINDG DUP
mkrows() {
  VTOK_X="${VTOK-COMMIT=$C}" GTOK_X="${GTOK-COMMIT=$C}" python3 -I - "$tmp/rows.json" <<'P'
import json, os, sys
e = os.environ.get
v = {"id": "d-v", "kind": e("KINDV", "verdict"), "agent": "r7", "via": e("VIA", "verifier"), "session": e("VSESS", "sess-v"), "gates": "d-g",
     "what": e("VWHAT") or "%s fleet-dash feat %s agent=verifier:r7 ran ok" % (e("VWORD", "CONFIRM"), e("VTOK_X"))}
g = {"id": "d-g", "kind": e("KINDG", "other"), "agent": "r7", "via": "r7", "session": e("GSESS", "sess-g"), "gates": None,
     "what": "%s feat %s agent=rb" % (e("GPFX", "GATED fleet-dash"), e("GTOK_X"))}
rows = [v, g]
if e("DUP"):
    rows.append(dict(v))
json.dump(rows, open(sys.argv[1], "w"))
P
}
runcase() { mkrows; bash "$fd" d-v feat >"$tmp/out" 2>"$tmp/err"; rc=$?; }
rmain() { git -C "$W/remote.git" rev-parse main; }
refused() { # name ; rc 3, remote main unchanged, local HEAD unchanged, no record call, one-line reason
  local before_r before_l
  before_r="$(rmain)"; before_l="$(g rev-parse HEAD)"
  runcase
  check "$rc" 3 "$1: exit 3"
  check "$(rmain)" "$before_r" "$1: remote main unchanged"
  check "$(g rev-parse HEAD)" "$before_l" "$1: local HEAD unchanged"
  check "$(grep -c '^wmd record' "$tmp/calls")" 0 "$1: no record call"
  grep -q '^FD-MERGE REFUSED: ' "$tmp/err" && ok "$1: one-line FD-MERGE REFUSED reason" || bad "$1: reason missing: $(cat "$tmp/err")"
}
n=0

newworld; runcase
check "$rc" 0 "valid: exit 0"
check "$(rmain)" "$C" "valid: remote main == COMMIT"
check "$(g rev-parse HEAD)" "$C" "valid: local main == COMMIT"
check "$(grep -c '^wmd record' "$tmp/calls")" 1 "valid: exactly one record call"
grep '^wmd record' "$tmp/calls" | grep -qF -- "--what MERGED fleet-dash feat COMMIT=$C verdict=d-v" && ok "valid: record carries the MERGED line" || bad "record line wrong: $(cat "$tmp/calls")"
grep -qx "FD-MERGED feat $C verdict=d-v" "$tmp/out" && ok "valid: FD-MERGED line printed" || bad "FD-MERGED missing: $(cat "$tmp/out")"

newworld; VIA=r7 refused "via=r7 (the d24b shape)"
newworld; VIA= refused "via empty"
newworld; VWORD=REFUSE refused "verdict word not CONFIRM"
newworld; VTOK="COMMIT=${C:0:12}" refused "short COMMIT"
newworld; VTOK="COMMIT=${C}a" refused "41-hex COMMIT token"
newworld; VTOK="COMMIT=$C COMMIT=$X" refused "two COMMIT tokens"
newworld; GTOK="COMMIT=$X" refused "gated COMMIT differs"
newworld; GPFX="GATED mcphost" refused "gated row not GATED fleet-dash"
newworld; KINDG=verdict refused "gated row kind not other"
newworld; KINDV=other refused "verdict row kind not verdict"
newworld; VSESS=same GSESS=same refused "same session"
newworld; VSESS= refused "empty session"
newworld; DUP=1 refused "duplicate row id"
newworld; STUB_LIST_RC=1 refused "list stub rc!=0"

# remote feat head moves off COMMIT (fixture setup only); X is a fast-forward of main, so without the head check the merge would succeed
newworld; git -C "$W/remote.git" update-ref refs/heads/feat "$X"
refused "remote branch head != COMMIT"
newworld; echo dirty >> "$W/repo/f"; refused "dirty worktree"
newworld; g checkout -q -b other; refused "repo not on main"

# remote main moved past local HEAD: refuses, local main never advanced
newworld; git -C "$W/remote.git" update-ref refs/heads/main "$X"; refused "remote main moved ahead of local HEAD"
# not ff-able: local main (== remote main, a sibling of COMMIT) is not an ancestor of COMMIT
newworld; git -C "$W/remote.git" update-ref refs/heads/main "$X"; g fetch -q orch; g merge -q --ff-only "$X"
refused "not fast-forwardable"

# step failures: exit 4
newworld; printf '#!/bin/sh\nexit 1\n' > "$W/remote.git/hooks/pre-receive"; chmod +x "$W/remote.git/hooks/pre-receive"
runcase; check "$rc" 4 "transfer rejected: exit 4"
check "$(grep -c '^wmd record' "$tmp/calls")" 0 "transfer rejected: no record call"
check "$(rmain)" "$M0" "transfer rejected: remote main unchanged"
grep -q 'step push' "$tmp/err" && ok "transfer rejected: names the step" || bad "step not named: $(cat "$tmp/err")"
newworld; STUB_RECORD_RC=1 runcase; check "$rc" 4 "record fails after a good transfer: exit 4"
check "$(rmain)" "$C" "record fails: remote main == COMMIT"
grep -qx "MERGED fleet-dash feat COMMIT=$C verdict=d-v" "$tmp/err" && ok "record fails: the MERGED line is on stderr" || bad "MERGED line missing: $(cat "$tmp/err")"
grep -q 'step record' "$tmp/err" && ok "record fails: names the step" || bad "step not named"

# real-row shapes (ctl b854 10-30): trailing comma after COMMIT, gated row kind gate
newworld; VWHAT="CONFIRM MERGE-OK fleet-dash 14c60b4 COMMIT=$C, gating the GATED row" KINDG=gate runcase
check "$rc" 0 "comma-trailed COMMIT + gated kind gate: exit 0"
check "$(rmain)" "$C" "comma-trailed COMMIT + gated kind gate: remote main == COMMIT"
check "$(grep -c '^wmd record' "$tmp/calls")" 1 "comma-trailed COMMIT + gated kind gate: exactly one record call"
newworld; VWHAT="CONFIRM MERGE-OK fleet-dash 14c60b4 COMMIT=${C:0:39}, gating the GATED row" KINDG=gate refused "comma after a 39-hex COMMIT"
newworld; KINDG=verdict refused "gated row kind verdict (kind gate allowed)"
newworld; KINDG=note refused "gated row kind note"
newworld; VWHAT="CONFIRM MERGE-OK fleet-dash COMMIT=${C}G, gating" KINDG=gate refused "COMMIT then G then comma"
newworld; VWHAT="CONFIRM MERGE-OK fleet-dash COMMIT=${C}-x gating" KINDG=gate refused "COMMIT then -x"
newworld; VWHAT="CONFIRM MERGE-OK fleet-dash COMMIT=$C, gating" KINDG=gate VSESS=same GSESS=same refused "kind gate with the same session"

# structure
grep -q '^set -uo pipefail' "$fd" && ok "strict mode" || bad "strict mode missing"
if grep -v '^[[:space:]]*#' "$fd" | grep -E 'push.*(--force|-f |\+HEAD|--delete|--mirror)'; then bad "force flag in the transfer"; else ok "no force flag in the transfer"; fi
[ ! -e "$tmp/tripwire" ] && ok "tripwire untouched" || bad "tripwire touched: a real gh or wm-decide ran"
[ "$fail" = 0 ] && echo "ALL OK - fd-merge" || echo "FAILED - fd-merge"
exit "$fail"
