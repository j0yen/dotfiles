#!/usr/bin/env bash
# pkg2-critpath.test.sh (A1296 package 2, hook critical-path reduction, Joe 11-13): controls for the advisory ops hooks. Hermetic: wm-asks / wm-decide are PATH stubs,
# HOME is a temp dir, the real ledger is never read. Usage: pkg2-critpath.test.sh [repo-root]  (point it at a base clone to see the RED side; a blocked hook is
# bounded by `timeout` inside the test, never by the hook).
# Controls: slow ledger, locked store, absent cache, malformed cache, stale cache, slow wiki, cosmetic failure (ledger append); guard negatives (the required
# guards still REFUSE: unauthorized, wrong actor, wrong model, duplicate executor).
set -u
R="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
W="$(mktemp -d "${TMPDIR:-/tmp}/crit.XXXXXX")"; trap 'pkill -f "$W" 2>/dev/null; rm -rf "$W"' EXIT
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
export HOME="$W/home"; mkdir -p "$HOME" "$W/bin"; export TMPDIR="$W"
unset WM_DIRECTOR WM_HELPER FOLLOWUP_TRACE OWED_NOW_SOURCE OPEN_ASKS WM_SEAT
export PATH="$W/bin:$PATH" WM_ASKS_BIN="$W/bin/wm-asks" WM_DECIDE_BIN="$W/bin/wm-decide" ASIDE_WM_ASKS_BIN="$W/bin/wm-asks"
export FOLLOWUP_STATE_DIR="$W/st" FOLLOWUP_OUTBOX="$W/st/outbox.jsonl" FOLLOWUP_DELIVER_CMD=true OWED_NOW_STATE="$W/owed" ASIDE_STOP_LOG="$W/fires.log" SEATS_TABLE="$W/seats.tsv"
export FOLLOWUP_NOW=2026-11-13T12:00
printf '#!/bin/bash\necho "{\\"owed\\":0,\\"overdue\\":0,\\"escalated\\":0,\\"ids\\":[]}"\n' >"$W/bin/wm-decide"
# wm-asks stub: $W/delay = seconds to sleep before answering (a slow/hung ledger), then the rows
cat >"$W/bin/wm-asks" <<'STUB'
#!/bin/bash
echo x >>"@W@/calls.log"; d="$(cat "@W@/delay" 2>/dev/null)"; [ -z "$d" ] || sleep "$d"
cat "@W@/rows.json"
STUB
sed -i "s#@W@#$W#g" "$W/bin/wm-asks"; chmod +x "$W/bin/"*
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"
OWED="$R/.claude/hooks/owed-now.sh"
now(){ date +%s.%N; }
UPSAS(){ printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "${2:-s1}" | WM_SEAT="$1" timeout 40 bash "$OWED" hook 2>/dev/null; }
UPS(){ UPSAS ctl "${1:-s1}"; }
STOPAS(){ jq -nc --arg s "${2:-s1}" --arg m "${3:-}" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,last_assistant_message:$m}' | WM_SEAT="$1" timeout 40 bash "$OWED" hook 2>/dev/null; }
within(){ awk -v a="$1" -v b="$2" -v lim="$3" 'BEGIN{print ((b-a)<=lim)?"ok":"slow " (b-a)}'; }
fresh(){ pkill -f "$OWED refresh" 2>/dev/null; rm -rf "$W/owed" "$W/st"; : >"$W/delay"; }   # a detached producer of an earlier control must not write into the next control's cache
wait_cache(){ local i; for i in $(seq 100); do [ -s "$W/owed/ctl.ups-cache.json" ] && return 0; sleep 0.1; done; return 1; }

