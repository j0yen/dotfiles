#!/usr/bin/env bash
# adhd-always-on.sh — SessionStart hook: the i-have-adhd always-on injection, owned by dotfiles.
# Replaces the plugin's own always-on hook, which we no longer let fire: the lean/compact one-liner used to be a
# local patch INSIDE ~/.claude/plugins/cache/i-have-adhd/*/hooks/always-on.{mjs,sh} and a plugin update erased it
# (token-cut C3, 10-20 2026; moved here by the Fable review the same day). The plugin cache is pristine again.
#
# Opt-in flag: $CLAUDE_CONFIG_DIR/.adhd-always-on (default ~/.claude). The plugin's own flag name
# (.i-have-adhd-always) is the legacy name: if found it is renamed to the new one, which makes the plugin's hook a
# no-op and this hook the single injector. Rename is a mv (reversible), never a delete.
#
# HEADLESS = NOTHING (Joe 10-22 3:3x PM "Seems like it would have no value in a headless environment"): a session with WM_SEAT rb, r7 or
# ctl (seat units, seat-tick.sh turns) or launched by a `claude -p` / `--print` process (print-mode coders and inners; checked on the
# first 4 ancestors' /proc/<pid>/cmdline) exits 0 with NO output. Interactive sessions below are untouched. `--selftest` covers it
# (ADHD_SKIP_ANCESTORS=1 is a selftest-only seam so the real ancestry cannot change a result).
#
# Output: LEAN (CLAUDE_LEAN_START=1 or SEAT_LEAN=1) or source=compact -> one line; otherwise the full ruleset from
# the newest cached plugin SKILL.md (frontmatter stripped). Never blocks session start: any failure exits 0.
# print-mode matcher: $1 = a cmdline with NULs already turned into spaces; true when it has ` -p ` / `--print`, or ends in ` -p`
adhd_cmdline_is_print() {
  local c=" ${1%" "} "
  [[ "$c" == *" -p "* || "$c" == *"--print"* ]]
}
# true when any of the first 4 ancestors (from $PPID) runs in print mode
adhd_ancestor_is_print() {
  local pid=$PPID i cmd stat
  [ "${ADHD_SKIP_ANCESTORS:-}" = 1 ] && return 1
  for i in 1 2 3 4; do
    [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || return 1
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    adhd_cmdline_is_print "$cmd" && return 0
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    pid=$(set -- ${stat##*) }; echo "${2:-}")   # fields after "(comm) ": state ppid ...
  done
  return 1
}
adhd_headless() {
  case "${WM_SEAT:-}" in rb|r7|ctl) return 0 ;; esac
  adhd_ancestor_is_print
}

selftest() {
  local T fail=0 out me
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  me=$(readlink -f "${BASH_SOURCE[0]}")
  chk() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
  mkdir -p "$T/on" "$T/off"; : >"$T/on/.adhd-always-on"
  # (i) seat env -> silent
  out=$(WM_SEAT=ctl CLAUDE_CONFIG_DIR="$T/on" ADHD_SKIP_ANCESTORS=1 bash "$me" </dev/null 2>&1); chk "WM_SEAT=ctl, flag present: empty output rc 0 (rc=$? len=${#out})" $([ -z "$out" ] && echo 0 || echo 1)
  for s in rb r7; do out=$(WM_SEAT=$s CLAUDE_CONFIG_DIR="$T/on" ADHD_SKIP_ANCESTORS=1 bash "$me" </dev/null 2>&1); chk "WM_SEAT=$s: empty output" $([ -z "$out" ] && echo 0 || echo 1); done
  # (ii) print-mode matcher on sample cmdlines
  for c in 'claude --dangerously-skip-permissions -p --resume X' 'claude -p "x"' 'claude --print' 'claude --dangerously-skip-permissions --resume X -p'; do
    adhd_cmdline_is_print "$c"; chk "matcher positive: $c" $?
  done
  for c in 'claude --dangerously-skip-permissions --resume X' 'claude --model claude-opus-5-5' 'claude --plugin-dir /x/pp'; do
    ! adhd_cmdline_is_print "$c"; chk "matcher negative: $c" $?
  done
  # (iii) interactive path: flag absent -> empty; flag present + lean -> the one-liner
  out=$(env -u WM_SEAT CLAUDE_CONFIG_DIR="$T/off" ADHD_SKIP_ANCESTORS=1 bash "$me" </dev/null 2>&1); chk "interactive, flag absent: empty" $([ -z "$out" ] && echo 0 || echo 1)
  out=$(env -u WM_SEAT CLAUDE_CONFIG_DIR="$T/on" CLAUDE_LEAN_START=1 ADHD_SKIP_ANCESTORS=1 bash "$me" </dev/null 2>&1)
  chk "interactive, flag present + CLAUDE_LEAN_START=1: the one-liner" $([ "$out" = 'ADHD MODE ACTIVE (always-on); ruleset = i-have-adhd skill.' ] && echo 0 || echo 1)
  [ "$fail" = 0 ] && echo "SELFTEST PASS" || echo "SELFTEST FAIL"; return "$fail"
}
[ "${1:-}" = --selftest ] && { selftest; exit $?; }

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
flag="$claude_dir/.adhd-always-on"
legacy="$claude_dir/.i-have-adhd-always"
if [ ! -f "$flag" ] && [ -f "$legacy" ]; then mv -f "$legacy" "$flag" 2>/dev/null || cp "$legacy" "$flag" 2>/dev/null; fi
[ -f "$flag" ] || exit 0
adhd_headless && exit 0   # seat units and print-mode sessions get nothing

src=""
[ -t 0 ] || src=$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ "${CLAUDE_LEAN_START:-}" = 1 ] || [ "${SEAT_LEAN:-}" = 1 ] || [ "$src" = compact ]; then
  printf 'ADHD MODE ACTIVE (always-on); ruleset = i-have-adhd skill.\n'; exit 0
fi

skill=$(ls -d "$claude_dir"/plugins/cache/i-have-adhd/i-have-adhd/*/skills/i-have-adhd/SKILL.md 2>/dev/null | sort -V | tail -1)
[ -n "$skill" ] && [ -f "$skill" ] || exit 0
body=$(awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next} fm && /^---[[:space:]]*$/ {fm=0; next} !fm {print}' "$skill") || exit 0
printf 'ADHD MODE ACTIVE (always-on). The ruleset below applies to every response. "stop adhd mode" turns it off for this session; delete %s to turn always-on off for good.\n\n%s\n' \
  "$flag" "$body"
