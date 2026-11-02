# zero-open-runs-guard.sh: sourced by approve.sh and seat-ask.sh (Joe #113: a host change applies to new runs at once, never "at 0 open runs" / "when idle").
# zero_open_runs_refuse "<text>"...: returns 1 and prints the refusal on stderr when a text gates work on zero open runs or an idle host; 0 otherwise.
# The patterns live in ONE pair of files, .config/wm-guards/zero-open-runs.ere and zero-open-runs-exempt.ere (WM_GUARDS_DIR overrides the directory);
# swarm-decide wm_decide/checks.py ZERO_OPEN_RUNS_ERE / ZERO_EXEMPT_ERE carry the same strings, pinned by tests/zero-open-runs-nodrift.test.sh and tests/test_record_refusals.py.
# Spans matching the exempt pattern (the rule's own wording) are deleted before the refusal pattern is tried.
zero_open_runs_refuse() {
  local d="" c ere ex t
  for c in "${WM_GUARDS_DIR:-}" "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.config/wm-guards" "$HOME/.config/wm-guards"; do
    [ -n "$c" ] && [ -r "$c/zero-open-runs.ere" ] && { d="$c"; break; }
  done
  [ -n "$d" ] || { echo "zero-open-runs-guard: zero-open-runs.ere not found" >&2; return 0; }
  ere="$(head -n1 "$d/zero-open-runs.ere")"; ex="$(head -n1 "$d/zero-open-runs-exempt.ere" 2>/dev/null)"
  for t in "$@"; do
    if [ -n "$ex" ]; then t="$(printf '%s' "$t" | tr '\r\n' '  ' | sed -E "s/$ex/ /Ig")"; fi
    if printf '%s' "$t" | grep -Eiq -- "$ere"; then
      echo "never wait for 0 open runs (Joe #113): apply to new runs now" >&2; return 1
    fi
  done
  return 0
}
