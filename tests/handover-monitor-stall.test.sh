#!/usr/bin/env bash
# handover-monitor-stall.test.sh: stall-prevention + cutover truth (A1150). Stubs only; no network, no model.
# Scenarios: live-but-idle executor; unrelated progress; unchanged receipt; genuine active worker;
# failed alert delivery then recovery; ack without resumed work; receipt-is-not-cutover.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; MON="$HERE/.local/bin/handover-monitor.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; FAIL=1; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mkdir -p "$T/fb" "$T/bin" "$T/st" "$T/code" "$T/other"
cat > "$T/bin/claude" <<'S'
#!/usr/bin/env bash
cat >/dev/null; echo '{"is_error":false,"result":"{\"severity\":\"high\",\"summary\":\"t\",\"needs_hermes\":false}","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
S
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ -e "$HM_T/send.fail" ] && exit 1
shift; shift; shift; echo "${1//$'\n'/ | }" >> "$HM_T/sent.log"; echo '{"ok":true}'
S
cat > "$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
u="${@: -1}"; s="$(cat "$HM_T/unit.$u" 2>/dev/null || echo inactive)"
printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\n' "$s" "$s"
S
cat > "$T/bin/seat-event.sh" <<'S'
#!/usr/bin/env bash
[ -e "$HM_T/seat.fail" ] && exit 1
echo "$*" >> "$HM_T/seat.log"
S
chmod +x "$T/bin/"*
export HM_T="$T"
git -C "$T/code" init -q . && echo a > "$T/code/a.py" && git -C "$T/code" add . && git -C "$T/code" -c user.email=t@t -c user.name=t commit -qm init
echo r0 > "$T/fb/r.md"
cat > "$T/cfg.json" <<E2
{"target":"discord:TEST","units":[],"receipts":[],"progress_paths":[],"deadlines":[],
 "cron_file":"$T/jobs.json","cron_ids":[],"hold_file":"$T/HOLD.json","ledger":"$T/trial.tsv",
 "cutover":{"id":"model-free","timer":"mf.timer"},
 "tasks":[{"id":"tk","title":"test task","receipt":"$T/fb/r.md","evidence_paths":["$T/code/*.py"],"git_dir":"$T/code",
   "worker_stream_globs":["$T/fb/worker-*.jsonl"],"worker_units":["wk.service"],"done_requires":"cutover:model-free"}]}
E2
echo '{}' > "$T/jobs.json"; echo '{}' > "$T/HOLD.json"; echo h > "$T/trial.tsv"
BASE="$(date -d '2026-11-07T00:00:00-08:00' +%s)"
run(){ HM_CONFIG="$T/cfg.json" HM_STATE="$T/st" HM_CLAUDE="$T/bin/claude" HM_SEND="$T/bin/hermes" HM_SYSTEMCTL="$T/bin/systemctl" \
  HM_SEAT_EVENT="$T/bin/seat-event.sh" HM_NOW="$((BASE + $1*60))" HM_TRIGGER="${TRIG:-manual}" python3 -I "$MON" run; }
mon(){ HM_CONFIG="$T/cfg.json" HM_STATE="$T/st" HM_NOW="$((BASE + $1*60))" python3 -I "$MON" "${@:2}"; }
stalls_sent(){ grep -c "STALL tk" "$T/sent.log" 2>/dev/null || echo 0; }
seat_n(){ grep -c "STALL tk" "$T/seat.log" 2>/dev/null || echo 0; }

