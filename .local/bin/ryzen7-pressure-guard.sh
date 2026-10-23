#!/usr/bin/env bash
# ryzen7-pressure-guard (v3 PGB, r7 10-19 9:1x PM; v2 10-16 9:1x am; v1 10-13 never re-raised).
# Every 5 min: DROP max_runs by one (floor 1) through the limits guard when swap fullness >= 75 %, or si+so > 20 MB/s over 10 s with
# < 8 G avail, or memory full avg60 > 20 % — unless a hand build (cargo with cwd under ~/hand/) runs while the shed timer is active.
# RE-RAISE one step after two consecutive calm reads (full60 < 5, siso 0, avail >= 8 G; swap fullness dropped from calm 10-20 v4: residue never
# drains on an idle host) taken once r7-pressure-shed has been quiet >= 600 s (its last-hot stamp; a shed HOT holds the count at 0) — ONLY back toward the value the guard itself
# dropped FROM, and only while the newest `limits-set key=max_runs` line in limits-guard.log is guard-authored (quote carries $TAG).
# v2 raised toward a cached `.baseline` file (stale 2 over a seat lock of 1, 10-18 8:14 PM); v3 derives the ceiling from the lock's
# own set log, so any seat/controller set of max_runs voids the drop record and the guard never raises over it.
# Paused runs in a land stage are never unpaused here (release = `wm-build run redrive --from land`).
# `--selftest` runs 8 scenarios in a throwaway HOME (fake readings via PG_* env) and prints `selftest ok 8/8`.
set -euo pipefail
TAG="pressure-guard auto (STOP WAITING FOR MY APPROVAL.)"

