#!/usr/bin/env bash
# hetzner-fixed-fleet-guard-carbon.sh -- second, delete-only Hetzner guard on carbon (A44; ctl RECOMMEND 10-23; CLAUDE.md "PERMANENT HETZNER BOXES ONLY").
# The primary guard is hetzner-fixed-fleet-guard.timer on RedBaron. This copy deletes any server outside the fixed fleet from carbon, so one dead host
# cannot leave a leased box billing. Premise + EXPIRES + decision row per delete through watcher-premise.sh. Never Claude.
#   (no args)           list servers, delete the non-fleet ones (only while the premise holds and the token exists)
#   --staleness [MAX_S] print one JSON line {hetzner_guard_carbon_stale_s, hetzner_guard_carbon_alarm, status}; rc 1 = alarm (status.json guard-staleness key)
#   --selftest          decision path against a stub curl, no API call
# Env (tests): HZG_STATE, HZG_TOKEN, HZG_ALLOW, HZG_EXPIRES, HZG_PREMISE_FILE, WP_LIB, WP_STATE, WP_DECIDE_BIN.
set -u
HZG_STATE=${HZG_STATE:-$HOME/.local/state/hetzner-guard-carbon}
HZG_TOKEN=${HZG_TOKEN:-$HOME/.config/hetzner-guard/token}
HZG_ALLOW=${HZG_ALLOW:-hub orch mcphost-1}
HZG_EXPIRES=${HZG_EXPIRES:-2026-12-01T23:59:59}
HZG_PREMISE_FILE=${HZG_PREMISE_FILE:-$HOME/.claude/CLAUDE.md}
WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
export WP_OWNER=${WP_OWNER:-rb} WP_DECIDE_KIND=${WP_DECIDE_KIND:-guard}
mkdir -p "$HZG_STATE" 2>/dev/null

stamp() { # STATUS [DETAIL]: always writes last; last_ok only when the list call worked
  printf '%s %s %s\n' "$(date +%s)" "$1" "${2:--}" > "$HZG_STATE/last" 2>/dev/null
  [ "$1" = ok ] && date +%s > "$HZG_STATE/last_ok" 2>/dev/null
  return 0
}

case "${1:-}" in
--staleness)
  max=${2:-900}; now=$(date +%s)
  ok=$(cat "$HZG_STATE/last_ok" 2>/dev/null); case "$ok" in ''|*[!0-9]*) ok=0;; esac
  st=$(awk '{print $2}' "$HZG_STATE/last" 2>/dev/null); st=${st:-never-ran}
  age=$((now - ok)); [ "$ok" -eq 0 ] && age=-1
  alarm=false; { [ "$age" -lt 0 ] || [ "$age" -gt "$max" ]; } && alarm=true
  printf '{"hetzner_guard_carbon_stale_s":%s,"hetzner_guard_carbon_alarm":%s,"status":"%s"}\n' "$age" "$alarm" "$st"
  [ "$alarm" = false ]; exit ;;
--selftest)
  T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin"; printf 'dummy' > "$T/tok"; : > "$T/deletes"
  cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
case " $* " in
*" DELETE "*) printf '%s\n' "$*" >> "$STUB_DIR/deletes"; printf '200' ;;
*) printf '%s' '{"servers":[{"id":1,"name":"hub","server_type":{"name":"cx"}},{"id":9,"name":"leased-9","server_type":{"name":"cx"}}]}' ;;
esac
STUB
  chmod +x "$T/bin/curl"; printf 'PERMANENT HETZNER BOXES ONLY\n' > "$T/claude.md"
  [ -r "$WP_LIB" ] || WP_LIB="$(dirname "$(readlink -f "$0")")/../lib/watcher-premise.sh"   # no installed copy (fresh HOME / RB): use the repo lib
  STUB_DIR=$T PATH="$T/bin:$PATH" WP_LIB=$WP_LIB HZG_STATE=$T/s HZG_TOKEN=$T/tok HZG_PREMISE_FILE=$T/claude.md WP_STATE=$T/wp WP_DECIDE_BIN=none-here bash "$0" >/dev/null 2>&1
  [ "$(wc -l < "$T/deletes")" -eq 1 ] && grep -q '/v1/servers/9$' "$T/deletes" || { echo "SELFTEST FAIL: delete set"; exit 1; }
  echo "SELFTEST ok"; exit 0 ;;
"") ;;
*) echo "usage: hetzner-fixed-fleet-guard-carbon.sh [--staleness [MAX_S]|--selftest]" >&2; exit 2 ;;
esac

[ -r "$HZG_TOKEN" ] || { stamp no-token "$HZG_TOKEN"; echo "hetzner-guard-carbon: no token at $HZG_TOKEN (not guarding)" >&2; exit 0; }
# shellcheck disable=SC1090
. "$WP_LIB" 2>/dev/null; type wp_arm >/dev/null 2>&1 || { stamp no-lib "$WP_LIB"; echo "hetzner-guard-carbon: watcher-premise lib missing" >&2; exit 2; }
wp_arm hetzner-fixed-fleet-guard-carbon "grep -q 'PERMANENT HETZNER BOXES ONLY' $(printf '%q' "$HZG_PREMISE_FILE")" "$HZG_EXPIRES" 'fixed fleet = hub, orch, mcphost-1; Joe 2026-10-11 (no non-permanent Hetzner boxes)' || true
T=$(cat "$HZG_TOKEN")
json=$(curl -s --max-time 30 -H "Authorization: Bearer $T" 'https://api.hetzner.cloud/v1/servers?per_page=50') && [ -n "$json" ] || { stamp list-failed; echo "$(date -Is) list failed" >&2; exit 1; }
rows=$(printf '%s' "$json" | HZG_ALLOW=$HZG_ALLOW python3 -I -c '
import json,sys,os
allow=set(os.environ["HZG_ALLOW"].split()); d=json.load(sys.stdin)
print("N\t"+",".join(s["name"] for s in d["servers"]))
for s in d["servers"]:
    if s["name"] not in allow: print("X\t%d\t%s" % (s["id"], s["name"]))') || { stamp parse-failed; exit 1; }
names=$(printf '%s\n' "$rows" | awk -F'\t' '$1=="N"{print $2}')
stamp ok "servers=$names"; echo "$(date -Is) ok servers=$names"
printf '%s\n' "$rows" | awk -F'\t' '$1=="X"{print $2"\t"$3}' | while IFS=$'\t' read -r id name; do
  if wp_gate && wp_emit_write hetzner-delete "server=$name id=$id" "DELETE /v1/servers/$id ($name outside fixed fleet)" "api list $(date -Is)" "recreate the server by hand; a deleted box is not restorable"; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $T" "https://api.hetzner.cloud/v1/servers/$id")
    echo "$(date -Is) DELETED non-fleet server $name -> $code"
  else
    echo "$(date -Is) premise disarmed: NOT deleting $name"
  fi
done
exit 0
