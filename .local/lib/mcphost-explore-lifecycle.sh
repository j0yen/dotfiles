#!/usr/bin/env bash
# mcphost-explore-lifecycle.sh — PRD-mcphost-explore-first-light: the pure,
# fixture-testable decision logic for .local/bin/mcphost-explore-run.sh,
# split out the same way .local/lib/vibeloop-measure-guards.sh is (function
# only, no side effects at source time, no network/systemctl/git calls) so
# tests/explorefirst_ac*.test.sh can source this file directly and exercise
# the logic against fixture ledger lines with no real instance, no synthorg,
# no filesystem writes outside a throwaway test dir.
#
# test_prefix: explorefirst
set -uo pipefail

# Requirement 1/AC2: the current ISO week token used for the "already ran
# this week" skip marker. Honors EXPLOREFIRST_NOW (an ISO-8601 UTC
# timestamp) so tests can pin "now" without faking the `date` binary or the
# system clock; unset in production, where real `date -u` is authoritative.
iso_week() {
  if [ -n "${EXPLOREFIRST_NOW:-}" ]; then
    date -u -d "$EXPLOREFIRST_NOW" +%G-W%V
  else
    date -u +%G-W%V
  fi
}

# Requirement 5: the novelty gate itself — "≥3 use-case candidates no
# corpus task and no panel readout anticipated" (visions/synthorg-dream-feed.md).
# $1 = novel_count (an integer, or empty/non-numeric on a malformed read,
# which never meets the gate). Exit 0 when met.
novelty_gate_met() { # $1=novel_count -> exit 0/1
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 3 ] ;;
  esac
}

# Pulls "status=<x>" and "week=<y>" tokens out of one ledger line (order
# independent, extra tokens ignored) -> "status week", either half empty
# when the line doesn't carry that key.
ledger_line_fields() { # $1=line -> "status week"
  local line="$1" status week
  status=$(printf '%s\n' "$line" | grep -oE 'status=[^ ]+' | head -1 | cut -d= -f2)
  week=$(printf '%s\n' "$line" | grep -oE 'week=[^ ]+' | head -1 | cut -d= -f2)
  echo "${status:-} ${week:-}"
}

# Requirement 6/AC7: true exactly when the ledger's last two lines are both
# status=fail (any earlier history, or a status=ok anywhere in the last
# two, never fires — one bad week beside a good one is not "two
# consecutive"). Prints "<older-week> <newer-week>" on stdout when true.
two_consecutive_failures() { # $1=ledger path -> "week1 week2" (exit 0), or exit 1
  local path="$1" n line1 line2 s1 w1 s2 w2
  [ -f "$path" ] || return 1
  n=$(wc -l < "$path" 2>/dev/null || echo 0)
  [ "$n" -ge 2 ] || return 1
  line1=$(tail -n2 "$path" | head -n1)
  line2=$(tail -n1 "$path")
  read -r s1 w1 <<< "$(ledger_line_fields "$line1")"
  read -r s2 w2 <<< "$(ledger_line_fields "$line2")"
  if [ "$s1" = "fail" ] && [ "$s2" = "fail" ]; then
    echo "$w1 $w2"
    return 0
  fi
  return 1
}

# Requirement 1: mid-cycle guard — "checked, not assumed" against the same
# unit vibeloop-measure.sh's own req-11 guard checks
# (claude-vibeloop-work.service). A thin wrapper (not pure — it shells out)
# so the main script and its tests share one call site; tests put a fake
# `systemctl` earlier on PATH rather than faking this function.
vibeloop_mid_cycle() { # $1=unit name -> exit 0 if active (mid-cycle)
  systemctl --user is-active --quiet "$1" 2>/dev/null
}