export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH   # v4.1: set before the selftest too (CTRL 10-20 6:15 PM: a bare non-login ssh lacked wm-build -> enforce failed -> 4/8)
GLOG=~/.local/state/wm-build/limits-guard.log   # prow: read by prow_row (the main flow below sets it again)
# ---- PROW (r7 10-22 4:5x PM, CTRL a358 + Fable FIX): every limits-guard set leaves a wm-decide row; a shed drop stamps pressure-last-shed and the
#      guard holds raises for HOLD_MIN after it (a shed itself is never held). Premise + expiry come from the shared watcher lib (watcher-premise.sh).
#      Row: first `ssh carbon wm-decide record --kind limit ...` under timeout 20s (a rejected flag or a hung ssh = failure); else one JSON line in
#      $R7_SEAT_STATE/pending-decisions.jsonl + `PROW-PENDING <n>` on every run while that file is non-empty. A failed row never blocks or reverts a set.
PREMISE="max_runs on ryzen7 is moved by memory pressure only while the wm-build daemon runs; raises wait HOLD_MIN after the last shed drop"
EXPIRES=${PROW_EXPIRES:-2026-11-21T23:59:59-08:00}
R7_SEAT_STATE=${R7_SEAT_STATE:-$HOME/.local/state/r7-seat}; PROW_PENDING=$R7_SEAT_STATE/pending-decisions.jsonl; PROW_LASTSHED=$R7_SEAT_STATE/pressure-last-shed
HOLD_MIN=${PROW_HOLD_MIN:-30}
WP_LIB=${WP_LIB:-$HOME/.local/lib/watcher-premise.sh}
if [ -r "$WP_LIB" ]; then . "$WP_LIB"; else wp_arm() { return 2; }; wp_gate() { return 1; }; fi   # no lib = disarmed, never armed-by-default
PROW_PREMISE_DEFAULT='export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}; systemctl --user is-active -q wm-build.service || exit 1'
wp_arm ryzen7-pressure-guard "${PROW_PREMISE_CMD:-$PROW_PREMISE_DEFAULT}" "$EXPIRES" "$PREMISE" || true
prow_say() { echo "$*"; echo "$(date -Is) $*" >> "${LOG:-$HOME/.local/state/ryzen7-pressure-guard.log}"; }
prow_state() { # per run (journal only): PROW_ARMED 0|1 (premise holds and unexpired); PROW-EXPIRED / PROW-DISARMED; PROW-PENDING <n>
  local n
  if wp_gate 2>/dev/null; then PROW_ARMED=1; else PROW_ARMED=0; fi
  if [ "${WP_DEFECT:-}" = expired ]; then echo "PROW-EXPIRED ryzen7-pressure-guard expires=$EXPIRES (raises disarmed; drops stay live)"
  elif [ "$PROW_ARMED" != 1 ]; then echo "PROW-DISARMED ryzen7-pressure-guard verdict=${WP_VERDICT:-?} defect=${WP_DEFECT:--} (raises disarmed; drops stay live)"; fi
  n=$(grep -c . "$PROW_PENDING" 2>/dev/null || true); if [ "${n:-0}" -gt 0 ]; then echo "PROW-PENDING $n"; fi
  return 0
}
prow_stamp() { mkdir -p "$R7_SEAT_STATE" 2>/dev/null && date +%s > "$PROW_LASTSHED.tmp" 2>/dev/null && mv -f "$PROW_LASTSHED.tmp" "$PROW_LASTSHED" 2>/dev/null || prow_say "PROW-STAMP-FAILED $PROW_LASTSHED"; return 0; }
prow_hold() { # rc 0 = a shed dropped less than HOLD_MIN ago; sets PROW_REMAINING (whole minutes, rounded up)
  local ls el now=${NOW:-$(date +%s)}
  ls=$(cat "$PROW_LASTSHED" 2>/dev/null || echo 0); case "$ls" in ''|*[!0-9]*) ls=0;; esac
  el=$((now-ls)); if [ "$el" -lt 0 ]; then el=0; fi
  if [ "$ls" -gt 0 ] && [ "$el" -lt $((HOLD_MIN*60)) ]; then PROW_REMAINING=$(( (HOLD_MIN*60-el+59)/60 )); return 0; fi
  return 1
}
prow_row() { # SCRIPT OLD NEW WHY: call right after a limits-guard set. Never fails, never reverts the set.
  ( set +e
    scr=$1; old=$2; new=$3; why=$4
    gl=$(grep "limits-set key=max_runs value=$new " "$GLOG" 2>/dev/null | tail -1)
    gts=${gl%% *}; gep=$(date -d "$gts" +%s 2>/dev/null || echo 0)
    if [ -z "$gl" ] || [ $(( $(date +%s) - gep )) -gt 300 ]; then prow_say "PROW-SKIP $scr max_runs $old->$new: no fresh limits-set value=$new line in limits-guard.log (set not applied), no row"; exit 0; fi
    what="$scr: max_runs $old->$new"; ev="ryzen7 limits-guard.log line ts $gts: limits-set key=max_runs value=$new"; rev="max_runs $old"
    rcmd='export PATH=$HOME/.local/bin:$PATH; wm-decide record'
    for a in --agent r7 --via "$scr" --kind limit --target host:ryzen7 --key max_runs --expect "$new" --what "$what" --why "$why" --evidence "$ev" --reverse-text "$rev" --tag "by=joe-$(date +%Y%m%d)+${scr%.sh}"; do rcmd="$rcmd $(printf '%q' "$a")"; done
    out=$(timeout 20s ssh -o BatchMode=yes -o ConnectTimeout=10 carbon "$rcmd" 2>&1); rc=$?
    if [ "$rc" = 0 ] && [ -n "$out" ]; then prow_say "PROW-ROW $(printf '%s' "$out" | tail -1) $what"; exit 0; fi
    err=$(printf '%s' "$out" | tail -1 | cut -c1-200)
    mkdir -p "$R7_SEAT_STATE" 2>/dev/null
    json=$(python3 -I -c 'import json,sys,time
a=sys.argv[1:]
print(json.dumps({"ts":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"agent":"r7","via":a[0],"kind":"limit","target":"host:ryzen7","key":"max_runs","expect":a[1],"what":a[2],"why":a[3],"evidence":a[4],"reverse_text":a[5],"rc":int(a[6]),"err":a[7]},ensure_ascii=False,separators=(",",":")))' "$scr" "$new" "$what" "$why" "$ev" "$rev" "$rc" "$err" 2>/dev/null)
    if [ -n "$json" ] && printf '%s\n' "$json" >> "$PROW_PENDING" 2>/dev/null; then prow_say "PROW-PENDING $(grep -c . "$PROW_PENDING") (row not recorded: rc=$rc ${err:--}; $what)"
    else prow_say "PROW-LOST $what (rc=$rc ${err:--}; pending append failed)"; fi
  ) || true
  return 0
}
if [ "${1:-}" = "--selftest" ]; then
  for b in wm-build wm-build-limits-guard; do command -v "$b" >/dev/null && [ -x "$(command -v "$b")" ] || { [ "$(hostname -s)" = ryzen7 ] && { echo "selftest FAILED: $b not executable on PATH=$PATH"; exit 1; }; echo "selftest SKIP: $b absent on $(hostname -s) (ryzen7-only script; FAILS on ryzen7)"; exit 0; }; done
  real_wb=$(command -v wm-build)
  self=$(readlink -f "$0"); real_guard=$(command -v wm-build-limits-guard || echo "$HOME/.local/bin/wm-build-limits-guard")
  pass=0; fail=0; pn=0
  real_state=$R7_SEAT_STATE; real_state_m=$(stat -c %y "$real_state" 2>/dev/null || echo absent); real_glog_m=$(stat -c %y "$GLOG" 2>/dev/null || echo absent)   # PROW: asserted unchanged at the end
  # ---- PROW sandbox: stub ssh (runs the "remote" command locally under the sandbox HOME) + stub wm-decide (accepts only the real `wm-decide record --help` flag set;
  #      a limit row needs --target/--key/--expect) + sandbox env. Nothing here can reach carbon, the real limits-guard, the real state dir or the real wm-decide ledger.
  mkstubs() {
    cat > "$T/.local/bin/ssh" <<'S'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$HOME/ssh.calls"; echo >> "$HOME/ssh.calls"
[ -e "$HOME/ssh.fail" ] && exit 255
while [ "${1:-}" = -o ]; do shift 2; done; shift
exec bash -c "$*"
S
    cat > "$T/.local/bin/wm-decide" <<'S'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$HOME/wmd.calls"; echo >> "$HOME/wmd.calls"
[ "${1:-}" = record ] || exit 2; shift; kind=""; have=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --agent|--via|--model|--gates|--attach|--kind|--what|--why|--evidence|--reverse-text|--target|--run|--pr|--slug|--expect-by|--key|--expect|--expect-within-h|--check|--rule|--tag|--from-text)
      [ $# -ge 2 ] || exit 2; have="$have$1 "; [ "$1" = --kind ] && kind=$2; shift 2;;
    *) echo "wm-decide: error: unrecognized arguments: $1" >&2; exit 2;;
  esac
done
case "$have" in *" --agent "*) ;; *) exit 2;; esac
case "$kind" in limit|config|run-state|prod|binary|prd|design|verdict|plan|test|other|correction|restart|guard|observe|gate) ;; *) exit 2;; esac
if [ "$kind" = limit ]; then for r in --target --key --expect; do case "$have" in *" $r "*) ;; *) echo "refused: limit needs $r" >&2; exit 2;; esac; done; fi
[ -e "$HOME/wmd.reject" ] && { echo "wm-decide: error: stub forced rejection" >&2; exit 2; }
echo "d-20261022-000000-r7-stub"
S
    chmod +x "$T/.local/bin/ssh" "$T/.local/bin/wm-decide"
    export R7_SEAT_STATE="$T/.local/state/r7-seat" WP_STATE="$T/.local/state/watcher-premise" WP_LIB PROW_PREMISE_CMD=true PROW_EXPIRES="$(date -d '+1 day' -Iseconds)"
  }
  # stub limits-guard: `set max_runs=N --by X QUOTE` appends the log line + rewrites config.toml; enforce is a no-op
  mkstubs_lg() {
    cat > "$T/.local/bin/wm-build-limits-guard" <<'S'
#!/usr/bin/env bash
case "${1:-}" in
  set) v=${2#max_runs=}; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) limits-set key=max_runs value=$v by=$4 quote=\"$5\"" >> "$HOME/.local/state/wm-build/limits-guard.log"
       sed -i "s/^max_runs = .*/max_runs = $v/" "$HOME/.config/wm-build/config.toml"; echo x >> "$HOME/set.calls"; echo "set max_runs=$v";;
  *) :;;
