#!/usr/bin/env bash
# skill-route-ledger-reader.test.sh: the resolver's canonical ledger read (ledger A1300 interface, A1665 O1R5 preflight).
# Exercises the real subprocess path (SKILL_ROUTE_LEDGER_IDS unset) against a stub reader at the pinned path in a private HOME.
# No provider calls, no real ledger. Run alone: bash tests/skill-route-ledger-reader.test.sh [resolver.py]
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
RES="${1:-$R/.local/lib/skill-route-resolve.py}"
export SKILL_ROUTE_POLICY="$R/.config/skill-routing/policy.json"
unset SKILL_ROUTE_LEDGER_IDS WM_DECIDE_STATE WM_DECIDE_LIVE_BIN
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/.local/bin" "$T/pathbin"
# stub reader: behaviour chosen by $T/mode; records argv, env redirects and stdin kind
cat >"$T/stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$T/argv"
printf 'STATE=%s LIVE=%s\n' "\${WM_DECIDE_STATE-unset}" "\${WM_DECIDE_LIVE_BIN-unset}" >"$T/env"
if [ -t 0 ]; then echo tty; elif read -r -t 0.1 _l; then echo data; else echo empty; fi >"$T/stdin"
case "\$(cat "$T/mode")" in
  found)   echo '[{"ask_id":"A1665","rev":248,"status":"open"}]' ;;
  none)    echo '[]' ;;
  exit1)   echo 'boom' >&2; exit 1 ;;
  exit127) echo 'wm-asks: no canonical asks API' >&2; exit 127 ;;
  nonjson) echo 'not json at all' ;;
  string)  echo '"A1665"' ;;
  object)  echo '{"ask_id":"A1665"}' ;;
  scalar)  echo '[1]' ;;
  other)   echo '[{"ask_id":"A9999","rev":1}]' ;;
  mixed)   echo '[{"ask_id":"A1665","rev":248},{"ask_id":"A1666","rev":3}]' ;;
  noid)    echo '[{"rev":3}]' ;;
  sleep)   sleep 20; echo '[{"ask_id":"A1665"}]' ;;
esac
EOF
chmod +x "$T/stub"; cp "$T/stub" "$H/.local/bin/wm-asks"
# a wrapper earlier on PATH that would claim every id: must never be consulted
printf '#!/bin/sh\necho "[{\\"ask_id\\":\\"A1665\\"}]"\ntouch %s/pathbin-used\n' "$T" >"$T/pathbin/wm-asks"; chmod +x "$T/pathbin/wm-asks"
REQ='{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["ledger:A1665"]}}'
fail=0
# chk NAME MODE WANT_RC ERR_SUBSTRING [extra env assignments...]
chk(){ local name=$1 mode=$2 want=$3 sub=$4; shift 4; echo "$mode" >"$T/mode"; local out rc
  out=$(printf '%s' "$REQ" | env HOME="$H" PATH="$T/pathbin:/usr/bin:/bin" "$@" python3 -I "$RES" 2>/dev/null); rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL $name rc=$rc want $want: $out"; fail=1; return; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | grep -qF -- "$sub"; then echo "FAIL $name missing '$sub': $out"; fail=1; return; fi
  echo "PASS $name"; }
chk "valid canonical row -> resolved"            found   0 '"ok": true'
chk "empty result -> not found"                  none    2 "not found in the ledger"
chk "reader exit 1 -> unavailable, not 'not found'"   exit1   2 "ledger lookup unavailable; cannot verify ledger:A1665 (fail closed; exit-1)"
chk "reader exit 127 -> unavailable"             exit127 2 "(fail closed; exit-127)"
chk "non-json -> corrupt"                        nonjson 2 "ledger lookup corrupt"
chk "json string -> corrupt (was accepted)"      string  2 "ledger lookup corrupt"
chk "json object -> corrupt"                     object  2 "ledger lookup corrupt"
chk "list of scalars -> corrupt"                 scalar  2 "ledger lookup corrupt"
chk "row for another id -> mismatch (was accepted)" other 2 "ledger lookup mismatch; cannot verify ledger:A1665 (fail closed; reader returned A9999)"
chk "extra row for another id -> mismatch"       mixed   2 "reader returned A1666"
chk "row without ask_id -> mismatch"             noid    2 "ledger lookup mismatch"
chk "reader timeout -> unavailable"              sleep   2 "(fail closed; timeout)"
[ ! -e "$T/pathbin-used" ] && echo "PASS PATH wrapper never consulted" || { echo "FAIL PATH wrapper used"; fail=1; }
chk "store redirect env not passed to reader"    found   0 '"ok": true' WM_DECIDE_STATE="$T/mirror" WM_DECIDE_LIVE_BIN="$T/pathbin/wm-asks"
grep -qx 'STATE=unset LIVE=unset' "$T/env" && echo "PASS redirect vars stripped" || { echo "FAIL redirect vars reached reader: $(cat "$T/env")"; fail=1; }
grep -qx 'asks query --ids A1665 --status all --json' "$T/argv" && echo "PASS exact read-only argv" || { echo "FAIL argv: $(cat "$T/argv")"; fail=1; }
grep -qx 'empty' "$T/stdin" && echo "PASS reader gets no stdin (request bytes not leaked)" || { echo "FAIL reader stdin: $(cat "$T/stdin")"; fail=1; }
rm -f "$H/.local/bin/wm-asks"
chk "reader absent at pinned path -> unavailable (PATH copy ignored)" found 2 "(fail closed; reader-absent $H/.local/bin/wm-asks)"
[ ! -e "$T/pathbin-used" ] && echo "PASS PATH wrapper never consulted when pinned reader absent" || { echo "FAIL PATH wrapper used"; fail=1; }
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