# --- C1 slow ledger, cold cache: the prompt returns at once with a truthful UNKNOWN marker (the ledger sleeps 25 s)
fresh; echo 25 >"$W/delay"; t0=$(now); o="$(UPS)"; t1=$(now)
ck "C1 slow ledger + absent cache: prompt returns within 4 s" "$(within "$t0" "$t1" 4)" ok
ck "C1 slow ledger + absent cache: UNKNOWN marker, says NOT none owed" "$(grep -c 'UNKNOWN' <<<"$o")/$(grep -c 'NOT \\"none owed\\"\|NOT "none owed"' <<<"$o")" "1/1"
# --- C2 slow ledger, warm cache: cached rows are visible at once while a refresh hangs on the ledger
fresh; : >"$W/delay"; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1
echo 25 >"$W/delay"; export OWED_CACHE_REFRESH_S=0
t0=$(now); o="$(UPS)"; t1=$(now)
ck "C2 slow ledger + warm cache: prompt returns within 4 s" "$(within "$t0" "$t1" 4)" ok
ck "C2 slow ledger + warm cache: the cached owed row T1 is visible" "$(grep -c 'T1' <<<"$o")" 1
unset OWED_CACHE_REFRESH_S
# --- C3 absent cache, healthy ledger: UNKNOWN once, then the real rows after the producer ran, then quiet (dedupe), nothing replayed
fresh; : >"$W/delay"; o1="$(UPS)"; wait_cache; o2="$(UPS)"; o3="$(UPS)"
ck "C3 absent cache: first prompt says UNKNOWN" "$(grep -c UNKNOWN <<<"$o1")" 1
ck "C3 after the background producer: the owed row T1 is recited" "$(grep -c 'T1' <<<"$o2")" 1
ck "C3 unchanged fingerprint: next prompt quiet (no replay)" "${o3:-quiet}" quiet
# a second prompt of the same session with the cache still absent carries a SHORT UNKNOWN line (rv6 F6-2 contract change: silence after the first prompt read as "nothing owed")
fresh; rm -f "$W/rows.json.hold"; mv "$W/rows.json" "$W/rows.hold"; : >"$W/rows.json"; echo 25 >"$W/delay"; o1="$(UPS s9)"; o="$(UPS s9)"; mv "$W/rows.hold" "$W/rows.json"; : >"$W/delay"
ck "C3 persistent absent cache: every later prompt still carries a short UNKNOWN line, never silence and never the long block again (F6-2: silence read as none owed)" "$(grep -c UNKNOWN <<<"$o")/$([ "$(wc -c <<<"$o")" -lt "$(wc -c <<<"$o1")" ] && echo shorter)" "1/shorter"
# --- C4 malformed cache: garbage, wrong seat, symlink, empty file, wrong schema => truthful malformed marker, fast, rc 0
fresh; mkdir -p "$W/owed"; echo 25 >"$W/delay"
for kind in garbage wrongseat future symlink empty schema; do
  rm -rf "$W/owed"; mkdir -p "$W/owed"; c="$W/owed/ctl.ups-cache.json"
  case "$kind" in
    garbage) printf '{not json' >"$c" ;;
    wrongseat) printf '{"v":1,"seat":"rb","ts":%s,"clean":false,"rows":"OVERDUE\\tT1\\tx"}' "$(date +%s)" >"$c" ;;
    future) printf '{"v":1,"seat":"ctl","ts":%s,"clean":false,"rows":"OVERDUE\\tT1\\tx"}' "$(( $(date +%s) + 3600 ))" >"$c" ;;
    symlink) printf '{"v":1,"seat":"ctl","ts":%s,"clean":true,"rows":""}' "$(date +%s)" >"$W/real.json"; ln -s "$W/real.json" "$c" ;;
    empty) : >"$c" ;;
    schema) printf '{"v":1,"seat":"ctl","ts":"yesterday","clean":true,"rows":""}' >"$c" ;;
  esac
  t0=$(now); o="$(UPS)"; rc=$?; t1=$(now)
  ck "C4 malformed cache ($kind): fast, rc 0, UNKNOWN marker naming malformed" "$(within "$t0" "$t1" 4)/$rc/$(grep -c 'UNKNOWN.*malformed' <<<"$o")" "ok/0/1"
