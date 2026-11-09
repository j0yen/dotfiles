#!/bin/bash
# carbon-alive (A1446) synthetic test: down, recovery, UNKNOWN, restart, stale evidence,
# delivery outage + ordered replay, unconfigured channel, mention suppression.
# Loopback fake webhook only; no real host is probed or changed.
set -u
BIN=${CARBON_ALIVE_BIN:-$(dirname "$0")/../.local/bin/carbon-alive}
T=$(mktemp -d)
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cat > "$T/fake.py" <<'EOF'
import http.server, json, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if os.path.exists(f"{d}/fail"):
            self.send_response(500); self.end_headers(); return
        n = len([x for x in os.listdir(d) if x.startswith("recv-")])
        open(f"{d}/recv-{n:03d}.json", "wb").write(body)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(f"{d}/port", "w").write(str(s.server_port))
s.serve_forever()
EOF
mkdir -p "$T/hook"
python3 -I "$T/fake.py" "$T/hook" & SRV=$!
for _ in $(seq 50); do [ -s "$T/hook/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/hook/port")
printf 'http://127.0.0.1:%s/hook\n' "$PORT" > "$T/webhook"; chmod 600 "$T/webhook"

export CARBON_ALIVE_STATE_DIR=$T/state CARBON_ALIVE_WEBHOOK_FILE=$T/webhook
export CARBON_ALIVE_REF=127.0.0.1:$PORT CARBON_ALIVE_PROBE_FILE=$T/probe CARBON_ALIVE_WITNESS=test
NOW=1800000000
recv() { find "$T/hook" -name 'recv-*' | wc -l; }
last() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"])' "$(find "$T/hook" -name 'recv-*' | sort | tail -n 1)"; }
probe_up() { # $1 um, $2 umsince, $3 dash age, $4 bus count
  printf 'now=%s\num=%s\numsince=@%s\ngw=active\nbridge=active\nbus=%s\ndash=%s\nexec=%s\nend=1\n' \
    "$NOW" "${1:-active}" "${2:-1700000000}" "${4:-3}" $((NOW - (${3:-30}))) $((NOW-60)) > "$T/probe"; }
run() { CARBON_ALIVE_NOW=$NOW python3 -I "$BIN" > "$T/out" 2>&1 || bad "cycle rc at $NOW: $(cat "$T/out")"; NOW=$((NOW+60)); }

# 1 healthy: no message
probe_up; run; run
check "healthy sends nothing" '[ "$(recv)" = 0 ]'
check "healthy summary" 'grep -q "host=UP user_manager=UP gateway=UP bus=UP executor=UP evidence=UP" "$T/out"'

# 2 host down with witness online: one DOWN after 3 checks, none repeated
echo SSH_FAIL > "$T/probe"; run; run
check "host down below threshold sends nothing" '[ "$(recv)" = 0 ]'
run
check "host DOWN opens at 3 checks" '[ "$(recv)" = 1 ] && last | grep -q "DOWN carbon host"'
check "subdimensions UNKNOWN, not DOWN" 'grep -q "user_manager=UNKNOWN" "$T/out"'
run; run; run
check "repeated failure stays one incident" '[ "$(recv)" = 1 ]'

# 3 recovery after 2 good checks, once
probe_up; run
check "one good check does not recover" '[ "$(recv)" = 1 ]'
run
check "RECOVERED after 2 good checks" '[ "$(recv)" = 2 ] && last | grep -q "RECOVERED carbon host"'
run
check "recovery sent once" '[ "$(recv)" = 2 ]'

