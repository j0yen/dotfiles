#!/usr/bin/env bash
# aide-claim.sh take|release|show <object> [--ttl <dur>] — claim an object (a PR `<repo>#<pr>`, or an advisory `task:<slug>`) for this aide lane.
#   aide-lanes 10-27 (decisions/2026-10-27-aide-lanes-wwhtbt.md mechanism 6): parallel aide lanes must never double-act on one PR.
#   claim file = ${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}/claims/<object>, three lines: lane=<WM_AIDE_LANE or main> / sid=<CLAUDE_SESSION_ID or -> / expires=<epoch>
#   take     default ttl 2h (also 30m, 90s, plain seconds). A live claim held by ANOTHER lane -> exit 3 naming it, nothing written;
#            an expired or own claim is overwritten (ttl restarts).
#   release  removes the claim when it is this lane's or expired; a live foreign claim -> exit 3.
#   show     prints the claim (the three lines + `live`/`expired`), exit 0; no claim -> `none`, exit 1.
#   The PreToolUse hook .claude/hooks/aide-claim-gate.sh takes the claim on act (same file format) and denies the other lane's act.
# Exit: 0 ok / 1 show: none / 3 held by another lane / 64 usage.
set -u
DIR="${FLEET_DASH_DIR:-$HOME/.cache/fleet-dash}/claims"
usage() { echo 'usage: aide-claim.sh take|release|show <repo>#<pr>|task:<slug> [--ttl 2h]' >&2; exit 64; }
[ $# -ge 2 ] || usage
cmd="$1"; obj="$2"; shift 2
[[ "$obj" =~ ^([A-Za-z0-9._-]+#[A-Za-z0-9._-]+|task:[A-Za-z0-9._-]+)$ ]] || { echo "aide-claim: bad object '$obj' (want <repo>#<pr> or task:<slug>)" >&2; usage; }
ttl=7200
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl)
      v="${2:-}"
      [[ "$v" =~ ^([0-9]+)([smhd]?)$ ]] || { echo "aide-claim: bad ttl '$v'" >&2; usage; }
      n="${BASH_REMATCH[1]}"; case "${BASH_REMATCH[2]}" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; d) n=$((n * 86400)) ;; esac
      ttl="$n"; shift 2 ;;
    *) usage ;;
  esac
done
lane="${WM_AIDE_LANE:-main}"; [[ "$lane" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || lane=main
sid="${CLAUDE_SESSION_ID:--}"
f="$DIR/$obj"; now="$(date +%s)"
claim_get() { c_lane=""; c_sid=""; c_exp=0; [ -f "$f" ] || return 1
  c_lane="$(sed -n 's/^lane=//p' "$f" | head -n1)"; c_sid="$(sed -n 's/^sid=//p' "$f" | head -n1)"; c_exp="$(sed -n 's/^expires=//p' "$f" | head -n1)"
  [[ "$c_exp" =~ ^[0-9]+$ ]] || c_exp=0; return 0; }
case "$cmd" in
  take)
    if claim_get && [ "$c_exp" -gt "$now" ] && [ "$c_lane" != "$lane" ]; then
      echo "aide-claim: $obj claimed by lane $c_lane (sid ${c_sid:--}, expires $(date -d "@$c_exp" '+%-I:%M %p'))" >&2; exit 3
    fi
    mkdir -p "$DIR" && tmp="$(mktemp "$DIR/.claim.XXXXXX")" || exit 1
    printf 'lane=%s\nsid=%s\nexpires=%s\n' "$lane" "$sid" "$((now + ttl))" >"$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; exit 1; }
    echo "aide-claim: $obj claimed by lane $lane until $(date -d "@$((now + ttl))" '+%-I:%M %p')" ;;
  release)
    if claim_get && [ "$c_exp" -gt "$now" ] && [ "$c_lane" != "$lane" ]; then
      echo "aide-claim: $obj is held by lane $c_lane (expires $(date -d "@$c_exp" '+%-I:%M %p')); not releasing another lane's claim" >&2; exit 3
    fi
    rm -f "$f"; echo "aide-claim: $obj released" ;;
  show)
    claim_get || { echo none; exit 1; }
    cat "$f"; [ "$c_exp" -gt "$now" ] && echo live || echo expired ;;
  *) usage ;;
esac