done
# --- C5 stale cache: rows still visible, marked STALE, fast while the ledger hangs
fresh; mkdir -p "$W/owed"; printf '{"v":1,"seat":"ctl","ts":%s,"clean":false,"rows":"OVERDUE\\tT1\\tdue=2026-11-12T09:00\\t[ready] x"}' "$(( $(date +%s) - 7200 ))" >"$W/owed/ctl.ups-cache.json"; echo 25 >"$W/delay"
t0=$(now); o="$(UPS)"; t1=$(now)
ck "C5 stale cache: fast; row visible and marked STALE" "$(within "$t0" "$t1" 4)/$(grep -c 'T1' <<<"$o")/$(grep -c STALE <<<"$o")" "ok/1/1"
# --- C6 locked store: the fingerprint store lock is held by another process; the prompt path does not touch it
fresh; : >"$W/delay"; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; mkdir -p "$W/st"
( flock -x "$W/st/lock" sleep 12 ) & lk=$!; sleep 0.3
t0=$(now); o="$(UPS)"; t1=$(now); kill $lk 2>/dev/null; wait $lk 2>/dev/null
ck "C6 locked store: prompt returns within 4 s with the cached row (no-regression control: the prompt path never took this lock)" "$(within "$t0" "$t1" 4)/$(grep -c 'T1' <<<"$o")" "ok/1"
# --- C7 fingerprint/dedupe through the cache: changed rows recite once, unchanged stay quiet
fresh; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; a="$(UPS)"; b="$(UPS)"
echo '[{"ask_id":"T1","rev":2,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; c="$(UPS)"; d="$(UPS)"
ck "C7 cache path keeps fingerprint semantics: emit, quiet, emit (changed rev), quiet" "$([ -n "$a" ] && echo e || echo q)$([ -n "$b" ] && echo e || echo q)$([ -n "$c" ] && echo e || echo q)$([ -n "$d" ] && echo e || echo q)" eqeq
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"
# --- C8 Stop is still a synchronous required guard: first sighting of an owed fingerprint blocks once, then passes; the same ledger outage fails open
fresh; : >"$W/delay"
S1="$(printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false}' | WM_SEAT=ctl timeout 40 bash "$OWED" hook 2>/dev/null)"; S2="$(printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false}' | WM_SEAT=ctl timeout 40 bash "$OWED" hook 2>/dev/null)"
ck "C8 Stop: first sighting blocks, unchanged passes" "$(jq -r '.decision // "none"' <<<"$S1" 2>/dev/null)/${S2:-pass}" "block/pass"
# --- C9 the producer timer script refreshes every seat in seats.tsv
fresh; printf 'ctl\t1\tsid-ctl\n' >"$W/seats.tsv"; bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1
ck "C9 outbox-replay timer script writes the seat cache (existing durable producer, no new scheduler)" "$([ -s "$W/owed/ctl.ups-cache.json" ] && jq -e '.v==1 and .seat=="ctl"' "$W/owed/ctl.ups-cache.json" >/dev/null 2>&1 && echo ok)" ok
# C9 alias (rv6 F6-1): a seats.tsv row named ops is refreshed under the one key (ctl.ups-cache.json), never ops.ups-cache.json
fresh; printf 'ops\t1\tsid-ops\n' >"$W/seats.tsv"; bash "$R/.local/bin/followup-outbox-replay.sh" >/dev/null 2>&1
ck "C9 timer script, seat row named ops: the cache lands under ctl (the reader's key), none under ops" "$([ -s "$W/owed/ctl.ups-cache.json" ] && [ ! -e "$W/owed/ops.ups-cache.json" ] && echo ok)" ok
# --- C10 evaluator: one liveness probe per distinct worker handle per run
cat >"$W/bin/alive-count" <<'ALV'
#!/bin/bash
echo "$1" >>"@W@/alive.log"; exit 0
ALV
sed -i "s#@W@#$W#g" "$W/bin/alive-count"; chmod +x "$W/bin/alive-count"; : >"$W/alive.log"
echo '[{"ask_id":"K1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"a","claim":"w1@2026-11-13T08:00","claim_session":"w1"},{"ask_id":"K2","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"b","claim":"w1@2026-11-13T08:00","claim_session":"w1"},{"ask_id":"K3","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"c","claim":"w2@2026-11-13T08:00","claim_session":"w2"}]' >"$W/rows.json"
FOLLOWUP_WORKER_ALIVE_CMD="$W/bin/alive-count" python3 -I "$R/.local/bin/followup-eval.py" eval --seat ctl >/dev/null 2>&1
ck "C10 evaluator probes each distinct worker once (3 claims, 2 workers)" "$(wc -l <"$W/alive.log" | tr -d ' ')" 2
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"

