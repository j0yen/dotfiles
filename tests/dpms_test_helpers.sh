#!/usr/bin/env bash
# tests/dpms_test_helpers.sh — shared setup for tests/dpms_ac0N_*.test.sh
# (PRD dream-prd-marker-per-session). Every test runs both hooks under a
# temporary HOME and SKILL_MARKER_DIR, never the real ones, and runs each
# gate through `bash <file>` so the mode-644 pinned fixtures run as-is.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/.claude/hooks/prd-write-gate.sh"
MARKER_HOOK="$ROOT/.claude/hooks/dream-marker.sh"
LIVE_SCRIPT="$ROOT/tests/dpms_live.sh"
FIX_DIR="$ROOT/tests/fixtures/dpms"
FIX_GATE="$FIX_DIR/prd-write-gate.61d0c6a2.sh"
FIX_MARKER="$FIX_DIR/dream-marker.61d0c6a2.sh"
CITED=61d0c6a25a0d65fa081552ba92587a6f9f7bdda4
FIX_GATE_SHA=cf9bee6ab7d9143bbfaedd03ae0c926a6a89cd8885e1152302f63e0fcc1e6915
FIX_MARKER_SHA=9c6caf86378533a98d282e32068ae9e84dda11ac9dbdd4007a33d6b1b279a281
REAL_HOME="$HOME"

fail=0
ok() { echo "ok - $1"; }
notok() { echo "NOT OK - $1"; fail=1; }
assert_eq() { # $1=actual $2=expected $3=description
  if [ "$1" = "$2" ]; then ok "$3"; else notok "$3: got '$1', want '$2'"; fi
}
assert_contains() { # $1=haystack $2=needle $3=description
  case "$1" in *"$2"*) ok "$3" ;; *) notok "$3: '$1' does not contain '$2'" ;; esac
}
finish() { if [ "$fail" = 0 ]; then echo "PASS $(basename "$0")"; exit 0; fi; echo "FAIL $(basename "$0")"; exit 1; }

# dpms_setup — fresh temporary HOME (holding .claude/ and .cache/), the
# marker directory inside it (not created), DREAM_TTL_MIN unset.
dpms_setup() {
  [ -n "${work:-}" ] && rm -rf "$work"
  work="$(mktemp -d)"
  trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
  export HOME="$work/home"
  mkdir -p "$HOME/.claude" "$HOME/.cache"
  export SKILL_MARKER_DIR="$HOME/.claude/state/skill-active"
  unset DREAM_TTL_MIN
  PRD="$work/proj/PRDs/build-queue/PRD-x.md"
  LOG="$HOME/.cache/prd-write-gate.log"
}

age_file() { # $1=path $2=age in minutes (creates the file)
  mkdir -p "$(dirname "$1")"
  touch -d "@$(( $(date +%s) - $2 * 60 ))" "$1"
}
fresh_legacy() { age_file "$HOME/.claude/.dream-active" 0; }
mk_marker() { age_file "$SKILL_MARKER_DIR/$1" "$2"; } # $1=name $2=age min
mtime() { stat -c %.9Y "$1" 2>/dev/null || echo none; }
fresh_within() { # $1=path $2=seconds -> 0 when mtime within $2 s of now
  local m; m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  [ $(( $(date +%s) - m )) -le "$2" ]
}

write_input() { # $1=sid ('-' = no session_id field) $2=file_path
  if [ "$1" = - ]; then jq -cn --arg p "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}'
  else jq -cn --arg s "$1" --arg p "$2" '{session_id:$s,tool_name:"Write",tool_input:{file_path:$p,content:"x"}}'; fi
}
bash_input() { jq -cn --arg s "$1" --arg c "$2" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}'; }
edit_input() { jq -cn --arg s "$1" --arg p "$2" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}'; }

# run_gate <gate file> <json> — sets OUT and RC.
run_gate() { OUT=$(printf '%s' "$2" | bash "$1" 2>/dev/null); RC=$?; }
is_deny() { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }

