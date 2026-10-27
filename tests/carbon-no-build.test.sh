#!/usr/bin/env bash
# tests/carbon-no-build.test.sh: carbon refuses builds, test suites and coding (Joe 10-27 "Nothing should be built nor coded on carbon", approvals #47).
# Covers .claude/hooks/carbon-no-build.{sh,py} (Bash / Edit-family / Agent rules, hostname gate, symlink resolve), the aide-verifier.sh launch refusal,
# the hand-pr-land-driver carbon case (run through tests/hand-pr-land-driver.test.sh), the carbon-build-procs.py sampler and the settings wiring.
# Hermetic: own mktemp HOME + XDG dirs; `hostname -s` is stubbed by a PATH dir only (never an env override). Run: bash tests/carbon-no-build.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
HOOK="$root/.claude/hooks/carbon-no-build.sh"
fail=0; npass=0
pass() { echo "PASS: $1"; npass=$((npass + 1)); }
bad() { echo "FAIL: $1"; fail=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/xdg/config" XDG_STATE_HOME="$T/xdg/state" XDG_CACHE_HOME="$T/xdg/cache" XDG_DATA_HOME="$T/xdg/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
for h in carbon redbaron; do mkdir -p "$T/host-$h"; printf '#!/bin/sh\necho %s\n' "$h" >"$T/host-$h/hostname"; chmod +x "$T/host-$h/hostname"; done
BASEPATH=$PATH

# sandbox tree: a dotfiles git tree, ~/.claude scripts + CLAUDE.md symlinked into it, a worktree, a memory dir, a vault, a scratchpad
mkdir -p "$HOME/dotfiles/.git" "$HOME/dotfiles/.claude/scripts" "$HOME/.claude/projects/p/memory" "$HOME/Notes/wiki" "$HOME/.claude/state" \
         "$HOME/.cache/tmp/claude-1/s" "$HOME/.config/systemd/user/x.service.d" "$HOME/wt/foo/tests" "$HOME/plain"
: >"$HOME/dotfiles/.claude/CLAUDE.md"; : >"$HOME/dotfiles/.claude/scripts/x.sh"
ln -s "$HOME/dotfiles/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
ln -s "$HOME/dotfiles/.claude/scripts" "$HOME/.claude/scripts"
echo "gitdir: $HOME/dotfiles/.git/worktrees/foo" >"$HOME/wt/foo/.git"

jstr() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
run_hook() {   # run_hook <host> <json> -> rc in $RC, stderr in $ERR
  ERR=$(PATH="$T/host-$1:$BASEPATH" bash "$HOOK" <<<"$2" 2>&1 >/dev/null); RC=$?
}
bashj() { printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' "$(jstr "$1")" "$HOME"; }
editj() { printf '{"tool_name":"%s","tool_input":{"file_path":%s},"cwd":"%s"}' "$1" "$(jstr "$2")" "$HOME"; }
agentj() { printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"x"},"cwd":"%s"}' "$1" "$HOME"; }
MSG_RE='^carbon-no-build: [a-z-]+ denied on carbon; run on redbaron/ryzen7 over ssh \(CLAUDE\.md § Hosts\)$'

deny_case() {   # deny_case <label> <json>: denies on carbon (rc 2, one stderr line of the fixed shape), passes on redbaron
  run_hook carbon "$2"; local rc=$RC err=$ERR
  run_hook redbaron "$2"
  if [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [[ "$err" =~ $MSG_RE ]] && [ "$RC" = 0 ] && [ -z "$ERR" ]; then pass "deny: $1"
  else bad "deny: $1 (carbon rc=$rc err='$err'; redbaron rc=$RC err='$ERR')"; fi
}
allow_case() {   # allow_case <label> <json>: allowed on both hosts
  run_hook carbon "$2"; local rc=$RC err=$ERR
  run_hook redbaron "$2"
  if [ "$rc" = 0 ] && [ -z "$err" ] && [ "$RC" = 0 ]; then pass "allow: $1"; else bad "allow: $1 (carbon rc=$rc err='$err'; redbaron rc=$RC)"; fi
}
dB() { deny_case "$1" "$(bashj "$1")"; }
aB() { allow_case "$1" "$(bashj "$1")"; }

# ---- 1. Bash denies (command position)
dB 'pytest tests/ -x'
dB 'uv run pytest -q'
dB 'uv run --frozen python -m pytest'
dB 'python3 -m pytest tests'
dB '/home/x/.venv/bin/pytest'
dB 'wm-verify-run bash tests/x.test.sh'
dB 'bash tests/foo.test.sh'
dB 'for f in tests/*.test.sh; do bash "$f"; done'
dB 'tests/run.sh'
dB './tests/foo.test.sh'
dB 'make test'
dB 'FOO=1 make -j4'
dB 'go build ./...'
dB 'go test ./...'
dB 'npm test'
dB 'pnpm run build'
dB 'yarn build'
dB 'npx tsc --noEmit'
dB 'tsc -p .'
dB 'cargo build --release'
dB 'cd /x && cargo test'
dB 'rustc foo.rs'
dB 'aide-verifier.sh launch v1 --repo o/r --suite "x"'
dB 'systemd-run --user --unit u -p MemoryMax=2G cargo test'
dB 'systemd-run --user --unit=u bash tests/foo.test.sh'
# ---- Bash gaps (binding amendment 3): one test per case
dB 'git worktree add ../wt2 main'
dB 'cat tests/a.test.sh | bash tests/b.test.sh'
dB 'timeout 60 pytest'
dB 'nice -n 10 make'
dB 'nohup pytest &'
dB 'env FOO=1 pytest'
dB 'setsid cargo build'
dB 'bash -c "pytest -x"'
dB "sh -c 'cd /x && make'"
dB 'bash -lc "cargo test"'
dB "tmux send-keys -t x 'pytest -x' Enter"
dB 'tmux new-session -d -s s "cargo build"'
dB 'tmux new-window "make test"'
dB 'echo hi; for f in tests/*.test.sh; do echo $f; done'
# claude -p / --print = a headless coder turn (rb-run-coder.sh now launches it on redbaron)
dB 'claude -p x'
dB 'claude --print x'
dB 'systemd-run --user /bin/bash -c "claude -p < f"'
dB 'timeout 600 nohup claude --dangerously-skip-permissions -p < f'

# ---- 2. Bash allowed
aB "ssh redbaron 'cargo test'"
aB 'ssh redbaron cargo test'
SA=seat-; aB "${SA}ask.sh rb \"run pytest\""   # built from parts: the command is only classified by the hook, never run (tests/no-real-seat-in-tests.test.sh)
aB $'cat <<EOF\nrun pytest and cargo test and tests/x.test.sh\nEOF'
aB $'python3 - <<\'PYE\'\nprint("pytest")\nPYE'
aB 'git pull --ff-only'
aB 'git fetch origin && git status'
aB 'git worktree remove /tmp/wt'
aB 'git worktree list'
aB 'gh pr view 5 --repo j0yen/dotfiles'
aB 'rb-merge.sh d-1 5 j0yen/dotfiles'
aB 'wm-decide list --json'
aB 'systemctl --user status foo.timer'
aB 'jq . /tmp/x.json | grep -c pytest'
aB 'cat tests/foo.test.sh'
aB 'grep -n x tests/*.test.sh'
aB 'tail -n 20 /tmp/pytest.log'
aB 'echo "cargo test"'
aB 'cargo --version'
aB 'tmux send-keys -t rb "hello there" Enter'
aB 'bash -c "echo pytest"'
aB 'ls ~/.cargo/bin'
aB "ssh redbaron 'claude -p x'"
aB 'rb-run-coder.sh n f'
aB 'claude --version'
aB 'echo claude -p x'

# ---- 3. Edit / Write / MultiEdit / NotebookEdit
allow_case "Edit of a memory file" "$(editj Edit "$HOME/.claude/projects/p/memory/m.md")"
allow_case "Edit of ~/.claude/CLAUDE.md (a symlink into the dotfiles git tree; allowlist matches the path as given)" "$(editj Edit "$HOME/.claude/CLAUDE.md")"
allow_case "Write of a vault page" "$(editj Write "$HOME/Notes/wiki/p.md")"
allow_case "Write of ~/.claude/state" "$(editj Write "$HOME/.claude/state/x.json")"
allow_case "Write of a scratchpad file" "$(editj Write "$HOME/.cache/tmp/claude-1/s/note.txt")"
allow_case "Write of a systemd drop-in" "$(editj Write "$HOME/.config/systemd/user/x.service.d/10.conf")"
allow_case "Write under ~/.config (as given)" "$(editj Write "$HOME/.config/foo/bar.json")"
allow_case "Write of a file outside every git tree" "$(editj Write "$HOME/plain/x.txt")"
allow_case "tilde-relative path to CLAUDE.md" "$(editj Edit "~/.claude/CLAUDE.md")"
deny_case "Edit of ~/.claude/scripts/x.sh (symlinks into a git tree)" "$(editj Edit "$HOME/.claude/scripts/x.sh")"
deny_case "Edit of a file in the dotfiles tree" "$(editj Edit "$HOME/dotfiles/.claude/scripts/x.sh")"
deny_case "Write of a new file in the dotfiles tree" "$(editj Write "$HOME/dotfiles/new.sh")"
deny_case "Edit in a worktree tests/x.test.sh" "$(editj Edit "$HOME/wt/foo/tests/x.test.sh")"
deny_case "MultiEdit in a worktree" "$(editj MultiEdit "$HOME/wt/foo/tests/x.test.sh")"
deny_case "NotebookEdit in a git tree" "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":%s},"cwd":"%s"}' "$(jstr "$HOME/dotfiles/n.ipynb")" "$HOME")"
deny_case "relative path resolved against cwd into a git tree" "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"tests/y.test.sh"},"cwd":"%s"}' "$HOME/wt/foo")"

