#!/usr/bin/env bash
# W4 wiring (ledger ask A1346): the canonical-mode Stop in owed-now.sh calls `followup-eval.py suggestion`, so an unowned suggestion in a final message is a typed
# suggestion-only obligation carried through the existing outbox + deliverer once; an owned or factual message records nothing; WM_DIRECTOR=hermes never blocks.
# HOME sandbox, spy deliverer and stub ledger; no real ledger, no send.
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
H="$here/.claude/hooks/owed-now.sh"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
mkdir -p "$W/home"
printf '#!/bin/bash\necho "[]"\n' >"$W/asks.sh"; printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/dec.sh"
printf '#!/bin/bash\ncat >/dev/null; echo x >>"%s/deliver.log"\n' "$W" >"$W/deliver.sh"; chmod +x "$W"/*.sh
export HOME="$W/home" WM_ASKS_BIN="$W/asks.sh" WM_DECIDE_BIN="$W/dec.sh" FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD="$W/deliver.sh" WM_SEAT=ctl OWED_NOW_SOURCE=asks FOLLOWUP_NOW=2026-11-08T15:00
unset WM_DIRECTOR
stop(){ jq -nc --arg m "$1" --arg s "${2:-s1}" '{hook_event_name:"Stop",session_id:$s,last_assistant_message:$m}' | bash "$H" hook; }
rows(){ [ -f "$FOLLOWUP_OUTBOX" ] && jq -s 'map(select(.kind=="suggestion-only"))|length' "$FOLLOWUP_OUTBOX" || echo 0; }
dl(){ [ -f "$W/deliver.log" ] && wc -l <"$W/deliver.log" | tr -d ' ' || echo 0; }
BAD='I recommend moving the retry guard into the shared hook, and the next step would be to add a regression test.'
out="$(stop "$BAD")"
ck "unowned suggestion records one suggestion-only obligation" "$(rows)" 1
ck "it is delivered once through the existing deliverer" "$(dl)" 1
ck "recording does not block the turn" "$out" ""
stop "$BAD" >/dev/null
ck "repeat Stop dedupes (still one row)" "$(rows)" 1
ck "repeat Stop does not redeliver" "$(dl)" 1
stop "$BAD Also add a lint." >/dev/null
ck "a changed message is a new obligation" "$(rows)" 2
rm -rf "$W/st" "$W/deliver.log"
stop "$BAD owner: ctl, due 2026-11-08T18:00" >/dev/null
ck "owned suggestion (owner + due in message) records nothing" "$(rows)" 0
stop "The hook ran at 10:41 and exited 0; nothing else changed." >/dev/null
ck "factual message records nothing" "$(rows)" 0
ck "nothing delivered for owned/factual" "$(dl)" 0
out="$(WM_DIRECTOR=hermes stop "$BAD" s2)"
ck "WM_DIRECTOR=hermes records the obligation" "$(rows)" 1
ck "WM_DIRECTOR=hermes never blocks" "$(jq -e '.decision=="block"' <<<"${out:-null}" >/dev/null 2>&1 && echo block || echo pass)" pass
ck "static caller check: owed-now.sh calls followup-eval.py suggestion" "$(grep -c 'python3 -I "\$sev" suggestion' "$H")" 1
echo "pass=$p fail=$f"; [ "$f" = 0 ]