# --- C11 seat alias (rv6 F6-1): the prompt hook driven as seat ops reads the same cache key the producer writes (ctl); the ledger row is ctl-owned
fresh; : >"$W/delay"; o1="$(UPSAS ops sx)"; wait_cache; o2="$(UPSAS ops sx)"
ck "C11 seat ops (alias of ctl): after the producer ran, the prompt recites the ctl-owned row T1 (cache key shared, not ops.ups-cache.json)" "$(grep -c 'T1' <<<"$o2")/$([ -e "$W/owed/ops.ups-cache.json" ] && echo split || echo one-key)" "1/one-key"
ck "C11 one alias table: owed-now.sh maps ops->ctl in exactly one place" "$(grep -c '^seat_alias()' "$OWED")/$(grep -cE '(!=|==) ops \]' "$OWED")" "1/0"
# --- C12 persistent unknown / stale never reads as none owed (rv6 F6-2), compaction (same session id, state file lost) included
fresh; mv "$W/rows.json" "$W/rows.hold"; : >"$W/rows.json"; echo 25 >"$W/delay"
a="$(UPS sm)"; b="$(UPS sm)"; rm -f "$W/owed/sm.unk"; c="$(UPS sm)"; d="$(UPS sm)"
mv "$W/rows.hold" "$W/rows.json"; : >"$W/delay"
ck "C12 absent cache, 4 prompts of one session (state file lost between 2 and 3 = compaction): every prompt carries UNKNOWN and NOT none owed" "$(for x in "$a" "$b" "$c" "$d"; do grep -c 'UNKNOWN' <<<"$x"; done | tr '\n' ' ')" "1 1 1 1 "
ck "C12 the repeated UNKNOWN is the short line" "$([ "$(wc -c <<<"$b")" -lt 260 ] && echo short)" short
fresh; mkdir -p "$W/owed"; echo 25 >"$W/delay"; printf '{not json' >"$W/owed/ctl.ups-cache.json"
a="$(UPS sy)"; b="$(UPS sy)"; c="$(UPS sy)"
ck "C12 malformed cache persists: every prompt carries UNKNOWN naming malformed" "$(for x in "$a" "$b" "$c"; do grep -c 'UNKNOWN.*malformed' <<<"$x"; done | tr '\n' ' ')" "1 1 1 "
fresh; mkdir -p "$W/owed"; echo 25 >"$W/delay"; printf '{"v":1,"seat":"ctl","ts":%s,"clean":true,"rows":""}' "$(( $(date +%s) - 7200 ))" >"$W/owed/ctl.ups-cache.json"
a="$(UPS sz)"; b="$(UPS sz)"; c="$(UPS sz)"
ck "C12 stale-and-clean cache: every prompt says STALE, none reads as quiet" "$(for x in "$a" "$b" "$c"; do grep -c 'STALE' <<<"$x"; done | tr '\n' ' ')" "1 1 1 "
fresh; mkdir -p "$W/owed"; echo 25 >"$W/delay"; printf '{"v":1,"seat":"ctl","ts":%s,"clean":false,"rows":"OVERDUE\\tT1\\tdue=2026-11-12T09:00\\t[ready] x"}' "$(( $(date +%s) - 7200 ))" >"$W/owed/ctl.ups-cache.json"
a="$(UPS sw)"; b="$(UPS sw)"; c="$(UPS sw)"
ck "C12 stale cache with rows: row recited once, then every later prompt still carries a short STALE line" "$(grep -c T1 <<<"$a")/$(for x in "$b" "$c"; do grep -c 'STALE' <<<"$x"; done | tr '\n' ' ')" "1/1 1 "
: >"$W/delay"
# --- C13 locked store on the Stop path (rv6 F6-3, option a): the Stop hook takes the fingerprint-store lock only without waiting; contention is a truthful marker
# nothing lost (the fingerprint is not recorded, the next Stop escalates it; the unowned suggestion is written by a detached blocking retry) and nothing delivered twice
cat >"$W/bin/deliver" <<'DLV'
#!/bin/bash
cat >/dev/null; echo x >>"@W@/deliver.log"
DLV
sed -i "s#@W@#$W#g" "$W/bin/deliver"; chmod +x "$W/bin/deliver"
fresh; : >"$W/delay"; : >"$W/deliver.log"; mkdir -p "$W/st"; export FOLLOWUP_DELIVER_CMD="$W/bin/deliver"
echo '{"id":"PRE","rev":1,"disposition":"ready","kind":"overdue","owner":"ctl","fp":"PRE|1|ready|overdue","seat":"ctl","ts":"2026-11-13T11:00:00+00:00","delivered":false}' >"$W/st/outbox.jsonl"   # an undelivered entry: the in-hook replay would have to wait on the lock
WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1
( flock -x "$W/st/lock" sleep 9 ) & lk=$!; sleep 0.4
t0=$(now); S1="$(STOPAS ctl s13 'I recommend moving the cache to a new store.')"; t1=$(now)
ck "C13 Stop while the store lock is held 9 s: returns within 4 s (no wait on the lock)" "$(within "$t0" "$t1" 4)" ok
ck "C13 Stop under contention does not decide a block it could not record" "${S1:-pass}" pass
o="$(UPSAS ctl s13)"
ck "C13 the next prompt says the Stop check was skipped and new obligations were NOT checked" "$(grep -c 'STOP CHECK SKIPPED' <<<"$o")/$(grep -c 'NOT checked' <<<"$o")" "1/1"
wait $lk 2>/dev/null
for i in $(seq 60); do [ "$(grep -c suggestion-only "$W/st/outbox.jsonl" 2>/dev/null)" = 1 ] && break; sleep 0.2; done
ck "C13 the contended suggestion is written once by the detached retry (not lost)" "$(grep -c suggestion-only "$W/st/outbox.jsonl" 2>/dev/null)" 1
S2="$(STOPAS ctl s13 '')"; S3="$(STOPAS ctl s13 '')"
ck "C13 nothing lost: the next Stop escalates T1 once, the one after passes" "$(jq -r '.decision // "none"' <<<"$S2" 2>/dev/null)/${S3:-pass}" "block/pass"
o="$(UPSAS ctl s13)"
ck "C13 a Stop that completed clears the skipped-check marker" "$(grep -c 'STOP CHECK SKIPPED' <<<"$o")" 0
sleep 1
ck "C13 nothing replayed twice, the seeded entry delivered by the durable consumer: one delivery per outbox entry (PRE, suggestion, T1)" "$(wc -l <"$W/deliver.log" | tr -d ' ')/$(wc -l <"$W/st/outbox.jsonl" | tr -d ' ')" "3/3"
export FOLLOWUP_DELIVER_CMD=true
# --- L1 one refresher per seat (rv6 F6-4): concurrent refreshes of one seat cost the ledger the calls of one, every time. The lock is an exclusive create (noclobber), not mkdir:
# uutils mkdir lets two racing callers both succeed, so the race is repeated 8 times (a mkdir lock fails about 4 of 10 rounds on this host class)
pkill -f "$OWED refresh" 2>/dev/null; sleep 0.5   # detached producers of the earlier controls must not add ledger calls to this count
fresh; echo 1 >"$W/delay"; : >"$W/calls.log"
WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; n1="$(wc -l <"$W/calls.log" | tr -d ' ')"
bad=0; for i in 1 2 3 4 5 6 7 8; do
  rm -rf "$W/owed"; : >"$W/calls.log"
  ( WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1 ) & ( WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1 ) & wait
  [ "$(wc -l <"$W/calls.log" | tr -d ' ')" = "$n1" ] || bad=$((bad+1))
