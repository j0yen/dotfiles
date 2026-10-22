#!/usr/bin/env bash
# tests/gh_merge_shim.test.sh -- the seat gh shim (.local/seat-bin/gh): pass-through, refusal, refusal rows, and PATH scope (C2).
# Plain bash, run from the repo root:  bash tests/gh_merge_shim.test.sh   (exits nonzero and prints every failure)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shim="$here/.local/seat-bin/gh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ghshim.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok - gh-shim: $1"; }
bad() { echo "NOT OK - gh-shim: $1"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi; }

mkdir -p "$tmp/real" "$tmp/state" "$tmp/home"
cat > "$tmp/real/gh" <<'S'
#!/usr/bin/env bash
# stub real gh: logs argv (one line) and stdin, exits $STUB_GH_RC (default 0)
printf '%s\n' "$*" >> "$STUB_LOG/gh.calls"
[ "${STUB_STDIN:-0}" = 1 ] && cat > "$STUB_LOG/gh.stdin"
exit "${STUB_GH_RC:-0}"
S
cat > "$tmp/real/wm-decide" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/wm-decide.calls"
exit "${STUB_WMD_RC:-0}"
S
chmod +x "$tmp/real/gh" "$tmp/real/wm-decide"
mkdir -p "$tmp/seat-bin"; ln -s "$shim" "$tmp/seat-bin/gh"   # install.sh symlinks it: the shim must find the real gh past its own symlink
export STUB_LOG="$tmp" HOME="$tmp/home" WM_DECIDE_STATE="$tmp/state" TMUX=
SEATPATH="$tmp/seat-bin:$tmp/real:/usr/bin:/bin"
run() { if [ "${STUB_STDIN:-0}" = 1 ]; then env PATH="$SEATPATH" "$@"; else env PATH="$SEATPATH" "$@" </dev/null; fi; }   # stdin closed unless a test pipes into it
calls() { cat "$tmp/gh.calls" 2>/dev/null | wc -l | tr -d ' '; }
reset() { rm -f "$tmp/gh.calls" "$tmp/gh.stdin" "$tmp/wm-decide.calls" "$tmp/state/merge-events.jsonl"; }
event() { printf '{"event": "gate-pass", "oid": "%s", "pr": %s, "repo": "%s", "ts": "2026-10-22T14:00:00-07:00", "verdict": "%s"}\n' "$4" "$2" "$3" "$1" >> "$tmp/state/merge-events.jsonl"; }
V=d-20261022-140000-rb-abcd
OID=a1b2c3d4e5f60123456789abcdef0123456789ab

# -- pass-through: everything but `pr merge` reaches the real gh untouched (args, stdin, exit code)
reset
run gh pr view 7 --repo j0yen/swarm-decide --json headRefOid >/dev/null; rc=$?
check "$rc:$(cat "$tmp/gh.calls")" "0:pr view 7 --repo j0yen/swarm-decide --json headRefOid" "pr view passes through with identical argv"
reset
echo '{"a":1}' | STUB_STDIN=1 STUB_GH_RC=5 run gh api graphql --input - >/dev/null; rc=$?
check "$rc:$(cat "$tmp/gh.calls"):$(cat "$tmp/gh.stdin")" '5:api graphql --input -:{"a":1}' "api graphql passes through with its stdin and the real exit code"
reset
run gh pr list --search merge --repo j0yen/mcphost >/dev/null; rc=$?
check "$rc:$(calls)" "0:1" "the word merge as a flag VALUE is not a merge"
reset
run gh api repos/j0yen/mcphost/pulls/9 >/dev/null; rc=$?
check "$rc:$(calls)" "0:1" "an api read of a pull passes through"

# -- refusal: pr merge without WM_DECIDE_GATE_OK, with --auto, with a wrong id, for another PR or repo
reset
run gh pr merge 7 --repo j0yen/swarm-decide --squash 2>"$tmp/err"; rc=$?
check "$rc:$(calls)" "2:0" "pr merge without WM_DECIDE_GATE_OK is refused (rc 2, real gh not called)"
grep -q "REFUSED" "$tmp/err" && ok "the refusal names rb-merge.sh" || bad "no refusal text"
reset; event $V 7 j0yen/swarm-decide $OID
WM_DECIDE_GATE_OK=$V run gh pr merge 7 --repo j0yen/swarm-decide --squash --match-head-commit $OID >/dev/null 2>&1; rc=$?
check "$rc:$(cat "$tmp/gh.calls")" "0:pr merge 7 --repo j0yen/swarm-decide --squash --match-head-commit $OID" "with a gate-pass event for that verdict + PR + repo the merge passes through verbatim"
reset; event $V 7 j0yen/swarm-decide $OID
WM_DECIDE_GATE_OK=$V run gh pr merge 7 --repo j0yen/swarm-decide --auto --squash >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "--auto is refused even with a gate-pass"
WM_DECIDE_GATE_OK=d-other run gh pr merge 7 --repo j0yen/swarm-decide --squash >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "WM_DECIDE_GATE_OK naming a verdict with no gate-pass is refused (the variable alone is not trusted)"
WM_DECIDE_GATE_OK=$V run gh pr merge 8 --repo j0yen/swarm-decide --squash >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "a gate-pass for PR 7 does not open PR 8"
WM_DECIDE_GATE_OK=$V run gh pr merge 7 --repo j0yen/mcphost --squash >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "a gate-pass for swarm-decide does not open mcphost #7"
reset
run gh api -X PUT repos/j0yen/mcphost/pulls/7/merge >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "the REST merge endpoint is refused"
run gh api graphql -f query='mutation { enablePullRequestAutoMerge(input:{pullRequestId:"x"}) { clientMutationId } }' >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "the auto-merge GraphQL mutation is refused"
run gh -R j0yen/mcphost pr merge 7 >/dev/null 2>&1; rc=$?
check "$rc:$(calls)" "2:0" "gh -R repo pr merge is refused"