esac
S
    chmod +x "$T/.local/bin/wm-build-limits-guard"
  }
  mk() { # fresh fake HOME with lock max_runs=$1, config max_runs=$1, last set by a seat
    T=$(mktemp -d "${TMPDIR:-/tmp}/pgb-selftest.XXXXXX"); mkdir -p "$T/.config/wm-build" "$T/.local/state/wm-build" "$T/.local/bin"
    cp "$real_guard" "$T/.local/bin/wm-build-limits-guard"; mkdir -p "$T/.cargo/bin"; ln -s "$real_wb" "$T/.cargo/bin/wm-build"   # enforce validates via `wm-build config show`
    printf 'box.grace_minutes=20\nbuilder.idle_minutes=20\nbox.roles.coder.max_boxes=4\nbox.roles.coder.max_leases_per_box=7\nmax_runs=%s\nbuilder.type=ccx43\n' "$1" > "$T/.config/wm-build/limits.lock"
    printf 'max_runs = %s  # limits.lock — one record; see wm-build-limits-guard\n[box]\ngrace_minutes = 20\n[box.roles.coder]\nmax_boxes = 4\nmax_leases_per_box = 7\n[builder]\nidle_minutes = 20\ntype = "ccx43"\n' "$1" > "$T/.config/wm-build/config.toml"
    echo "2026-10-19T00:00:00Z limits-set key=max_runs value=$1 by=joe-20261019 quote=\"seat\"" > "$T/.local/state/wm-build/limits-guard.log"
    python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table runs(id integer, outcome text)"); c.execute("create table land(slug text, run_id integer, stage text)"); c.execute("insert into runs values(77,null)"); c.execute("insert into land values(\"s\",77,\"ci-wait\")"); c.commit()' "$T/.local/state/wm-build/state.db"
    mkstubs
  }
  run() { HOME=$T PG_SELFTEST=1 "$@" bash "$self" >/dev/null 2>&1 || true; }
  cur() { grep -E '^max_runs = ' "$T/.config/wm-build/config.toml" | awk '{print $3}'; }
  ok() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3: got $1 want $2"; fi; }
  HOT=(env PG_SWAPPCT=80 PG_FULL60=0 PG_SISO=0 PG_AVAIL=20 PG_HAND=0); CALM=(env PG_SWAPPCT=0 PG_FULL60=0 PG_SISO=0 PG_AVAIL=20 PG_HAND=0)
  # (a) drop 3->2, two calm reads -> back to 3
  mk 3; run "${HOT[@]}"; d=$(cur); run "${CALM[@]}"; run "${CALM[@]}"; ok "$d/$(cur)" "2/3" "a:drop-then-raise"; rm -rf "$T"
  # (b) drop 3->2, seat sets 1, calm x2 -> stays 1, drop record gone
  mk 3; run "${HOT[@]}"; HOME=$T "$T/.local/bin/wm-build-limits-guard" set max_runs=1 --by joe-20261019 "seat" >/dev/null 2>&1; HOME=$T "$T/.local/bin/wm-build-limits-guard" enforce >/dev/null 2>&1 || true
  run "${CALM[@]}"; run "${CALM[@]}"; ok "$(cur)/$([ -e "$T/.local/state/ryzen7-pressure-guard.drop" ] && echo rec || echo none)" "1/none" "b:seat-set-voids"; rm -rf "$T"
  # (c) no drop record, cur 1 (seat ruling), calm x3 -> stays 1 (v2 raised here off a stale .baseline)
  mk 1; echo 2 > "$T/.local/state/ryzen7-pressure-guard.baseline"; run "${CALM[@]}"; run "${CALM[@]}"; run "${CALM[@]}"; ok "$(cur)" "1" "c:no-record-no-raise"; rm -rf "$T"
  # (d) a paused LAND run (77, stage ci-wait) is never unpaused; it stays in the paused list
  mk 3; run "${HOT[@]}"; echo "77 x 1 verb" > "$T/.local/state/r7-paused-runs"; run "${CALM[@]}"; run "${CALM[@]}"
  ok "$(grep -c '^77 ' "$T/.local/state/r7-paused-runs")/$(grep -c 'land-held 77' "$T/.local/state/ryzen7-pressure-guard.log")" "1/1" "d:land-never-unpaused"; rm -rf "$T"
  # (e) HOT at floor 1 -> no set (a drop from 1 would be max_runs=0 = UNLIMITED)
  mk 1; run "${HOT[@]}"; ok "$(cur)/$(grep -c limits-set "$T/.local/state/wm-build/limits-guard.log")" "1/1" "e:floor-1"; rm -rf "$T"
  # (f) today's real post-spike calm (swap 6 %, full60 0, siso 0, avail 16) after a guard drop -> raises (v3 swap<5 % never did)
  POST=(env PG_SWAPPCT=6 PG_FULL60=0 PG_SISO=0 PG_AVAIL=16 PG_HAND=0)
  mk 3; run "${HOT[@]}"; run "${POST[@]}"; run "${POST[@]}"; ok "$(cur)" "3" "f:post-spike-calm-raises"; rm -rf "$T"
  # (g) shed HOT 120 s ago -> calm reads do not count, no raise; healthy 'ok' input with no record never sets
  mk 3; run "${HOT[@]}"; echo $(( $(date +%s) - 120 )) > "$T/.local/state/r7-pressure-shed.last-hot"; run "${CALM[@]}"; run "${CALM[@]}"; ok "$(cur)" "2" "g:shed-recent-holds"; rm -rf "$T"
  mk 3; run "${CALM[@]}"; run "${CALM[@]}"; ok "$(cur)/$(grep -c limits-set "$T/.local/state/wm-build/limits-guard.log")" "3/1" "h:healthy-no-fire"; rm -rf "$T"
  # ---- PROW cases: stub limits-guard/ssh/wm-decide in a fresh mktemp root. Calm read #2 at a drop record "3 1" (guard-owned) is a raise attempt.
  #      (1) inside the 30 min hold -> 0 sets + 1 PROW-HOLD; (2) after the hold -> 1 set + 1 row; (3) ssh failure -> 1 pending line, set applied; (4) expired -> 0 sets, PROW-EXPIRED,
  #      a HOT drop still happens (+1 row); (5) pending file -> PROW-PENDING n each run
  okp() { pn=$((pn+1)); ok "$@"; }
  lines() { if [ -e "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }
  mkp() { # $1 = max_runs now, $2 = last-shed age in s ("" = no stamp); drop record "3 $1", guard-authored last set, one calm read already counted
    T=$(mktemp -d "${TMPDIR:-/tmp}/pgb-selftest.XXXXXX"); mkdir -p "$T/.config/wm-build" "$T/.local/state/wm-build" "$T/.local/state/r7-seat" "$T/.local/bin"
    printf 'max_runs = %s\n' "$1" > "$T/.config/wm-build/config.toml"; echo "2026-10-22T00:00:00Z limits-set key=max_runs value=$1 by=joe-20261022+ryzen7-pressure-guard quote=\"$TAG\"" > "$T/.local/state/wm-build/limits-guard.log"
    echo "3 $1" > "$T/.local/state/ryzen7-pressure-guard.drop"; echo 1 > "$T/.local/state/ryzen7-pressure-guard.calm"
    mkstubs; mkstubs_lg; [ -z "${2:-}" ] || echo $(( $(date +%s) - $2 )) > "$T/.local/state/r7-seat/pressure-last-shed"; }
  runp() { HOME=$T PG_SELFTEST=1 "$@" bash "$self" > "$T/out" 2>&1 || true; }
  mkp 1 600; runp "${CALM[@]}"
  okp "$(cur)/$(lines "$T/set.calls")/$(grep -c '^PROW-HOLD 20m$' "$T/out")/$(lines "$T/wmd.calls")" "1/0/1/0" "prow-a:calm-inside-hold-no-raise"; rm -rf "$T"
  mkp 1 $((31*60)); runp "${CALM[@]}"
  okp "$(cur)/$(lines "$T/set.calls")/$(lines "$T/wmd.calls")/$(grep -cF 'ryzen7-pressure-guard.sh: max_runs 1->2|' "$T/wmd.calls")/$(grep -cF '|--expect|2|' "$T/wmd.calls")/$(grep -cF '|--reverse-text|max_runs 1|' "$T/wmd.calls")/$(grep -c '^PROW-HOLD' "$T/out")/$(grep -c '^PROW-ROW d-' "$T/out")/$(lines "$T/.local/state/r7-seat/pending-decisions.jsonl")" "2/1/1/1/1/1/0/1/0" "prow-b:calm-after-hold-raise-and-row"; rm -rf "$T"
  mkp 1 $((31*60)); touch "$T/ssh.fail"; runp "${CALM[@]}"
  okp "$(cur)/$(lines "$T/set.calls")/$(lines "$T/.local/state/r7-seat/pending-decisions.jsonl")/$(grep -c '^PROW-PENDING' "$T/out")" "2/1/1/1" "prow-c:ssh-fail-pending-set-applied"; rm -rf "$T"
  mkp 1 $((31*60)); touch "$T/wmd.reject"; runp "${CALM[@]}"
  okp "$(cur)/$(lines "$T/wmd.calls")/$(lines "$T/.local/state/r7-seat/pending-decisions.jsonl")" "2/1/1" "prow-d:flag-rejection-is-failure"; rm -rf "$T"
  mkp 1 ""; runp env PROW_EXPIRES=2020-01-01T00:00:00Z "${CALM[@]}"
  okp "$(cur)/$(lines "$T/set.calls")/$(grep -c '^PROW-EXPIRED' "$T/out")" "1/0/1" "prow-e:expired-guard-no-raise"; rm -rf "$T"
  mkp 3 ""; runp env PROW_EXPIRES=2020-01-01T00:00:00Z "${HOT[@]}"
  okp "$(cur)/$(lines "$T/set.calls")/$(lines "$T/wmd.calls")/$(grep -c '^PROW-EXPIRED' "$T/out")" "2/1/1/1" "prow-f:expired-guard-still-drops"; rm -rf "$T"
  mkp 1 ""; mkdir -p "$T/.local/state/r7-seat"; printf '{"x":1}\n{"x":2}\n{"x":3}\n' > "$T/.local/state/r7-seat/pending-decisions.jsonl"; runp "${CALM[@]}"
  okp "$(grep -c '^PROW-PENDING 3$' "$T/out")" "1" "prow-g:pending-visible-every-run"; rm -rf "$T"
  okp "$([ "$(stat -c %y "$real_state" 2>/dev/null || echo absent)" = "$real_state_m" ] && [ "$(stat -c %y "$GLOG" 2>/dev/null || echo absent)" = "$real_glog_m" ] && echo unchanged || echo CHANGED)" "unchanged" "prow-h:real-state-dir-and-limits-guard.log-untouched"
  if [ "$fail" = 0 ]; then echo "selftest ok $pass/$((8+pn))"; exit 0; else echo "selftest FAILED $fail/$((8+pn))"; exit 1; fi
fi

export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
LOG=~/.local/state/ryzen7-pressure-guard.log
DROPF=~/.local/state/ryzen7-pressure-guard.drop   # "<from> <to>" written at each guard drop
CALMF=~/.local/state/ryzen7-pressure-guard.calm
GLOG=~/.local/state/wm-build/limits-guard.log
rm -f ~/.local/state/ryzen7-pressure-guard.baseline   # v2 cache, retired by v3
cur=$(grep -E '^max_runs = ' ~/.config/wm-build/config.toml | awk '{print $3}')
last_set=$(grep 'limits-set key=max_runs ' "$GLOG" 2>/dev/null | tail -1 || true)
guard_owned=0; case "$last_set" in *"$TAG"*) guard_owned=1;; esac
if [ -s "$DROPF" ] && [ "$guard_owned" = 0 ]; then rm -f "$DROPF"; fi   # a seat/controller set since the drop IS the ruling
from=$(awk '{print $1}' "$DROPF" 2>/dev/null || true)
prow_state

if [ -n "${PG_SELFTEST:-}" ]; then
  swappct=$PG_SWAPPCT; memfull60=$PG_FULL60; siso_mb=$PG_SISO; availg=$PG_AVAIL; hand=$PG_HAND; swapused=0
else
  swapused=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print int((t-f)/1048576)}' /proc/meminfo)
  # 5:3x pm 10-16: swap FULLNESS = percent of the pri-10 T7 files (/mnt/ssd/swap*.img) only, not GB and not the NVMe pri-0 file
  swappct=$(swapon --show --bytes --noheadings 2>/dev/null | awk '$1 ~ /^\/mnt\/ssd\/swap/{s+=$3;u+=$4}END{print (s>0)?int(u*100/s):0}')
  memfull60=$(awk -F'avg60=' '/^full/{split($2,a," "); print int(a[1])}' /proc/pressure/memory)
  read -r si1 so1 < <(awk '/^pswpin/{i=$2}/^pswpout/{o=$2}END{print i,o}' /proc/vmstat); sleep 10
  read -r si2 so2 < <(awk '/^pswpin/{i=$2}/^pswpout/{o=$2}END{print i,o}' /proc/vmstat)
  siso_mb=$(( ((si2-si1)+(so2-so1))*4/1024/10 ))
  hand=0; for p in $(pgrep -x cargo 2>/dev/null); do case "$(readlink /proc/$p/cwd 2>/dev/null)" in *"/hand/"*) hand=1;; esac; done
  # 3:2x pm 10-16: the hand-build exemption holds ONLY while the durable shed timer is active
  systemctl --user is-active -q r7-pressure-shed.timer || hand=0
  availg=$(awk '/^MemAvailable/{print int($2/1048576)}' /proc/meminfo)