done
ck "L1 two concurrent refreshes of one seat query the ledger as often as one, in 8 of 8 rounds (one refresher per seat)" "$bad" 0
: >"$W/delay"; rm -rf "$W/owed"
ck "L1 the lock is released after a refresh (a later refresh runs)" "$(WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; [ -s "$W/owed/ctl.ups-cache.json" ] && [ ! -e "$W/owed/ctl.refresh.lock" ] && echo ok)" ok
ck "L1 a stale lock (older than 5 min) is replaced, a fresh one is respected" "$(rm -rf "$W/owed"; mkdir -p "$W/owed"; : >"$W/owed/ctl.refresh.lock"; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; a=$([ -s "$W/owed/ctl.ups-cache.json" ] && echo ran || echo skipped); rm -rf "$W/owed"; mkdir -p "$W/owed"; : >"$W/owed/ctl.refresh.lock"; touch -d '10 min ago' "$W/owed/ctl.refresh.lock"; WM_SEAT=ctl bash "$OWED" refresh --seat ctl >/dev/null 2>&1; echo "$a/$([ -s "$W/owed/ctl.ups-cache.json" ] && echo ran || echo skipped)")" "skipped/ran"
ck "L1 neither lock is a mkdir (uutils mkdir is not exclusive under a race): owed-now.sh and the Summa index builder" "$(grep -c 'mkdir "\$lock"' "$OWED" "$R/.claude/scripts/summa-lookup-inject.sh" | tr '\n' ' ' | sed 's#[^ ]*/##g')" "owed-now.sh:0 summa-lookup-inject.sh:0 "

