#!/usr/bin/env bash
# carbon-alive-discord.test.sh — .local/bin/carbon-alive-discord.sh with a fake curl on PATH (A1446 F2), and the
# carbon-alive.sh default deliverer wiring (deliver file absent + webhook.url present).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; pass=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'kill "${lp:-0}" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/cfg" CARBON_ALIVE_HOST=testhost
export CARBON_ALIVE_SSH="$here/tests/fixtures/carbon-alive-fake-ssh.sh" CA_CURL_LOG="$T/curl"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/carbon-alive" "$T/bin" "$CA_CURL_LOG"
# open loopback port = a REF the witness reaches (no test touches the internet)
python3 -I "$here/tests/fixtures/carbon-alive-listen.py" > "$T/refport" & lp=$!
for _ in $(seq 50); do [ -s "$T/refport" ] && break; sleep 0.1; done
REF_OPEN="127.0.0.1:$(cat "$T/refport")"; export CARBON_ALIVE_REF="$REF_OPEN"
ln -s "$here/tests/fixtures/carbon-alive-fake-curl.sh" "$T/bin/curl"; export PATH="$T/bin:$PATH"
D="$here/.local/bin/carbon-alive-discord.sh"; wf="$XDG_CONFIG_HOME/carbon-alive/webhook.url"
SECRET="TOKENsecret9f3a"; URL="https://discord.example/api/webhooks/123/$SECRET"
alert='{"kind":"alert","host":"testhost","state":"gateway-down","since":1,"outage_since":1,"states":["gateway-down","bus-down"],"at":2,"text":"x","readings":{"host_up":"1","gateway":"failed"}}'
setwf() { rm -f "$wf"; printf '%s\n' "$2" > "$wf"; chmod "$1" "$wf"; }
creset() { rm -rf "$CA_CURL_LOG"; mkdir -p "$CA_CURL_LOG"; unset CA_FAKE_HTTP CA_FAKE_HTTP_SEQ CA_FAKE_CURL_RC; }
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
[ "$(calls)" = 3 ] && [ ! -s "$ob" ] && grep -q '"content": "1970-01-12T[0-9:]*Z carbon-alive\[testhost\] recovery' "$CA_CURL_LOG/stdin" \
  && ok "9 next run 204 -> outbox replayed, then recovery delivered" || bad "9 replay (calls=$(calls))"
! grep -rqF "$SECRET" "$XDG_STATE_HOME" && ok "10 URL absent from state dir" || bad "10 URL leaked to state"

# G2: HTTP 4xx other than 429 = permanent (exit 3); 429 and 5xx = retry (exit 1)
creset; setwf 600 "$URL"; export CA_FAKE_HTTP=400; printf '%s' "$alert" | "$D" alert > "$T/out" 2>&1; r400=$?
export CA_FAKE_HTTP=429; printf '%s' "$alert" | "$D" alert > "$T/out2" 2>&1; r429=$?
[ "$r400" = 3 ] && [ "$r429" = 1 ] && ! grep -qF "$SECRET" "$T/out" "$T/out2" && ok "11 http 400 -> exit 3, 429 -> exit 1 ($r400/$r429)" \
  || bad "11 4xx exit codes $r400/$r429"

# (n) via carbon-alive.sh: 400 for the first outbox entry, 204 after -> first dead-lettered, second delivered, URL never logged
creset; rm -rf "$XDG_STATE_HOME"; mkdir -p "$XDG_STATE_HOME/carbon-alive"; setwf 600 "$URL"; clock=1000000
for i in 1 2; do echo "{\"kind\":\"alert\",\"host\":\"h\",\"state\":\"bus-down\",\"at\":$i,\"id\":\"e$i\",\"readings\":{}}"; done > "$ob"
export CA_FAKE_HTTP_SEQ="400 204"; run 2> "$T/err"; unset CA_FAKE_HTTP_SEQ
dead="$XDG_STATE_HOME/carbon-alive/outbox.dead.jsonl"
[ "$(calls)" = 2 ] && grep -q '"id":"e1"' "$dead" && ! grep -q '"id":"e2"' "$dead" && [ ! -s "$ob" ] \
  && python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"];assert c.startswith("1970-01-01T00:00:02Z REPLAY 1970-01-12T13:46:40Z "),c' "$CA_CURL_LOG/stdin" \
  && grep -q 'kind=alert state=bus-down at=1 permanently, moved to outbox.dead.jsonl' "$T/err" && ! grep -qF "$SECRET" "$T/err" \
  && ! grep -qF discord.example "$T/err" && ok "n 400 then 204 -> e1 in outbox.dead.jsonl, e2 delivered, one log line without the URL" \
  || { bad "n dead-letter (calls=$(calls))"; cat "$T/err"; }

