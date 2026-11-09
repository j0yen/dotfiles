#!/usr/bin/env bash
# carbon-alive-discord.test.sh — .local/bin/carbon-alive-discord.sh with a fake curl on PATH (A1446 F2), and the
# carbon-alive.sh default deliverer wiring (deliver file absent + webhook.url present).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; pass=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/cfg" CARBON_ALIVE_HOST=testhost
export CARBON_ALIVE_SSH="$here/tests/fixtures/carbon-alive-fake-ssh.sh" CA_CURL_LOG="$T/curl"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/carbon-alive" "$T/bin" "$CA_CURL_LOG"
ln -s "$here/tests/fixtures/carbon-alive-fake-curl.sh" "$T/bin/curl"; export PATH="$T/bin:$PATH"
D="$here/.local/bin/carbon-alive-discord.sh"; wf="$XDG_CONFIG_HOME/carbon-alive/webhook.url"
SECRET="TOKENsecret9f3a"; URL="https://discord.example/api/webhooks/123/$SECRET"
alert='{"kind":"alert","host":"testhost","state":"gateway-down","since":1,"outage_since":1,"states":["gateway-down","bus-down"],"at":2,"text":"x","readings":{"host_up":"1","gateway":"failed"}}'
setwf() { rm -f "$wf"; printf '%s\n' "$2" > "$wf"; chmod "$1" "$wf"; }
creset() { rm -rf "$CA_CURL_LOG"; mkdir -p "$CA_CURL_LOG"; unset CA_FAKE_HTTP CA_FAKE_CURL_RC; }
calls() { [ -f "$CA_CURL_LOG/calls" ] && wc -l < "$CA_CURL_LOG/calls" || echo 0; }

creset; setwf 600 "$URL"; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?
[ "$r" = 0 ] && [ "$(calls)" = 1 ] && ! grep -qF "$SECRET" "$CA_CURL_LOG/argv" "$T/out" && ! grep -qF discord.example "$CA_CURL_LOG/argv" \
  && grep -qx cfg=url "$CA_CURL_LOG/cfg" && grep -qx -- '--max-time' "$CA_CURL_LOG/argv" \
  && python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"];assert "gateway-down" in c and "bus-down" in c and "testhost" in c and "gateway=failed" in c and len(c)<=2000' "$CA_CURL_LOG/stdin" \
  && ok "1 0600 file -> curl called, 204 -> 0, URL absent from argv and output" || { bad "1 0600 post (rc=$r)"; cat "$T/out" "$CA_CURL_LOG/argv"; }

creset; setwf 644 "$URL"; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?
[ "$r" != 0 ] && [ "$(calls)" = 0 ] && ! grep -qF "$SECRET" "$T/out" && ok "2 0644 file -> nonzero, curl not called" || bad "2 0644 (rc=$r calls=$(calls))"

creset; setwf 600 "http://discord.example/api/webhooks/123/$SECRET"; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?
[ "$r" != 0 ] && [ "$(calls)" = 0 ] && ! grep -qF "$SECRET" "$T/out" && ok "3 http:// -> nonzero, curl not called" || bad "3 http (rc=$r)"

creset; rm -f "$wf"; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?
[ "$r" != 0 ] && [ "$(calls)" = 0 ] && ok "4 missing file -> nonzero" || bad "4 missing (rc=$r)"

creset; printf '%s\n' "$URL" > "$T/real.url"; chmod 600 "$T/real.url"; ln -s "$T/real.url" "$wf"
printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?; rm -f "$wf"
[ "$r" != 0 ] && [ "$(calls)" = 0 ] && ok "5 symlinked webhook file -> nonzero" || bad "5 symlink (rc=$r)"

creset; export CA_FAKE_HTTP=500; setwf 600 "$URL"; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r=$?
[ "$r" != 0 ] && [ "$(calls)" = 1 ] && ! grep -qF "$SECRET" "$T/out" && ok "6 http 500 -> nonzero, URL not in error text" || bad "6 500 (rc=$r)"

creset; setwf 600 "$URL"
big="$(python3 -I -c 'import json;print(json.dumps({"kind":"alert","host":"h","state":"bus-down","states":["bus-down"],"readings":{"k%d"%i:"v"*40 for i in range(100)}}))')"
printf '%s' "$big" | "$D" alert >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"];assert len(c)<=2000 and "\n" not in c' "$CA_CURL_LOG/stdin" \
  && ok "7 long readings -> content truncated to <= 2000 chars, one line" || bad "7 truncate"

# carbon-alive.sh default wiring: no deliver file, webhook.url present -> carbon-alive-discord.sh; a 500 keeps the alert
creset; rm -f "$XDG_CONFIG_HOME/carbon-alive/deliver"; setwf 600 "$URL"; clock=1000000
run() { CARBON_ALIVE_NOW="$clock" "$here/.local/bin/carbon-alive.sh"; clock=$((clock+120)); }
ob="$XDG_STATE_HOME/carbon-alive/outbox.jsonl"
export CA_FAKE_HTTP=500 CA_FAKE_RC=255; run; run
[ "$(calls)" = 1 ] && [ "$(wc -l < "$ob")" = 1 ] && ok "8 carbon-alive default deliverer, curl 500 -> alert stays in outbox" || bad "8 outbox on 500 (calls=$(calls))"
unset CA_FAKE_HTTP CA_FAKE_RC; run
[ "$(calls)" = 3 ] && [ ! -s "$ob" ] && grep -q '"content": "carbon-alive\[testhost\] recovery' "$CA_CURL_LOG/stdin" \
  && ok "9 next run 204 -> outbox replayed, then recovery delivered" || bad "9 replay (calls=$(calls))"
! grep -rqF "$SECRET" "$XDG_STATE_HOME" && ok "10 URL absent from state dir" || bad "10 URL leaked to state"

echo "carbon-alive-discord.test: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