# --- Summa lookup (UserPromptSubmit, installed timeout 20 s): fixture vault, cached index, no wiki walk in the steady state
V="$W/vault"; mkdir -p "$V/wiki/answers" "$V/wiki/entities"
for i in $(seq 1 120); do printf -- '---\nquestion: "How does widget%d relate to gadget%d?"\n---\nbody\n' "$i" "$((i % 7))" >"$V/wiki/answers/2026-11-13-answer-$i.md"; done
: >"$V/wiki/entities/Summa.md"; : >"$V/wiki/entities/Fleetbox.md"
SUMMA="$R/.claude/scripts/summa-lookup-inject.sh"
export SUMMA_VAULT="$V" SUMMA_LEDGER="$W/lookups.jsonl" SUMMA_CACHE_DIR="$W/scache"
PR='{"prompt":"how does widget17 relate to the Summa fleet gadget3?","session_id":"su1","hook_event_name":"UserPromptSubmit"}'
look(){ printf '%s' "$PR" | timeout "${1:-30}" bash "$SUMMA" 2>/dev/null; }
golden="$(look)"
ck "S0 lookup names the widget17 answer and the Summa entity" "$(grep -c 'answer-17.md' <<<"$golden")/$(grep -c 'wiki/entities/Summa.md' <<<"$golden")" "1/1"
# S1 slow wiki: a FIFO in answers (nobody writes it) must not block, cold or warm
rm -rf "$W/scache" "$W/lookups.jsonl"; mkfifo "$V/wiki/answers/zz-slow.md"
t0=$(now); o="$(look 12)"; rc=$?; t1=$(now)
ck "S1 slow wiki (FIFO in answers), cold index: returns within 6 s with the hit" "$(within "$t0" "$t1" 6)/$(grep -c 'answer-17.md' <<<"$o")" "ok/1"
t0=$(now); o="$(look 12)"; t1=$(now)
ck "S1 slow wiki, warm index: returns within 6 s with the hit" "$(within "$t0" "$t1" 6)/$(grep -c 'answer-17.md' <<<"$o")" "ok/1"
rm -f "$V/wiki/answers/zz-slow.md"
# S2 steady state never touches the wiki: move the whole wiki away; the cached index still answers
mv "$V/wiki" "$V/wiki.gone"; o="$(look 12)"; mv "$V/wiki.gone" "$V/wiki"
ck "S2 warm index: lookup answers with the wiki directory absent (no wiki access on the prompt path)" "$(grep -c 'answer-17.md' <<<"$o")" 1
# S3 stale index: still used at once; a detached refresh picks up a new page
touch -d '2 hours ago' "$W/scache/lookup-index.tsv"; printf -- '---\nquestion: "Zorblax widget handling"\n---\n' >"$V/wiki/answers/2026-11-13-zorblax.md"
PRZ='{"prompt":"what is zorblax widget handling about","session_id":"su2","hook_event_name":"UserPromptSubmit"}'
o="$(printf '%s' "$PRZ" | timeout 12 bash "$SUMMA" 2>/dev/null)"
ck "S3 stale index: the new page is not in this answer (index served as is)" "$(grep -c zorblax <<<"$o")" 0
for i in $(seq 50); do grep -q zorblax "$W/scache/lookup-index.tsv" 2>/dev/null && break; sleep 0.1; done
o="$(printf '%s' "$PRZ" | timeout 12 bash "$SUMMA" 2>/dev/null)"
ck "S3 detached refresh rebuilt the index: the next prompt finds the new page" "$(grep -c zorblax <<<"$o")" 1
# S4 cosmetic failure: the lookup ledger is a FIFO (the append would block forever); the hook still exits promptly with the hit
rm -f "$W/lookups.jsonl"; mkfifo "$W/lookups.jsonl"
t0=$(now); o="$(look 12)"; t1=$(now)
ck "S4 cosmetic ledger-append failure (FIFO): returns within 6 s with the hit" "$(within "$t0" "$t1" 6)/$(grep -c 'answer-17.md' <<<"$o")" "ok/1"
rm -f "$W/lookups.jsonl"
# S5 absent wiki and absent index: silent, rc 0
rm -rf "$W/scache"; o="$(SUMMA_VAULT="$W/nowhere" look 12)"; ck "S5 no wiki, no index: silent" "${o:-silent}" silent