fi
line="$(date -Is) cur=$cur drop_from=${from:--} guard_owned=$guard_owned swap_used_G=$swapused swap_pct=$swappct mem_full60=$memfull60 siso_MBps=$siso_mb avail_G=$availg hand_build=$hand"
# 4:1x pm 10-16: swap rate counts only with RAM short (< 8 G avail)
hot=0; { [ "$swappct" -ge 75 ] || { [ "$siso_mb" -gt 20 ] && [ "$availg" -lt 8 ]; } || [ "$memfull60" -gt 20 ]; } && hot=1
calm=0; { [ "$memfull60" -lt 5 ] && [ "$siso_mb" -eq 0 ] && [ "$availg" -ge 8 ]; } && calm=1
NOW=${PG_NOW:-$(date +%s)}; lasthot=$(cat ~/.local/state/r7-pressure-shed.last-hot 2>/dev/null || echo 0); hotage=$((NOW-${lasthot:-0}))
setmr() { out=$(wm-build-limits-guard set max_runs="$1" --by "joe-$(date +%Y%m%d)+ryzen7-pressure-guard" "$TAG" 2>&1 | tail -1); wm-build-limits-guard enforce >/dev/null 2>&1 || true; }
in_land() { python3 -I -c '
import sqlite3,sys; c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)
r=c.execute("select stage from land where run_id=? and stage is not null",(int(sys.argv[2]),)).fetchone(); print("land" if r else "no")' "$HOME/.local/state/wm-build/state.db" "$1" 2>/dev/null || echo land; }