# (p) G3: replayed entry -> text starts with the original at, then REPLAY and the replay time
creset; setwf 600 "$URL"
ra='{"kind":"alert","host":"testhost","state":"bus-down","executor":"stale","at":1762700000,"replay_at":1762703600,"states":["bus-down"],"readings":{"bus":"down"}}'
printf '%s' "$ra" | "$D" alert >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"]
assert c.startswith("2025-11-09T14:53:20Z REPLAY 2025-11-09T15:53:20Z carbon-alive[testhost] alert: state=bus-down executor=stale "),c' "$CA_CURL_LOG/stdin" \
  && ok "p replayed entry -> text starts with original at, REPLAY, replay time; names executor" || { bad "p replay text"; cat "$CA_CURL_LOG/stdin"; }
printf '%s' "${ra/,\"replay_at\":1762703600/}" | "$D" alert >/dev/null 2>&1
python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"];assert c.startswith("2025-11-09T14:53:20Z carbon-alive[") and "REPLAY" not in c,c' "$CA_CURL_LOG/stdin" \
  && ok "p2 fresh entry -> at time first, no REPLAY" || bad "p2 fresh text"

# (w) C5: stale carbon-alive-discord.* temp configs (left by a SIGKILL) are removed at the next start; fresh ones kept
creset; setwf 600 "$URL"; td="$T/tmpd"; mkdir -p "$td"
touch -d '-15 minutes' "$td/carbon-alive-discord.stale1"; touch "$td/carbon-alive-discord.fresh1"; touch -d '-15 minutes' "$td/other.old"
printf '%s' "$alert" | TMPDIR="$td" "$D" alert >/dev/null 2>&1; r=$?
left="$(cd "$td" && ls | sort | tr '\n' ' ')"
[ "$r" = 0 ] && [ ! -e "$td/carbon-alive-discord.stale1" ] && [ -e "$td/carbon-alive-discord.fresh1" ] && [ -e "$td/other.old" ] \
  && [ "$left" = "carbon-alive-discord.fresh1 other.old " ] \
  && ok "w stale carbon-alive-discord.* removed at start, fresh one and other files kept, own config removed on exit" || bad "w temp cleanup (left: $left)"

# (m) allowed_mentions: every payload carries an empty parse list, so @everyone / @here / <@id> in the text ping nobody
creset; setwf 600 "$URL"
ma='{"kind":"alert","host":"testhost","state":"bus-down","executor":"fresh","at":2,"states":["bus-down"],"readings":{"note":"@everyone @here <@123456789> <@&987654321>"}}'
printf '%s' "$ma" | "$D" alert >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));assert "@everyone" in p["content"] and "<@123456789>" in p["content"],p;assert p["allowed_mentions"]=={"parse":[]},p' "$CA_CURL_LOG/stdin" \
  && ok "m1 alert text with @everyone/@here/<@id> -> payload allowed_mentions {parse: []}" || { bad "m1 mentions"; cat "$CA_CURL_LOG/stdin"; }
creset; printf '%s' "$ma" | "$D" recovery >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));assert p["allowed_mentions"]=={"parse":[]},p' "$CA_CURL_LOG/stdin" \
  && printf '%s' "$big" | "$D" alert >/dev/null 2>&1 \
  && python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));assert p["allowed_mentions"]=={"parse":[]} and len(p["content"])<=2000,p' "$CA_CURL_LOG/stdin" \
  && ok "m2 recovery kind and a truncated long payload carry it too" || bad "m2 mentions on recovery/truncated"

echo "carbon-alive-discord.test: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