# S6 index scan scales linearly (rv6 F6-4): warm lookup at 2000 pages within 4.5x the 500-page time (linear = 4x; a quadratic scan is >6x). Measured here, best of 3, up to 3 attempts
mkvault(){ local d="$1" n="$2" i; rm -rf "$d"; mkdir -p "$d/wiki/answers" "$d/wiki/entities"; for i in $(seq 1 "$n"); do printf -- '---\nquestion: "How does widget%d relate to gadget%d?"\n---\nbody\n' "$i" "$((i % 7))" >"$d/wiki/answers/2026-11-13-answer-$i.md"; done; : >"$d/wiki/entities/Summa.md"; }
warmbest(){ local d="$1" c="$2" best=999 i a b; rm -rf "$c"; SUMMA_VAULT="$d" SUMMA_CACHE_DIR="$c" SUMMA_LEDGER="$W/lk6.jsonl" bash "$SUMMA" <<<"$PR" >/dev/null 2>&1; for i in $(seq 50); do [ -s "$c/lookup-index.tsv" ] && break; sleep 0.1; done
  for i in 1 2 3; do a=$(now); SUMMA_VAULT="$d" SUMMA_CACHE_DIR="$c" SUMMA_LEDGER="$W/lk6.jsonl" bash "$SUMMA" <<<"$PR" >/dev/null 2>&1; b=$(now); best="$(awk -v a="$a" -v b="$b" -v x="$best" 'BEGIN{t=b-a; print (t<x)?t:x}')"; done; echo "$best"; }
mkvault "$W/v500" 500; mkvault "$W/v2000" 2000
for att in 1 2 3; do t5="$(warmbest "$W/v500" "$W/c500")"; t20="$(warmbest "$W/v2000" "$W/c2000")"; r="$(awk -v a="$t5" -v b="$t20" 'BEGIN{printf "%.2f", b/a}')"; [ "$(awk -v r="$r" 'BEGIN{print (r<=4.5)?1:0}')" = 1 ] && break; done
echo "SCALE summa 500=$t5 2000=$t20 ratio=$r"
ck "S6 summa index scan: 2000 pages within 4.5x the 500-page time (linear, measured)" "$(awk -v r="$r" 'BEGIN{print (r<=4.5)?"ok":"quadratic " r}')" ok
# the 120 ms process cost dilutes 500 vs 2000 (a quadratic scan measures only 4.7x there); 2000 vs 8000 separates the classes: linear <= 1.6x measured, quadratic >= 10x
mkvault "$W/v8000" 8000
for att in 1 2 3; do t20="$(warmbest "$W/v2000" "$W/c2000")"; t80="$(warmbest "$W/v8000" "$W/c8000")"; r8="$(awk -v a="$t20" -v b="$t80" 'BEGIN{printf "%.2f", b/a}')"; [ "$(awk -v r="$r8" 'BEGIN{print (r<=3.0)?1:0}')" = 1 ] && break; done
echo "SCALE summa 2000=$t20 8000=$t80 ratio=$r8"
ck "S6 summa index scan: 8000 pages within 3x the 2000-page time (linear; a quadratic scan is above 10x, measured)" "$(awk -v r="$r8" 'BEGIN{print (r<=3.0)?"ok":"quadratic " r}')" ok