run 0 >/dev/null; run 5 >/dev/null
chk "no stall before 10 min" '[ "$(stalls_sent)" = 0 ]'
# live-but-idle executor: unit active but no fresh task stream, no substantive change
echo active > "$T/unit.wk.service"; touch -d "@$((BASE - 3600))" "$T/fb/worker-1.jsonl"
run 10 >/dev/null
chk "idle executor: stall event file" 'ls "$T/st/stalls"/tk-*.json >/dev/null 2>&1'
chk "idle executor: ctl seat notified" '[ "$(seat_n)" -ge 1 ] && grep -q "^ctl .*STALL tk" "$T/seat.log"'
chk "idle executor: hermes seat notified" 'grep -q "^hermes .*STALL tk" "$T/seat.log"'
chk "idle executor: discord delivered" '[ "$(stalls_sent)" -ge 1 ]'
chk "live unit alone does not clear stall" 'grep -q "STALL tk" "$T/sent.log"'
# unrelated progress (other file content + mtime churn on receipt) keeps the stall
echo x > "$T/other/unrelated.txt"; touch "$T/fb/r.md"; n=$(seat_n)
run 12 >/dev/null
chk "unrelated progress / touched receipt: stall stays open" 'python3 -c "import json;m=json.load(open(\"$T/st/meta.json\"));assert m[\"stalls\"][\"tk\"][\"stalled\"]"'
chk "no re-nag before 5 min" '[ "$(seat_n)" = "$n" ]'
run 15 >/dev/null
chk "escalation at 5 min without ack" 'grep -q "ESCALATED" "$T/sent.log"'
# ack without resumed work does not clear, and re-notifies after the window
mon 16 stall-ack tk --action "looking" >/dev/null; n=$(stalls_sent)
run 18 >/dev/null; run 24 >/dev/null
chk "ack without work: quiet during ack window" '[ "$(stalls_sent)" = "$n" ]'
chk "ack without work: stall not cleared" 'python3 -c "import json;m=json.load(open(\"$T/st/meta.json\"));assert m[\"stalls\"][\"tk\"][\"stalled\"]"'
run 27 >/dev/null
chk "ack without work: re-notifies after window" '[ "$(stalls_sent)" -gt "$n" ]'
# substantive evidence (code edit) clears
echo b >> "$T/code/a.py"; run 30 >/dev/null
chk "code edit clears stall" 'grep -q "CLEARED" "$T/st/runs.log"'
# genuine active worker: unit active + fresh stream => no false idle
n=$(stalls_sent); touch -d "@$((BASE + 45*60))" "$T/fb/worker-1.jsonl"
run 50 >/dev/null
chk "active worker: no false-idle stall" '[ "$(stalls_sent)" = "$n" ] && ! python3 -c "import json;m=json.load(open(\"$T/st/meta.json\"));assert m[\"stalls\"][\"tk\"].get(\"stalled\")"'
# failed delivery then recovery
echo inactive > "$T/unit.wk.service"; touch "$T/send.fail" "$T/seat.fail"; n=$(stalls_sent)
run 70 >/dev/null
chk "failed delivery: recorded incomplete" 'grep -q "delivery incomplete" "$T/st/runs.log"'
rm -f "$T/send.fail" "$T/seat.fail"; run 71 >/dev/null
chk "recovery: stall re-sent next run" '[ "$(stalls_sent)" -gt "$n" ]'
# receipt alone is not cutover
cat "$T/fb/r.md" >/dev/null
chk "receipt exists, no timer: not cutover" '! python3 -I -c "
import importlib.util as u,os
s=u.spec_from_file_location(\"m\",\"$MON\");m=u.module_from_spec(s);s.loader.exec_module(m)
import json;c=json.load(open(\"$T/cfg.json\"))
os.environ[\"HM_STATE\"]=\"$T/st\";os.environ[\"HM_SYSTEMCTL\"]=\"$T/bin/systemctl\"
assert m.cutover_facts(c,None)[\"ok\"]"'
# timer active + scheduled run + real delivery => cutover ok (stub delivery counted only under HM_TEST_CUTOVER)
echo active > "$T/unit.mf.timer"; TRIG=timer run 80 >/dev/null
chk "timer + scheduled run + delivery (test-tagged) not cutover without allow" '! HM_TEST_CUTOVER= python3 -I -c "
import importlib.util as u,os
s=u.spec_from_file_location(\"m\",\"$MON\");m=u.module_from_spec(s);s.loader.exec_module(m)
import json;c=json.load(open(\"$T/cfg.json\"))
os.environ[\"HM_STATE\"]=\"$T/st\";os.environ[\"HM_SYSTEMCTL\"]=\"$T/bin/systemctl\"
assert m.cutover_facts(c,None)[\"ok\"]"'
chk "timer + scheduled run + delivery: cutover ok" 'HM_TEST_CUTOVER=1 python3 -I -c "
import importlib.util as u,os
s=u.spec_from_file_location(\"m\",\"$MON\");m=u.module_from_spec(s);s.loader.exec_module(m)
import json;c=json.load(open(\"$T/cfg.json\"))
os.environ[\"HM_STATE\"]=\"$T/st\";os.environ[\"HM_SYSTEMCTL\"]=\"$T/bin/systemctl\"
assert m.cutover_facts(c,None)[\"ok\"]"'
[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