# ---- 4. Agent
deny_case "Agent coder" "$(agentj coder)"
deny_case "Agent coder-opus" "$(agentj coder-opus)"
allow_case "Agent scout" "$(agentj scout)"
allow_case "Agent verifier" "$(agentj verifier)"
# no escape hatch: files an agent could create do not open the gate
touch "$HOME/.claude/.allow-cargo-carbon" "$HOME/.claude/.allow-carbon-build" "$HOME/.claude/.allow-fable-bash"
run_hook carbon "$(bashj 'pytest')"; [ "$RC" = 2 ] && pass "no escape-hatch file opens the gate" || bad "an escape-hatch file opened the gate"
rm -f "$HOME/.claude/.allow-cargo-carbon" "$HOME/.claude/.allow-carbon-build" "$HOME/.claude/.allow-fable-bash"
# fail open on garbage input
run_hook carbon 'not json'; [ "$RC" = 0 ] && pass "garbage input fails open" || bad "garbage input did not fail open"

# ---- 5. aide-verifier.sh launch on carbon
AV="$root/.local/bin/aide-verifier.sh"
H40=$(printf 'a%.0s' $(seq 40))
out=$(PATH="$T/host-carbon:$BASEPATH" AIDE_VERIFIER_DIR="$T/av" bash "$AV" launch cnb1 --repo j0yen/dotfiles --pr 7 --head "$H40" --gated d-20261027-110840-aide-a2fe --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh' 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$out" = "aide-verifier: carbon runs no suites (CLAUDE.md CARBON): ask r7 (seat-ask.sh r7)" ] && [ ! -e "$T/av" ] && pass "aide-verifier launch --suite on carbon: exit 3 with the refusal line, before any clone or state" || bad "aide-verifier launch on carbon (rc=$rc out='$out')"
out=$(PATH="$T/host-carbon:$BASEPATH" AIDE_VERIFIER_DIR="$T/av" bash "$AV" finish nosuch 2>&1); rc=$?
[[ "$out" != *"carbon runs no suites"* ]] && pass "aide-verifier finish (no-suite path) is not refused on carbon (rc=$rc)" || bad "aide-verifier finish was refused on carbon"

# ---- 6. hand-pr-land-driver on carbon (cases live in the driver test, which owns the stub harness)
dout=$(bash "$root/tests/hand-pr-land-driver.test.sh" 2>&1); drc=$?
if [ "$drc" = 0 ] && [ "$(grep -c '^PASS: (carbon)' <<<"$dout")" = 2 ] && ! grep -q '^FAIL' <<<"$dout"; then pass "hand-pr-land-driver on carbon: GATED suite row launches nothing, rings r7 once per head (2 carbon cases in tests/hand-pr-land-driver.test.sh)"
else bad "hand-pr-land-driver carbon cases (rc=$drc)"; fi

# ---- 7. carbon-build-procs.py sampler
CBP="$root/.local/bin/carbon-build-procs.py"
cat >"$T/ps1.txt" <<'E'
    1 systemd         /sbin/init
  100 ssh             ssh redbaron cd /x && cargo test
  101 tmux: server    tmux new-session -d cargo build
  102 grep            grep -r pytest /x
  103 claude          claude --resume abc
  104 bash            bash /home/jsy/some.sh
E
export CBP_OUT="$T/cbp.json" CBP_HOST=carbon
python3 -I "$CBP" --ps-file "$T/ps1.txt" --json >"$T/o1" && [ "$(jq -r '.carbon.build_procs.count' "$T/o1")" = 0 ] && [ "$(jq -r '.alarms | length' "$T/o1")" = 0 ] && pass "sampler: an ssh line to redbaron that runs a cargo test, live on carbon, counts 0" || bad "sampler counted an ssh line"
cat >"$T/ps2.txt" <<'E'
  200 cargo           cargo build --release
  204 make            make test TOKEN=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH
  201 bash            bash tests/foo.test.sh
  202 python3         python3 -m pytest tests
  203 bash            bash -c something-else
  205 ssh             ssh redbaron cargo build
E
rm -f "$CBP_OUT"
python3 -I "$CBP" --ps-file "$T/ps2.txt" --json >"$T/o2"
[ "$(jq -r '.carbon.build_procs.count' "$T/o2")" = 4 ] && [ "$(jq -r '.carbon.build_procs.first3 | length' "$T/o2")" = 3 ] && [ "$(jq -r '.alarms | length' "$T/o2")" = 0 ] && ! grep -q 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH' "$T/o2" && grep -q '<redacted>' "$T/o2" && pass "sampler: 4 build procs counted, first 3 kept and redacted, no alarm on the first sample" || bad "sampler first sample"
python3 -I "$CBP" --ps-file "$T/ps2.txt" --json >"$T/o3"
[ "$(jq -r '.alarms[0]' "$T/o3")" = carbon-build-proc ] && pass "sampler: a second consecutive non-zero sample raises carbon-build-proc" || bad "sampler alarm"
python3 -I "$CBP" --ps-file "$T/ps1.txt" --json >"$T/o4"
[ "$(jq -r '.consecutive' "$T/o4")" = 0 ] && [ "$(jq -r '.alarms | length' "$T/o4")" = 0 ] && pass "sampler: a zero sample clears the alarm" || bad "sampler clear"
unset CBP_OUT CBP_HOST

# ---- 8. settings wiring (binding amendment 6)
chk_wired() {   # chk_wired <settings file> <label>
  python3 - "$1" <<'E'
import json, sys
need = {"Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Agent"}
d = json.load(open(sys.argv[1]))
ok = any(set(b.get("matcher", "").split("|")) >= need and any(h.get("command", "").endswith("/hooks/carbon-no-build.sh") for h in b.get("hooks", []))
         for b in d.get("hooks", {}).get("PreToolUse", []))
sys.exit(0 if ok else 1)
E
  [ $? = 0 ] && pass "wired: $2 carries carbon-no-build.sh on Bash|Edit|Write|MultiEdit|NotebookEdit|Agent" || bad "not wired: $2"
}
chk_wired "$root/.claude/settings.json" ".claude/settings.json"
for f in settings ctl-settings; do
  if jq -e 'has("hooks")' "$root/.config/claude-seat/$f.json" >/dev/null; then chk_wired "$root/.config/claude-seat/$f.json" ".config/claude-seat/$f.json (sets a hooks key)"
  else pass "$f.json sets no hooks key"; fi
done
grep -q 'carbon-no-build' "$root/.config/systemd/user/carbon-build-procs.service" 2>/dev/null || grep -q 'carbon-build-procs.py' "$root/.config/systemd/user/carbon-build-procs.service" && pass "carbon-build-procs.service runs the sampler" || bad "sampler unit missing"

echo "passed=$npass"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