# --- GUARD NEGATIVES: the required guards still refuse at this head (none of them is touched or disabled by the advisory work)
gn(){ rc=0; "$@" >"$W/gn.out" 2>"$W/gn.err" || rc=$?; echo "$rc"; }
# unauthorized action: r7 bare redrive without the row-first wrapper; and a force push
pl(){ jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
ck "G1 unauthorized: r7 bare 'wm-build run redrive' is refused (rc 2)" "$(pl 'wm-build run redrive some-slug' | WM_SEAT=r7 bash "$R/.claude/hooks/redrive-gate.sh" >/dev/null 2>&1; echo $?)" 2
ck "G1 unauthorized: force push is denied (permissionDecision deny)" "$(pl 'git push --force origin main' | bash "$R/.claude/hooks/git-no-force-push.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "allow"')" deny
# wrong actor (identity-scoped boundary): an rb-marked process pushing to a wm-build run branch outside rb-land-push.sh; a foreign-owner ledger row never accounts an aside
ck "G2 wrong actor: rb-marked bare push to wm-build/<slug> is refused (rc 2)" "$(pl 'git push origin HEAD:refs/heads/wm-build/x' | WM_SEAT=rb bash "$R/.claude/hooks/land-push-gate.sh" >/dev/null 2>&1; echo $?)" 2
echo '[{"ask_id":"A55","rev":1,"owner":"rb","due":"2026-11-12T09:00","what":"x","key":"foreign.service"}]' >"$W/rows.json"
printf '{"last_assistant_message":"The foreign.service item is a separate check, not investigated.","stop_hook_active":false,"session_id":"g2"}' | WM_SEAT=ctl bash "$R/.claude/hooks/aside-followup-stop.sh" >"$W/gn.out" 2>/dev/null
ck "G2 wrong owner: an aside naming another seat's row still blocks for ctl" "$(jq -r '.decision // "allow"' "$W/gn.out" 2>/dev/null)" block
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"
# F6-6 (rv6): a hyphen-joined or suffixed token (A55-2, x-A55) is not the exact id A55; plain and punctuated A55 still bind
echo '[{"ask_id":"A55","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"x"}]' >"$W/rows.json"
aside(){ local r; r="$(jq -nc --arg m "$1" '{last_assistant_message:$m,stop_hook_active:false,session_id:"g6"}' | WM_SEAT=ctl bash "$R/.claude/hooks/aside-followup-stop.sh" 2>/dev/null | jq -r '.decision // "allow"')"; echo "${r:-allow}"; }
S6="is a separate check, not investigated."
ck "F6-6 A55-2 is not the exact id A55: still blocks" "$(aside "The item A55-2 $S6")" block
ck "F6-6 x-A55 is not the exact id A55: still blocks" "$(aside "The item x-A55 $S6")" block
ck "F6-6 A55-2b (longer suffix) still blocks" "$(aside "The item A55-2b $S6")" block
ck "F6-6 plain A55 still binds (allow)" "$(aside "The item A55 $S6")" allow
ck "F6-6 punctuated (A55), A55, and A55. still bind (allow)" "$(aside "It (A55) $S6")/$(aside "It, per A55, $S6")/$(aside "It is a separate check, not investigated, see A55.")" "allow/allow/allow"
echo '[{"ask_id":"T1","rev":1,"owner":"ctl","due":"2026-11-12T09:00","what":"owed thing"}]' >"$W/rows.json"
# wrong model: a non-Fable turn calling a fable-spawn skill is refused
mkdir -p "$W/skills/nopin"; printf -- '---\nname: nopin\nmodel: fable\nfable-spawn: true\n---\n# x\n' >"$W/skills/nopin/SKILL.md"
printf '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu1"}]}}\n' >"$W/t.jsonl"
ck "G3 wrong model: opus turn calling a fable-spawn skill is refused (rc 2)" "$(printf '{"tool_name":"Skill","tool_input":{"skill":"nopin"},"transcript_path":"%s","tool_use_id":"tu1","session_id":"s1"}' "$W/t.jsonl" | FABLE_SKILLS_DIR="$W/skills" SKILL_MARKER_DIR="$W/marks" bash "$R/.claude/hooks/fable-skill-spawn-gate.sh" >/dev/null 2>&1; echo $?)" 2
# duplicate executor: a PR held by another aide lane is refused
mkdir -p "$W/fd/claims"; printf 'lane=main\nsid=sid-holder\nexpires=%s\n' "$(( $(date +%s) + 3600 ))" >"$W/fd/claims/dotfiles#127"
ck "G4 duplicate executor: gh pr merge on a PR claimed by another lane is refused (rc 2)" "$(jq -nc --arg c 'gh pr merge 127 --repo j0yen/dotfiles --squash' --arg d "$W" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"sid-test-0001"}' | FLEET_DASH_DIR="$W/fd" WM_SEAT=aide WM_AIDE_LANE=build bash "$R/.claude/hooks/aide-claim-gate.sh" >/dev/null 2>&1; echo $?)" 2
# no hook disabled: the enforcing hooks stay registered exactly where they were
for h in aside-followup-stop.sh owed-now.sh redrive-gate.sh land-push-gate.sh git-no-force-push.sh aide-claim-gate.sh fable-skill-spawn-gate.sh; do
  ck "G5 $h still registered in .claude/settings.json" "$(jq -r --arg h "$h" '[.hooks[][].hooks[]?.command | select(contains($h))] | length > 0' "$R/.claude/settings.json")" true
done
echo "pass=$p fail=$f"; [ "$f" = 0 ]
