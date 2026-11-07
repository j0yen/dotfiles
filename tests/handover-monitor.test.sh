#!/usr/bin/env bash
# handover-monitor.test.sh: one test, eight scenarios (A1150). Stubs for claude, hermes send, systemctl, seat-event.
# Proves: unchanged = zero model calls + zero sends; real progress; stalled; missed deadline; provider quota failure;
# duplicate/replay; missing/malformed evidence; notification failure then recovery. No network, no real model.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; MON="$HERE/.local/bin/handover-monitor.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; FAIL=1; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mkdir -p "$T/fb" "$T/bin" "$T/st"
cat > "$T/bin/claude" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$HM_T/claude.calls"; cat >/dev/null
case "$(cat "$HM_T/claude.mode" 2>/dev/null)" in
  quota) echo "Claude AI usage limit reached" >&2; echo '{"is_error":true,"result":"usage limit reached"}'; exit 1;;
  *) echo '{"is_error":false,"result":"{\"severity\":\"high\",\"summary\":\"triaged\",\"needs_hermes\":false}","usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.001}';;
esac
S
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ -e "$HM_T/send.fail" ] && exit 1
shift; shift; shift; m="$1"; echo "${m//$'\n'/ | }" >> "$HM_T/sent.log"; echo '{"ok":true}'
S
cat > "$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
u="${@: -1}"; s="$(cat "$HM_T/unit.$u" 2>/dev/null || echo inactive)"
printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\n' "$s" "$s"
S
cat > "$T/bin/seat-event.sh" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$HM_T/seat.log"
S
chmod +x "$T"/bin/*
export HM_T="$T"
cat > "$T/cfg.json" <<E2
{"target":"discord:TEST","tasks":[],"cutover":{"id":"model-free","timer":"t.timer"},"stale_minutes":30,"units":["ctl-dispatch.path"],
 "receipts":[{"id":"rcpt","path":"$T/fb/r.md","kind":"md"},{"id":"proof","path":"$T/fb/p.json","kind":"json"}],
 "progress_paths":["$T/fb/work-*"],
 "deadlines":[{"id":"cut","due":"2026-11-07T01:30:00-08:00","satisfied_by":"receipt:rcpt"}],
 "cron_file":"$T/jobs.json","cron_ids":["378a"],"hold_file":"$T/HOLD.json","ledger":"$T/trial.tsv"}
E2
echo '{"hold":true}' > "$T/HOLD.json"
echo '{"jobs":[{"id":"378a","last_status":"ok","last_error":null}]}' > "$T/jobs.json"
echo "header" > "$T/trial.tsv"; echo ok > "$T/fb/r.md"; echo '{"a":1}' > "$T/fb/p.json"; echo w1 > "$T/fb/work-1"
echo active > "$T/unit.ctl-dispatch.path"
run(){ # $1 = epoch offset minutes from base
  HM_CONFIG="$T/cfg.json" HM_STATE="$T/st" HM_CLAUDE="$T/bin/claude" HM_SEND="$T/bin/hermes" HM_SYSTEMCTL="$T/bin/systemctl" \
  HM_SEAT_EVENT="$T/bin/seat-event.sh" HM_NOW="$((BASE + $1*60))" python3 -I "$MON" run; }
calls(){ [ -f "$T/claude.calls" ] && wc -l < "$T/claude.calls" || echo 0; }
sends(){ [ -f "$T/sent.log" ] && wc -l < "$T/sent.log" || echo 0; }
BASE="$(date -d '2026-11-06T23:00:00-08:00' +%s)"

# 1 baseline: first run records snapshot; healthy evidence and no events beyond baseline
run 0 >/dev/null; c0=$(calls); s0=$(sends)
# 2 unchanged x3: zero model calls, zero sends
for m in 5 10 15; do run $m >/dev/null; done
chk "1 unchanged: zero model calls" '[ "$(calls)" = "$c0" ]'
chk "1 unchanged: zero sends" '[ "$(sends)" = "$s0" ]'
chk "1 unchanged: run log shows calls=0 x3" '[ "$(grep -c "calls=0" "$T/st/runs.log")" -ge 3 ]'
touch -d '2026-11-01' "$T/fb/work-1"; run 17 >/dev/null
chk "1 timestamp-only churn ignored" '[ "$(calls)" = "$c0" ] && [ "$(sends)" = "$s0" ]'
# 3 real progress: content change -> one haiku call, one send
echo w2 > "$T/fb/work-1"; run 20 >/dev/null
chk "2 progress: one haiku call" '[ "$(calls)" = "$((c0+1))" ]'
chk "2 progress: pinned haiku id" 'grep -q -- "--model claude-haiku-5-5" "$T/claude.calls"'
chk "2 progress: no codex/fable" '! grep -q -i -E "codex|fable|gpt" "$T/claude.calls"'
chk "2 progress: delivered once" '[ "$(sends)" = "$((s0+1))" ]'
# 4 replay: same facts, state wiped of snapshot only (restart replay) -> no duplicate
cp "$T/st/alerts.json" "$T/alerts.keep"; rm -f "$T/st/snapshot.json"; run 21 >/dev/null
chk "3 restart replay: no duplicate send" '[ "$(sends)" = "$((s0+1))" ]'
# 5 stalled: no progress change > 30 min while deadline unmet
rm "$T/fb/r.md"; run 25 >/dev/null; run 60 >/dev/null
chk "4 stalled alert present" 'grep -q "stalled" "$T/sent.log"'
n=$(sends); run 65 >/dev/null
chk "4 stalled deduped within repeat window" '[ "$(sends)" = "$n" ]'
# 6 missed deadline (base 23:00 + 150 min = 01:30; run at 155)
run 155 >/dev/null
chk "5 deadline missed alert" 'grep -q "deadline-missed" "$T/sent.log"'
chk "5 deadline alert notified ctl" 'grep -q "ctl" "$T/seat.log"'
# 7 acknowledgement suppresses repeats; unresolved escalates after repeat window
HM_CONFIG="$T/cfg.json" HM_STATE="$T/st" python3 -I "$MON" ack all >/dev/null
n=$(sends); run 400 >/dev/null
chk "6 acked alerts stay quiet" '[ "$(sends)" = "$n" ]'
# 8 missing/malformed evidence
echo ok > "$T/fb/r.md"; echo '{bad' > "$T/fb/p.json"; run 410 >/dev/null
chk "7 malformed evidence alert" 'grep -q "malformed-evidence" "$T/sent.log"'
rm "$T/fb/p.json"; run 415 >/dev/null
chk "7 missing evidence alert" 'grep -q "missing-evidence" "$T/sent.log"'
echo '{"a":1}' > "$T/fb/p.json"
# 9 provider quota failure: scheduler job error + haiku quota failure; alert still delivered, no fallback
echo '{"jobs":[{"id":"378a","last_status":"error","last_error":"HTTP 429 usage limit reached"}]}' > "$T/jobs.json"
echo quota > "$T/claude.mode"; n=$(sends); k=$(calls); run 420 >/dev/null
chk "8 provider failure alert delivered without model" '[ "$(sends)" -gt "$n" ] && grep -q "provider-failure" "$T/sent.log"'
chk "8 triage unavailable tagged" 'grep -q "triage-unavailable" "$T/sent.log"'
chk "8 no fallback model after quota" '[ "$(( $(calls) - k ))" -le 1 ] && ! grep -q -i -E "codex|fable|sonnet|opus" "$T/claude.calls"'
echo ok > "$T/claude.mode"
echo '{"jobs":[{"id":"378a","last_status":"ok","last_error":null}]}' > "$T/jobs.json"
# 10 notification failure then recovery
touch "$T/send.fail"; echo w3 > "$T/fb/work-1"; run 430 >/dev/null
chk "9 failed delivery spooled" 'ls "$T/st/outbox"/* >/dev/null 2>&1'
chk "9 failure surfaced locally to ctl" 'grep -q "notification" "$T/seat.log"'
rm "$T/send.fail"; run 435 >/dev/null
chk "9 recovery flushes spool" '! ls "$T/st/outbox"/* >/dev/null 2>&1 && grep -q "recovered" "$T/sent.log"'
# 11 missing config unit -> handled, no crash
rm "$T/unit.ctl-dispatch.path"; run 440 >/dev/null; chk "10 inactive unit reported" 'grep -q "unit-down" "$T/sent.log"'
[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