# snap — the marker directory's existence plus every dream-prd.* name and
# nanosecond mtime, so a call that creates or refreshes one is visible.
snap() {
  if [ -d "$SKILL_MARKER_DIR" ]; then
    echo dir=present
    find "$SKILL_MARKER_DIR" -maxdepth 1 -name 'dream-prd.*' -printf '%f %T@\n' 2>/dev/null | sort
  else echo dir=absent; fi
}
log_last() { tail -n 1 "$LOG" 2>/dev/null; }

# expect_deny <gate> <json> <reason token> <desc> — denied naming /dream and
# the per-session recipe, logged with the reason token, marker names and
# mtimes unchanged by the call, and the same input piped again denied again.
expect_deny() {
  local g="$1" j="$2" why="$3" d="$4" before after
  before=$(snap)
  run_gate "$g" "$j"
  if [ "$RC" = 0 ] && is_deny "$OUT"; then ok "$d: denied"; else notok "$d: denied (rc=$RC out=$OUT)"; fi
  assert_contains "$OUT" "/dream" "$d: reason names /dream"
  assert_contains "$OUT" "invoke the dream skill in this session" "$d: reason names the per-session recipe"
  assert_contains "$OUT" ".allow-prd-handfile" "$d: reason names the override"
  assert_contains "$(log_last)" "reason=$why" "$d: logged reason=$why"
  after=$(snap)
  assert_eq "$after" "$before" "$d: dream-prd.* names and mtimes unchanged"
  sleep 0.05
  run_gate "$g" "$j"
  if is_deny "$OUT"; then ok "$d: same input denied again"; else notok "$d: same input denied again (out=$OUT)"; fi
  assert_eq "$(snap)" "$before" "$d: still unchanged after the second input"
}
# expect_pass <gate> <json> <desc> — exit 0, no decision printed.
expect_pass() {
  run_gate "$1" "$2"
  assert_eq "$RC" 0 "$3: exit 0"
  assert_eq "$OUT" "" "$3: no decision"
}

# fixture_check — the pinned known-bad copies are byte-exact by digest, and
# equal the cited commit's objects when the clone holds them; never fetches.
fixture_check() {
  local f sha obj
  for f in "$FIX_GATE:$FIX_GATE_SHA:.claude/hooks/prd-write-gate.sh" "$FIX_MARKER:$FIX_MARKER_SHA:.claude/hooks/dream-marker.sh"; do
    IFS=: read -r path sha obj <<<"$f"
    if [ "$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)" = "$sha" ]; then ok "fixture digest $(basename "$path")"
    else notok "dpms-fixture-drift: $(basename "$path") sha256 != $sha"; finish; fi
    if git -C "$ROOT" cat-file -e "$CITED:$obj" 2>/dev/null; then
      if git -C "$ROOT" show "$CITED:$obj" | cmp -s - "$path"; then ok "fixture equals $CITED:$obj"
      else notok "dpms-fixture-drift: $(basename "$path") differs from $CITED:$obj"; fi
    else echo "# $CITED:$obj absent from this clone; digest assertion stands alone"; fi
  done
}

# mutant_fallback <out> — the landed gate with dream_active edited to fall
# back to the legacy file when no fresh dream-prd.<sid> exists (R5(b)).
mutant_fallback() {
  awk '
    /^dream_active\(\) \{/ { sub(/^dream_active/, "_dpms_landed_dream_active") }
    /^REASON=/ && !done {
      print "dream_active() {"
      print "    _dpms_landed_dream_active && return 0"
      print "    local legacy=\"$HOME/.claude/.dream-active\""
      print "    [ -f \"$legacy\" ] || return 1"
      print "    [ $(( ( $(date +%s) - $(stat -c %Y \"$legacy\") ) / 60 )) -le \"$DREAM_TTL_MIN\" ] || return 1"
      print "    ADMIT_BY=legacy"
      print "}"
      done = 1
    }
    { print }' "$GATE" >"$1"
}
# mutant_deny_refresh <out> — the landed gate with dream_active edited to
# touch dream-prd.<sid> after reading its mtime and before the comparison (R5(d)).
mutant_deny_refresh() {
  sed '/^[[:space:]]*mtime=\$(stat /a\    touch "$OWN_MARKER" 2>/dev/null' "$GATE" >"$1"
}
