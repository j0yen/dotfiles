#!/usr/bin/env bash
# tests for ctl-dispatch-claim.sh (A1210): isolated dirs, stub worker, no systemd, no real notices
set -u
S="${CDC:-$HOME/.local/bin/ctl-dispatch-claim.sh}"; T="$(mktemp -d)"; p=0; f=0
ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
export DP_FEEDBACK="$T/fb" DP_STATE="$T/st" DP_NOTIFY=none DP_STALE=1
mkdir -p "$T/fb"
cat > "$T/worker.sh" <<'W'
#!/usr/bin/env bash
echo "$1" >> "$T_RUNS"; sleep "${W_SLEEP:-0}"; exit "${W_RC:-0}"
W
chmod +x "$T/worker.sh"; export T_RUNS="$T/runs" DP_WORKER="$T/worker.sh"
cat > "$T/start.sh" <<'W'
#!/usr/bin/env bash
( setsid "$CDC_SELF" run "$1" >/dev/null 2>&1 & )
W
chmod +x "$T/start.sh"; export CDC_SELF="$S" DP_START="$T/start.sh"
printf '# a\nDispatch: ctl\n' > "$T/fb/a.task.md"          # preexisting, marked
printf '# old\nno marker\n'   > "$T/fb/old.task.md"        # preexisting, unmarked
export DP_HOLD="false"
out=$($S scan); ck "held: nothing claimed" '[ ! -d "$T/st/claims" ] || [ -z "$(ls "$T/st/claims")" ]'
ck "held: reports held" 'echo "$out" | grep -q ^held'
export DP_HOLD="true"
$S scan >/dev/null; sleep 0.6
ck "preexisting marked task ran once" '[ "$(grep -c a.task.md "$T/runs")" = 1 ]'
ck "unmarked task skipped, not run" '! grep -q old.task.md "$T/runs" && $S status | grep -q "skipped.*old.task.md"'
ck "receipt written done" '$S status | grep -q "claimed/done a.task.md"'
$S scan >/dev/null; sleep 0.3
ck "replay scan does not re-run" '[ "$(grep -c a.task.md "$T/runs")" = 1 ]'
printf '# b\nDispatch: ctl\n' > "$T/fb/b.task.md"
for i in 1 2 3 4 5; do $S scan >/dev/null & done; wait; sleep 0.8
ck "5 concurrent scans -> new task ran exactly once" '[ "$(grep -c b.task.md "$T/runs")" = 1 ]'
# restart: claim exists, start never happened (crash between claim and start)
printf '# c\nDispatch: ctl\n' > "$T/fb/c.task.md"
k=$(printf '%s\0' "$T/fb/c.task.md" | cat - "$T/fb/c.task.md" | sha256sum | cut -c1-16)
mkdir -p "$T/st/claims/$k"; python3 -c "import json;json.dump({'source':'$T/fb/c.task.md','key':'$k','state':'claimed'},open('$T/st/claims/$k/claim.json','w'))"
sleep 1.2; $S scan >/dev/null; sleep 0.6
ck "crash before start: stale claim retried once" '[ "$(grep -c c.task.md "$T/runs")" = 1 ]'
sleep 1.2; $S scan >/dev/null; sleep 0.3
ck "retry is not repeated" '[ "$(grep -c c.task.md "$T/runs")" = 1 ]'
# failure after effect: worker rc!=0 -> failed receipt, no rerun
printf '# d\nDispatch: ctl\n' > "$T/fb/d.task.md"; W_RC=3 $S scan >/dev/null; sleep 0.8
ck "worker failure recorded failed" '$S status | grep -q "claimed/failed d.task.md"'
$S scan >/dev/null; sleep 0.3
ck "failed started task not re-executed" '[ "$(grep -c d.task.md "$T/runs")" = 1 ]'
# changed content = new claim
printf '# a2\nDispatch: ctl\n' > "$T/fb/a.task.md"; $S scan >/dev/null; sleep 0.6
ck "edited task gets a new claim" '[ "$(grep -c a.task.md "$T/runs")" = 2 ]'
# start failure keeps claim, owned
export DP_START="false"; printf '# e\nDispatch: ctl\n' > "$T/fb/e.task.md"; o=$($S scan); 
ck "start failure reported" 'echo "$o" | grep -q start-failed'
rm -rf "$T"; echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
