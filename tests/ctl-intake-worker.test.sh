#!/usr/bin/env bash
# named test: scheduled worker binding on a PRIVATE ledger: ready -> verifying with one done effect; replay REUSED; unapproved/untrusted registry -> zero marker; never accepts
set -u
LIVE="${SWARM_DECIDE_LIVE:-$HOME/.local/share/swarm-decide/live/current}"
[ -f "$LIVE/wm_decide/intake_worker.py" ] || { echo "FAIL prerequisite: no installed intake_worker at $LIVE"; exit 1; }
S="$(mktemp -d)"; export WM_DECIDE_STATE="$S/state" SWARM_DECIDE_LIVE="$LIVE"; mkdir -p "$S/state" "$S/scratch"
W="$(dirname "$0")/../.local/bin/ctl-intake-worker.py"
E='{"source_event_id":"tg:w1","source_ref":"t","text":"x","received_at":"2026-11-10T06:40:00","request_type":"new","authorized_by":"hermes"}'
C='{"owner":"ctl","due":"2026-11-10T09:00","what":"t","check":"test -n x","depends":[]}'
wm-decide intake submit --envelope "$E" --change "$C" >/dev/null || { echo FAIL submit; exit 1; }
P="$(realpath "$S/scratch")/canary.txt"
printf '{"A1":{"recipe":"scratch-marker","rev":1,"approved_by":"hermes","target":"scratch-marker:%s","scratch_dir":"%s","marker":"canary.txt","content":"hi"}}' "$P" "$(realpath "$S/scratch")" > "$S/reg.json"; chmod 600 "$S/reg.json"
"$W" once --registry "$S/reg.json" > "$S/o1"; [ $? -eq 0 ] || { echo FAIL run1; cat "$S/o1"; exit 1; }
grep -q VERIFYING "$S/o1" || { echo FAIL not-verifying; cat "$S/o1"; exit 1; }
[ "$(cat "$P")" = hi ] || { echo FAIL marker; exit 1; }
"$W" once --registry "$S/reg.json" > "$S/o2"; grep -q '"SKIP"' "$S/o2" || grep -q REUSED "$S/o2" || { echo FAIL replay; cat "$S/o2"; exit 1; }
[ "$(sqlite3 "$S/state/decisions.sqlite" "select count(*) from effects where state='done'")" = 1 ] || { echo FAIL effects; exit 1; }
[ "$(sqlite3 "$S/state/decisions.sqlite" "select state from asks where ask_id='A1'")" = verifying ] || { echo FAIL accepted-by-worker; exit 1; }
chmod 666 "$S/reg.json"; "$W" once --registry "$S/reg.json" >/dev/null 2>&1; [ $? -eq 65 ] || { echo FAIL writable-registry; exit 1; }
chmod 600 "$S/reg.json"; sed -i 's/"hermes"/"mallory"/' "$S/reg.json"; rm -f "$P"
E2="${E//tg:w1/tg:w2}"; wm-decide intake submit --envelope "$E2" --change "$C" >/dev/null
sed -i 's/"A1"/"A2"/' "$S/reg.json"; "$W" once --registry "$S/reg.json" >/dev/null; [ $? -eq 70 ] || { echo FAIL untrusted-approver; exit 1; }
[ ! -e "$P" ] || { echo FAIL marker-written-untrusted; exit 1; }
echo PASS ctl-intake-worker
