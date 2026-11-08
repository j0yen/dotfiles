#!/usr/bin/env bash
# A1346 effective owed-now: canonical-ledger Stop = one fingerprint once, a changed rev once, a ledger outage and a missing evaluator visible, no recital.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
H="$here/.claude/hooks/owed-now.sh"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
printf '#!/bin/bash\ncat "$FX_ASKS"\n' >"$W/asks.sh"; printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/dec.sh"; chmod +x "$W"/*.sh
export FX_ASKS="$W/rows.json" WM_ASKS_BIN="$W/asks.sh" WM_DECIDE_BIN="$W/dec.sh" FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD=true WM_SEAT=ctl OWED_NOW_SOURCE=asks FOLLOWUP_NOW=2026-11-08T15:00
unset WM_DIRECTOR
J='{"hook_event_name":"Stop","session_id":"s1"}'
blk(){ [ -n "$(printf '%s' "$J" | bash "$H" hook)" ] && echo block || echo pass; }
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-08T10:00","what":"x"}]' >"$FX_ASKS"
ck "first sighting blocks" "$(blk)" block
ck "unchanged fingerprint passes (stop 2)" "$(blk)" pass
ck "unchanged fingerprint passes (stop 3)" "$(blk)" pass
echo '[{"ask_id":"T1","rev":2,"owner":"ctl","due":"2026-11-08T10:00","what":"x"}]' >"$FX_ASKS"
ck "changed rev blocks once" "$(blk)" block
ck "changed rev then passes" "$(blk)" pass
printf '#!/bin/bash\nexit 7\n' >"$W/asks.sh"
ck "ledger outage visible in lint" "$(bash "$H" lint --seat ctl | head -1 | cut -f1)" LEDGER
ck "ledger outage: lint never reads the retired TSV" "$(OPEN_ASKS=/nonexistent bash "$H" lint --seat ctl | head -1 | cut -f1)" LEDGER
mkdir -p "$W/t/.claude/hooks" "$W/t/.local/bin" "$W/home"; cp "$H" "$here/.claude/hooks/followup-lib.sh" "$W/t/.claude/hooks/"
J='{"hook_event_name":"Stop","session_id":"s9"}'; H="$W/t/.claude/hooks/owed-now.sh"; export HOME="$W/home" FOLLOWUP_STATE_DIR="$W/st2"
ck "missing evaluator blocks visibly once" "$(blk)" block
ck "missing evaluator does not recite" "$(blk)" pass
echo "pass=$p fail=$f"; [ "$f" = 0 ]