if [ "$hot" = 1 ]; then
  echo 0 > "$CALMF"
  if [ "$hand" = 1 ]; then echo "$line HOT but hand build running — shed owns it, no drop" >> $LOG
  elif [ "$cur" -gt 1 ]; then tgt=$((cur-1)); setmr "$tgt"
    echo "${from:-$cur} $tgt" > "$DROPF"   # keep the ORIGINAL from across consecutive drops
    echo "$line DROPPED -> $tgt (ceiling ${from:-$cur}): $out" >> $LOG
    prow_row ryzen7-pressure-guard.sh "$cur" "$tgt" "HOT swap_pct=$swappct mem_full60=$memfull60 siso_MBps=$siso_mb avail_G=$availg (HOT = swap_pct>=75 | siso>20MBps with avail<8G | mem_full60>20)"
  else echo "$line HOT at floor 1" >> $LOG; fi
elif [ "$calm" = 1 ] && [ -n "$from" ] && [ "$cur" -lt "$from" ] && [ "$hotage" -lt 600 ]; then
  echo 0 > "$CALMF"; echo "$line calm, shed HOT ${hotage}s ago (< 600 s) — calm count held at 0, ceiling $from" >> $LOG
elif [ "$calm" = 1 ] && [ -n "$from" ] && [ "$cur" -lt "$from" ]; then
  n=$(( $(cat "$CALMF" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CALMF"
  pid_=$(grep -m1 ' verb$' "$HOME/.local/state/r7-paused-runs" 2>/dev/null | cut -d' ' -f1 || true)   # shed-owned lines only (4th field verb = r7-pressure-shed; nothing else writes this file)
  if [ "$n" -ge 2 ] && [ -n "$pid_" ] && [ "$(in_land "$pid_")" = land ]; then
    echo 0 > "$CALMF"; echo "$line land-held $pid_ — not unpaused (release = redrive --from land); raise deferred" >> $LOG
  elif [ "$n" -ge 2 ] && [ -n "$pid_" ]; then
    # controller 10-16 4:14 pm: unpause the OLDEST shed-paused run before any raise (a held run already counts in max_runs)
    out=$($HOME/.local/bin/r7-unpause-run.sh "$pid_" 2>&1 | tail -1)
    echo 0 > "$CALMF"; echo "$line UNPAUSED $pid_ (calm x$n, ceiling $from, raise deferred to the next calm pair): $out" >> $LOG
  elif [ "$n" -ge 2 ] && [ "$PROW_ARMED" != 1 ]; then echo "$line PROW-DISARMED ${WP_DEFECT:--} — raise to $((cur+1)) skipped (calm x$n, ceiling $from)" >> $LOG
  elif [ "$n" -ge 2 ] && prow_hold; then echo "$line PROW-HOLD ${PROW_REMAINING}m — raise to $((cur+1)) held (calm x$n, ceiling $from, last shed drop within ${HOLD_MIN} min)" >> $LOG; echo "PROW-HOLD ${PROW_REMAINING}m"
  elif [ "$n" -ge 2 ]; then tgt=$((cur+1)); setmr "$tgt"
    if [ "$tgt" -ge "$from" ]; then rm -f "$DROPF"; else echo "$from $tgt" > "$DROPF"; fi
    echo 0 > "$CALMF"; echo "$line RAISED -> $tgt (calm x$n, ceiling $from): $out" >> $LOG
    prow_row ryzen7-pressure-guard.sh "$cur" "$tgt" "calm x$n (mem_full60=$memfull60 siso_MBps=$siso_mb avail_G=$availg swap_pct=$swappct), shed quiet ${hotage}s, hold ${HOLD_MIN}m clear; restoring toward ceiling $from"
  else echo "$line calm $n/2 below ceiling $from" >> $LOG; fi
else
  [ "$calm" = 1 ] && echo 0 > "$CALMF" || true
  echo "$line ok" >> $LOG
fi