# 4 witness-side flap: ssh fails and REF unreachable -> UNKNOWN, no DOWN; UNKNOWN incident at 10
export CARBON_ALIVE_REF=127.0.0.1:1
echo SSH_FAIL > "$T/probe"; for _ in $(seq 9); do run; done
check "witness offline is UNKNOWN, no DOWN" '[ "$(recv)" = 2 ] && grep -q "host=UNKNOWN" "$T/out"'
run
check "UNKNOWN incident at 10 checks" '[ "$(recv)" = 3 ] && last | grep -q "UNKNOWN carbon host"'
export CARBON_ALIVE_REF=127.0.0.1:$PORT
probe_up; run; run
check "UNKNOWN incident recovers" '[ "$(recv)" = 4 ] && last | grep -q "RECOVERED carbon host"'

# 5 malformed output is UNKNOWN
printf 'now=%s\num=active\n' "$NOW" > "$T/probe"; run
check "malformed output is UNKNOWN" 'grep -q "host=UNKNOWN" "$T/out" && [ "$(recv)" = 4 ]'
probe_up; run

# 6 user manager down: DOWN after 2, gateway suppressed to UNKNOWN; restart event on return
probe_up inactive; run; run
check "user_manager DOWN at 2 checks" '[ "$(recv)" = 5 ] && last | grep -q "DOWN carbon user_manager"'
check "gateway UNKNOWN while manager down" 'grep -q "gateway=UNKNOWN" "$T/out"'
U=$((NOW-5)); probe_up active $U; run
check "restart event names the probe login" '[ "$(recv)" = 6 ] && last | grep -q "RESTART carbon user@1000" && last | grep -q "probe"'
run
check "user_manager RECOVERED" '[ "$(recv)" = 7 ] && last | grep -q "RECOVERED carbon user_manager"'

# 7 stale evidence and future timestamp
probe_up active $U 900; run; run
check "stale status.json is STALE incident" '[ "$(recv)" = 8 ] && last | grep -q "STALE carbon evidence"'
probe_up active $U -600; run
check "future timestamp is UNKNOWN" 'grep -q "evidence=UNKNOWN" "$T/out"'
probe_up active $U; run; run
check "evidence RECOVERED" '[ "$(recv)" = 9 ]'

# 8 bus down
probe_up active $U 30 0; run; run; run
check "bus DOWN at 3 checks" '[ "$(recv)" = 10 ] && last | grep -q "DOWN carbon bus"'
probe_up active $U; run; run

# 9 delivery outage: messages held, then replayed in order with a held note
touch "$T/hook/fail"
echo SSH_FAIL > "$T/probe"; run; run; run
probe_up active $U; run; run
check "outage keeps both messages pending" '[ "$(recv)" = 11 ] && grep -q "pending=2 delivery=failing" "$T/out"'
rm "$T/hook/fail"; run
N=$(recv)
check "replay delivers both" '[ "$N" = 13 ]'
F1=$(find "$T/hook" -name 'recv-*' | sort | sed -n 12p); F2=$(find "$T/hook" -name 'recv-*' | sort | sed -n 13p)
check "replay order DOWN then RECOVERED" 'grep -q "DOWN carbon host" "$F1" && grep -q "RECOVERED carbon host" "$F2"'
check "replay says delivered late" 'grep -q "delivered late" "$F1"'
check "mentions suppressed" 'grep -q "\"allowed_mentions\": {\"parse\": \\[\\]}" "$F1"'

# 10 no channel: unconfigured, held, never lost
mv "$T/webhook" "$T/webhook.off"
echo SSH_FAIL > "$T/probe"; run; run; run
check "unconfigured channel holds message" 'grep -q "pending=1 delivery=unconfigured: no webhook file" "$T/out" && [ "$(recv)" = 13 ]'
chmod 644 "$T/webhook.off"; mv "$T/webhook.off" "$T/webhook"; run
check "group-readable webhook file refused" 'grep -q "delivery=unconfigured: webhook file not a private" "$T/out"'
chmod 600 "$T/webhook"; run
check "held message delivered once channel exists" '[ "$(recv)" = 14 ]'

# 11 no secret in output or state
check "webhook url never written to state or output" '! grep -rq "127.0.0.1:$PORT/hook" "$T/state" "$T/out"'

echo "carbon-alive.test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