# -- every refusal is a logged wm-decide row: kind gate, model deterministic, decision=<verdict id | none>
reset; PATH="$SEATPATH" WM_DECIDE_AGENT=rb gh pr merge 7 --repo j0yen/swarm-decide >/dev/null 2>&1
row="$(cat "$tmp/wm-decide.calls" 2>/dev/null)"
case "$row" in *"record --agent rb --kind gate --model deterministic"*decision=none*) ok "refusal row: agent rb, kind gate, model deterministic, decision=none" ;; *) bad "refusal row missing or wrong: $row" ;; esac
reset; event $V 7 j0yen/swarm-decide $OID
PATH="$SEATPATH" WM_DECIDE_AGENT=r7 WM_DECIDE_GATE_OK=d-bogus gh pr merge 7 --repo j0yen/swarm-decide >/dev/null 2>&1
case "$(cat "$tmp/wm-decide.calls")" in *"decision=d-bogus"*) ok "a wrong verdict id is logged as decision=<that id>" ;; *) bad "decision id not logged" ;; esac
reset
STUB_WMD_RC=2 run gh pr merge 7 --repo j0yen/swarm-decide >/dev/null 2>"$tmp/err"; rc=$?
check "$rc" "2" "a failed refusal-row write does not change the refusal"
reset
PATH="$SEATPATH" WM_DECIDE_AGENT=rb gh pr merge 7 --repo j0yen/swarm-decide "--body=sk-ant-oat01-FAKEFAKE" >/dev/null 2>&1
grep -q "sk-ant" "$tmp/wm-decide.calls" && bad "a token-shaped argument reached the ledger row" || ok "token-shaped arguments are redacted from the row"

# -- C2: the shim dir is on a seat PATH only. A wm-build.service-style PATH resolves gh to the real one.
UNIT_PATH="$tmp/home/.cargo/bin:$tmp/home/.local/bin:$tmp/real:/usr/bin:/bin"
got="$(env -i PATH="$UNIT_PATH" bash -c 'command -v gh')"
check "$got" "$tmp/real/gh" "a systemd-unit PATH (no seat-bin) resolves gh to the real binary"
got="$(env -i PATH="$SEATPATH" bash -c 'command -v gh')"
check "$got" "$tmp/seat-bin/gh" "a seat PATH (seat-bin first) resolves gh to the shim"
# the repo must not put gh anywhere a unit PATH or a login shell reads
if find "$here/.local/bin" "$here/.config/environment.d" -maxdepth 1 -name gh 2>/dev/null | grep -q .; then bad "a gh exists under .local/bin or environment.d"; else ok "no gh under .local/bin (wm-build.service PATH) or environment.d"; fi
if grep -rn "seat-bin" "$here/.config/environment.d" "$here/.profile" "$here/.bashrc" "$here/.zshenv" 2>/dev/null | grep -q .; then bad "seat-bin referenced by environment.d or a shell profile"; else ok "seat-bin is not referenced by environment.d or a profile"; fi
"$here/.local/bin/seat-gh-scope-check" --selftest >/dev/null && ok "seat-gh-scope-check --selftest" || bad "seat-gh-scope-check --selftest"

# -- install.sh links the shim to ~/.local/seat-bin/gh (and nothing to ~/.local/bin/gh)
d="$(HOME="$tmp/home2" bash -c 'mkdir -p "$HOME"; bash "'"$here"'/install.sh" --dry-run 2>&1' | grep -E 'would link: .*/gh ' || true)"
case "$d" in *".local/seat-bin/gh"*) ok "install.sh links ~/.local/seat-bin/gh" ;; *) bad "install.sh does not link seat-bin/gh: $d" ;; esac
case "$d" in *".local/bin/gh"*) bad "install.sh would link ~/.local/bin/gh" ;; *) ok "install.sh links no ~/.local/bin/gh" ;; esac

[ "$fail" = 0 ] && echo "ALL OK - gh-shim" || echo "FAILED - gh-shim"
exit "$fail"
