#!/usr/bin/env bash
# dpms AC 8 / R5(e): the readback script tests/dpms_live.sh is proven against
# gates whose behavior is known, never by its own exit declarations. Each run
# gives the script a temporary HOME whose .claude/hooks/prd-write-gate.sh is a
# symlink to: the pinned 61d0c6a2 fixture (7), a comment-edited copy of it
# (8, after the copy is shown to admit directly), the landed gate (0), a
# dangling link (2, no probe), the landed gate with no jq on PATH (2, no
# probe), a mode-644 copy of the landed gate (0; a direct-exec script would
# read 126 as an admit and exit 8). Extra controls: a gate that exits non-zero
# with no output counts as admit (8); an inherited SKILL_MARKER_DIR and
# DREAM_TTL_MIN never reach the probes; the script reads nothing from stdin.
# Never touches the real ~/.claude/hooks or ~/dotfiles.
. "$(dirname "$0")/dpms_test_helpers.sh"
fixture_check

[ -f "$LIVE_SCRIPT" ] || { notok "tests/dpms_live.sh exists"; finish; }

dpms_setup; tw="$work/tw"; mkdir -p "$tw"   # cleaned by dpms_setup's trap
# live_home <target> — a HOME whose installed hook links to <target>
live_home() {
  local h; h="$(mktemp -d "$tw/home.XXXX")"; mkdir -p "$h/.claude/hooks"
  ln -s "$1" "$h/.claude/hooks/prd-write-gate.sh"; printf '%s' "$h"
}
# run_live <home> [env…] — sets LOUT and LRC; stdin closed
run_live() { local h="$1"; shift; LOUT=$(env "$@" HOME="$h" bash "$LIVE_SCRIPT" </dev/null 2>"$tw/err"); LRC=$?; }
probe_lines() { printf '%s\n' "$LOUT" | grep -c '^probe='; }

# Run 1: the pinned 61d0c6a2 fixture (mode 644) -> 7
h=$(live_home "$FIX_GATE"); run_live "$h"
assert_eq "$LRC" 7 "R5(e) run 1 fixture: exit 7 (not-installed)"
assert_contains "$LOUT" "hook=$FIX_GATE sha256=$FIX_GATE_SHA" "R5(e) run 1: hook=<resolved path> sha256=cf9bee6a… line"
assert_contains "$LOUT" "probe=empty verdict=admit" "R5(e) run 1: empty probe admit"
assert_contains "$LOUT" "probe=foreign verdict=admit" "R5(e) run 1: foreign probe admit"

# Run 2: the fixture plus one appended comment line -> 8
cp "$FIX_GATE" "$tw/edited.sh"; printf '# dpms comment edit\n' >>"$tw/edited.sh"
cmp -s "$FIX_GATE" "$tw/edited.sh" && notok "R5(e) run 2: the edit changed the file" || ok "R5(e) run 2: the edit changed the file"
fresh_legacy; mkdir -p "$SKILL_MARKER_DIR"
expect_pass "$tw/edited.sh" "$(write_input T "$PRD")" "R5(e) run 2: edited copy admits AC1's empty-directory input directly"
h=$(live_home "$tw/edited.sh"); run_live "$h"
assert_eq "$LRC" 8 "R5(e) run 2 edited copy: exit 8"
assert_contains "$LOUT" "sha256=$(sha256sum "$tw/edited.sh" | cut -d' ' -f1)" "R5(e) run 2: prints the edited digest"

# Run 3: the landed gate -> 0, both probes deny
h=$(live_home "$GATE"); run_live "$h"
assert_eq "$LRC" 0 "R5(e) run 3 landed gate: exit 0"
assert_contains "$LOUT" "hook=$GATE sha256=$(sha256sum "$GATE" | cut -d' ' -f1)" "R5(e) run 3: hook line"
assert_contains "$LOUT" "probe=empty verdict=deny" "R5(e) run 3: empty probe deny"
assert_contains "$LOUT" "probe=foreign verdict=deny" "R5(e) run 3: foreign probe deny"

# Run 4: a dangling symlink -> 2, no probe
h=$(live_home "$tw/does-not-exist.sh"); run_live "$h"
assert_eq "$LRC" 2 "R5(e) run 4 dangling link: exit 2"
assert_eq "$(probe_lines)" 0 "R5(e) run 4: no probe line"

# Run 5: the landed gate under a PATH without jq -> 2, no probe
mkdir -p "$tw/nojq"
for f in /usr/bin/* /usr/local/bin/*; do b=${f##*/}; [ "$b" = jq ] || ln -sf "$f" "$tw/nojq/$b"; done
PATH="$tw/nojq" command -v jq >/dev/null && notok "R5(e) run 5: PATH has no jq" || ok "R5(e) run 5: PATH has no jq"
h=$(live_home "$GATE"); run_live "$h" PATH="$tw/nojq"
assert_eq "$LRC" 2 "R5(e) run 5 no jq: exit 2"
assert_eq "$(probe_lines)" 0 "R5(e) run 5: no probe line"

# Run 6: a mode-644 copy of the landed gate -> 0
cp "$GATE" "$tw/landed644.sh"; chmod 644 "$tw/landed644.sh"
[ -x "$tw/landed644.sh" ] && notok "R5(e) run 6: copy is non-executable" || ok "R5(e) run 6: copy is non-executable"
h=$(live_home "$tw/landed644.sh"); run_live "$h"
assert_eq "$LRC" 0 "R5(e) run 6 mode-644 landed copy: exit 0"

# Extra: a gate that exits non-zero with no output counts as admit -> 8
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n' >"$tw/crash.sh"
h=$(live_home "$tw/crash.sh"); run_live "$h"
assert_eq "$LRC" 8 "R5(e) crash gate: exit 8"
assert_contains "$LOUT" "probe=empty verdict=admit" "R5(e) crash gate: non-zero exit counts as admit"

# Extra: a hook path resolving to a directory -> 2
h=$(live_home "$tw"); run_live "$h"
assert_eq "$LRC" 2 "R5(e) hook resolves to a directory: exit 2"

# Extra: inherited SKILL_MARKER_DIR / DREAM_TTL_MIN never reach the probes
mkdir -p "$tw/sentinel"; touch "$tw/sentinel/keep"
h=$(live_home "$FIX_GATE"); run_live "$h" SKILL_MARKER_DIR="$tw/sentinel" DREAM_TTL_MIN=-1
assert_eq "$LRC" 7 "R5(e) inherited DREAM_TTL_MIN=-1 does not turn the fixture's admit into a deny"
h=$(live_home "$GATE"); run_live "$h" SKILL_MARKER_DIR="$tw/sentinel" DREAM_TTL_MIN=-1
assert_eq "$LRC" 0 "R5(e) landed gate with inherited env: exit 0"
assert_eq "$(ls -A "$tw/sentinel")" "keep" "R5(e) inherited SKILL_MARKER_DIR untouched (no dream-prd.other / dream.other)"

# Extra: the script reads nothing from its own stdin (piped-to-bash form)
h=$(live_home "$GATE")
LOUT=$(cat "$LIVE_SCRIPT" | env HOME="$h" bash 2>/dev/null); LRC=$?
assert_eq "$LRC" 0 "R5(e) 'cat dpms_live.sh | bash' against the landed gate: exit 0"
assert_eq "$(probe_lines)" 2 "R5(e) piped form prints both probe lines"
h=$(live_home "$FIX_GATE")
LOUT=$(cat "$LIVE_SCRIPT" | env HOME="$h" bash 2>/dev/null); LRC=$?
assert_eq "$LRC" 7 "R5(e) piped form against the fixture: exit 7"
finish
