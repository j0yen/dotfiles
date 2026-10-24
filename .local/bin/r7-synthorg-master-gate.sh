#!/bin/bash
# r7-synthorg-master-gate.sh — run synthorg's own gate on every new origin/master sha (= after every land) on a clean clone.
# Why: synthorg master went red with no gate on master (10-23 wm-verify 20261023T081940Z-0c232023661e EXIT=1: contracts drift,
# pinned counts, ruff 10, mypy 13) and run 486 died `blocked refresh-failed` hours later. Fable fb22 FIX 8: guard = this timer;
# root fix (land-stage check on the post-merge tree) is rb's. Timer r7-synthorg-master-gate.timer, 10 min. Read-only on real
# paths: clones into a mktemp dir, writes only its own state/log/notify. Gate = the daemon's commands: `synthorg contracts check`,
# `ruff check .`, `mypy src`, `promise lint`, `pytest -m "not flaky"` + flaky with reruns (= CI gate.yml), py3.14, HOME/TMPDIR inside the mktemp root, 3 G cgroup, nice 19.
# State ~/.local/state/r7-synthorg-master-gate.json {sha, status green|red|error, parts, ts}; a red or a transition appends to
# ~/.local/state/r7-lever2.notify. --selftest runs the decision logic on stub gates in a mktemp dir.
# CLOCK (plint-l3): the state JSON also carries clock {surface_age_days, expired_allow, expired_keys, line_present, expected, ts} parsed from the
# `promise-lint-clock:` line of `synthorg promise lint` (WARN, exit 0, so it never reaches status). expected = master's src/synthorg/promise.py has that line.
# The clock moves with the date, not the sha: a SAME-SHA tick is clock-only (re-lint, rewrite ONLY clock via .new + mv; status/parts/notify untouched,
# lint rc ignored), and a full gate run re-lints every 10 min (clockbeat) so clock.ts stays fresh. fleet-dash promise_clock.py alarms on it.
set -u
export PATH=$HOME/.cargo/bin:$HOME/.local/bin:$PATH
ST=$HOME/.local/state; OUT=$ST/r7-synthorg-master-gate.json; LOG=$ST/r7-synthorg-master-gate.log; NOTIFY=$ST/r7-lever2.notify
URL=https://github.com/j0yen/synthorg.git
SELF=0; [ "${1:-}" = "--selftest" ] && SELF=1
log() { echo "$(date '+%F %I:%M:%S %p') $*" >> "$LOG"; }
prev() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$OUT" "$1" 2>/dev/null; }
save() {  # save <sha> <status> <parts>; $CLK (clock JSON) when set, else the previous clock is carried over
  python3 -I -c '
import json,sys,datetime,os
d={"sha":sys.argv[2],"status":sys.argv[3],"parts":sys.argv[4],"ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
try: c=json.loads(sys.argv[5]) if sys.argv[5] else json.load(open(sys.argv[1])).get("clock")
except Exception: c=None
if c: d["clock"]=c
json.dump(d,open(sys.argv[1]+".new","w")); os.replace(sys.argv[1]+".new",sys.argv[1])' "$OUT" "$1" "$2" "$3" "${CLK:-}"; }
# mkclock <lint-output-file> <expected 0|1>: the clock JSON from the `promise-lint-clock: surface_age_days=<n> expired_allow=<n> expired_keys=<k1,k2|->` line (last one wins)
mkclock() {
  python3 -I -c '
import json,re,sys,datetime
try: t=open(sys.argv[1],errors="replace").read()
except OSError: t=""
c={"surface_age_days":None,"expired_allow":None,"expired_keys":[],"line_present":False,"expected":sys.argv[2]=="1","ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
m=re.findall(r"promise-lint-clock: surface_age_days=(\d+) expired_allow=(\d+) expired_keys=(\S+)",t)
if m:
    a,e,k=m[-1]; c.update(surface_age_days=int(a),expired_allow=int(e),expired_keys=[] if k=="-" else k.split(","),line_present=True)
print(json.dumps(c))' "$1" "$2"; }
# setclock <clock JSON>: rewrite ONLY .clock in the state JSON (.new + mv); no state file = nothing to annotate
setclock() {
  python3 -I -c '
import json,sys,os
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
d["clock"]=json.loads(sys.argv[2])
json.dump(d,open(sys.argv[1]+".new","w")); os.replace(sys.argv[1]+".new",sys.argv[1])' "$OUT" "$1"; }
# clocklint <dir>: <dir>/s is a synced clone at the linted sha; writes <dir>/expected (1 = master's promise.py emits the clock line) and
# <dir>/promise.clock.out (the lint output; its exit code is ignored, the clock is a WARN)
clocklint() {
  local D=$1
  if git -C "$D/s" grep -q promise-lint-clock HEAD -- src/synthorg/promise.py 2>/dev/null; then echo 1 > "$D/expected"; else echo 0 > "$D/expected"; fi
  (cd "$D/s" && HOME=$D/h XDG_CONFIG_HOME=$D/h/.config TMPDIR=$D/t timeout 300 uv run --no-sync synthorg promise lint) > "$D/promise.clock.out" 2>&1
  return 0
}
clockfrom() { setclock "$(mkclock "$1/promise.clock.out" "$(cat "$1/expected" 2>/dev/null || echo 0)")"; }  # clockfrom <dir>
lintclone() {  # lintclone <sha> <dir>: shallow clone at <sha> + uv sync + clocklint; rc 1 = no lint ran (the clock is left as it was)
  local sha=$1 D=$2
  git clone -q --depth 1 -b master "$URL" "$D/s" && [ "$(git -C "$D/s" rev-parse HEAD)" = "$sha" ] || return 1
  mkdir -p "$D/h" "$D/t"; export UV_PYTHON=3.14 UV_CACHE_DIR=$HOME/.cache/uv
  (cd "$D/s" && TMPDIR=$D/t uv sync -q) > "$D/sync.out" 2>&1 || return 1
  clocklint "$D"
}
clockonly() {  # clockonly <sha>: the same-sha tick; status, parts and notify stay untouched
  local D; D=$(mktemp -d "$HOME/.cache/r7-smg.XXXX") || return 0
  if lintclone "$1" "$D"; then clockfrom "$D"; log "clock-only $(cat "$D/promise.clock.out" 2>/dev/null | grep -o 'promise-lint-clock:.*' | tail -1)"; else log "clock-only: clone/sync failed, clock kept"; fi
  rm -rf "$D"; return 0
}
clockbeat() {  # clockbeat <dir>: during a long full gate run, re-lint every 10 min so clock.ts stays under the 30-min stale-tick alarm
  local D=$1
  while sleep 600; do [ -d "$D/s" ] || break; clocklint "$D"; [ -d "$D/s" ] && clockfrom "$D"; done
}
# EXPECT = every `run: uv run …` one-liner in synthorg .github/workflows/gate.yml (both jobs; the second job's
# "not flaky and not slow" is a subset of the first). The argv part diffs it against the cloned sha's gate.yml, so a CI
# command added, removed or changed turns this gate red (+added / -missing) instead of drifting silently (ctl 1:5x, 90a0).
EXPECT='ruff check .
mypy src
synthorg promise lint
pytest -m "not flaky"
pytest -m flaky --reruns 2 --reruns-delay 5
pytest -m "not flaky and not slow"'
argvdrift() {  # argvdrift <gate.yml>: prints "+cmd"/"-cmd" for each difference vs EXPECT; rc 1 on any (a missing file = all missing)
  local got df; got=$(sed -nE 's/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+uv run (.+[^[:space:]])[[:space:]]*$/\2/p' "$1" 2>/dev/null | LC_ALL=C sort -u)
  df=$(LC_ALL=C comm -3 <(printf '%s\n' "$EXPECT" | LC_ALL=C sort -u) <(printf '%s\n' "$got" | sed '/^$/d') | sed -E 's/^\t/+/; t; s/^/-/')
  # structural facts this gate depends on: the main lane runs with SYNTHORG_LOAD_GUARD=1; the flaky lane is
  # continue-on-error ("reports, never gates"), so pytestflaky below is report-only
  grep -A3 -F 'run: uv run pytest -m "not flaky"' "$1" 2>/dev/null | grep -q 'SYNTHORG_LOAD_GUARD: "1"' || df="$df${df:+
}-env SYNTHORG_LOAD_GUARD=1 on main lane"
  grep -A2 -F 'run: uv run pytest -m flaky --reruns' "$1" 2>/dev/null | grep -q 'continue-on-error: true' || df="$df${df:+
}-continue-on-error on flaky lane"
  [ -z "$df" ] && { echo "gate.yml argv matches"; return 0; }; echo "drift: $(echo "$df" | paste -sd' ' -)"; return 1; }
# gate <dir>: runs the parts, prints "part=rc …"; status red when any rc != 0
gate() {
  local d=$1 p r parts="" bad=0
  for p in argv contracts ruff mypy promise pytest pytestflaky; do
    case $p in
      argv) argvdrift "$d/s/.github/workflows/gate.yml" > "$d/$p.out" 2>&1 ;;
      contracts) (cd "$d/s" && timeout 600 uv run synthorg contracts check) > "$d/$p.out" 2>&1 ;;
      ruff) (cd "$d/s" && timeout 600 uv run ruff check .) > "$d/$p.out" 2>&1 ;;
      # ruff/mypy/promise/pytest argv = .github/workflows/gate.yml (mypy src, not `.`: `.` reads corpora/ + tests/ under
      # strict and reported 1424 errors CI never sees, 10-23)
      mypy) (cd "$d/s" && timeout 1200 uv run mypy src) > "$d/$p.out" 2>&1 ;;
      promise) (cd "$d/s" && timeout 600 uv run synthorg promise lint) > "$d/$p.out" 2>&1 ;;
      # per-test --timeout (pytest-timeout added at run time, not a repo dep): a HANG is a red test, never a silent
      # whole-suite kill (Fable 2774/aa42: esc_ac2 + nested fastprooftier hang rather than fail)
      pytest) (cd "$d/s" && SYNTHORG_LOAD_GUARD=1 timeout 4500 uv run --with pytest-timeout python -m pytest -q -rfE -p no:cacheprovider -o faulthandler_timeout=600 --timeout=600 -m "not flaky") > "$d/$p.out" 2>&1 ;;
      pytestflaky) (cd "$d/s" && timeout 1800 uv run --with pytest-timeout --with pytest-rerunfailures python -m pytest -q -rfE -p no:cacheprovider --timeout=600 -m flaky --reruns 2 --reruns-delay 5) > "$d/$p.out" 2>&1 ;;
    esac
    r=$?; local rep=0; [ $p = pytestflaky ] && rep=1   # flaky lane = gate.yml continue-on-error: reported, never red/green
    [ $r = 0 ] || [ $rep = 1 ] || bad=1
    local to=""; case $p in pytest*) to=$(grep -cE 'Timeout >[0-9.]+s|^\+{5,} Timeout \+{5,}' "$d/$p.out"); [ "$to" -gt 0 ] && { [ $rep = 1 ] || bad=1; [ $r = 0 ] && r=1; }; to=" timeouts=$to" ;; esac
    [ $rep = 1 ] && to="$to report-only"
    parts="$parts $p=$r($(tail -1 "$d/$p.out" | tr -d '\n' | cut -c1-60))${to}"
  done
  echo "${parts# }"; return $bad
}
decide() {  # decide <sha> <rc> <parts>: save + notify on red or transition
  local sha=$1 rc=$2 parts=$3 st old; old=$(prev status)
  st=green; [ "$rc" = 0 ] || st=red; [ "$rc" = 99 ] && st=error
  save "$sha" "$st" "$parts"; log "$st ${sha:0:10} $parts"
  if [ "$st" != green ] || [ "$old" != green ]; then
    [ "$st" = green ] && [ -z "$old" ] && return 0
    echo "$(date '+%I:%M %p') r7-synthorg-master-gate ${st^^} master ${sha:0:10} (was ${old:-none}): $parts" >> "$NOTIFY"
  fi
}
main() {
  local sha D rc parts
  sha=$(git ls-remote "$URL" refs/heads/master | cut -f1); [ -n "$sha" ] || { log "ls-remote failed"; return 0; }
  [ "$sha" = "$(prev sha)" ] && [ "$(prev status)" != error ] && { clockonly "$sha"; return 0; }  # an error (clone/sync) retries next tick; same sha = clock-only
  # clone on disk (~/.cache, ext4), never tmpfs /tmp (the inode trap); TMPDIR lives inside it. The unit is single-instance,
  # so any other r7-smg.* dir is a leak from a stopped run (RETURN traps do not fire on SIGTERM): sweep it first.
  local x; for x in "$HOME"/.cache/r7-smg.*; do [ -d "$x" ] && { rm -rf "$x"; log "swept leaked clone $x"; }; done
  D=$(mktemp -d "$HOME/.cache/r7-smg.XXXX"); trap 'rm -rf "$D"' RETURN; trap 'rm -rf "$D"; exit 143' TERM INT
  if ! git clone -q --depth 1 -b master "$URL" "$D/s" || [ "$(git -C "$D/s" rev-parse HEAD)" != "$sha" ]; then decide "$sha" 99 "clone failed or master moved"; return 0; fi
  mkdir -p "$D/h" "$D/t"
  export UV_PYTHON=3.14 UV_CACHE_DIR=$HOME/.cache/uv
  # sync keeps the REAL HOME: synthorg pins private git deps (j0yen/pybuild) that need the git credential helper; it writes
  # only the clone .venv + the uv cache. Every gate part below runs with the throwaway HOME.
  if ! (cd "$D/s" && TMPDIR=$D/t uv sync -q) > "$D/sync.out" 2>&1; then cp "$D/sync.out" "$ST/r7-synthorg-master-gate.sync.last"; decide "$sha" 99 "uv sync failed: $(grep -m1 -iE "error|failed" "$D/sync.out" | cut -c1-100)"; return 0; fi
  cp "$D/sync.out" "$ST/r7-synthorg-master-gate.sync.last" 2>/dev/null
  local hb; clocklint "$D"; clockfrom "$D"; clockbeat "$D" & hb=$!   # fresh clock now (this sha's state row lands at the end), re-linted every 10 min during the gate
  parts=$(HOME=$D/h XDG_CONFIG_HOME=$D/h/.config TMPDIR=$D/t gate "$D"); rc=$?
  kill $hb 2>/dev/null; clocklint "$D"; CLK=$(mkclock "$D/promise.clock.out" "$(cat "$D/expected")")
  # measured cost (Fable NEEDS-READ b249): this unit's cgroup memory.peak vs its MemoryMax, in the saved parts
  local cg pk mx; cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup); pk=$(cat "$cg/memory.peak" 2>/dev/null); mx=$(cat "$cg/memory.max" 2>/dev/null)
  [ -n "$pk" ] && parts="$parts mem_peak_mib=$((pk/1048576)) mem_max=${mx:-?}"
  decide "$sha" "$rc" "$parts"
}
selftest() {
  local S fail=0; S=$(mktemp -d); OUT=$S/out.json; LOG=$S/log; NOTIFY=$S/notify
  chk() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
  decide aaaa 0 "all=0"; chk '[ "$(prev status)" = green ] && [ ! -s "$NOTIFY" ]' "first green -> saved, no notify"
  decide bbbb 1 "ruff=1"; chk '[ "$(prev status)" = red ] && grep -q "RED master bbbb" "$NOTIFY"' "red -> notify"
  : > "$NOTIFY"; decide cccc 1 "ruff=1"; chk 'grep -q RED "$NOTIFY"' "red again -> notify again"
  : > "$NOTIFY"; decide dddd 0 "all=0"; chk 'grep -q "GREEN master dddd (was red)" "$NOTIFY"' "red -> green transition notifies"
  : > "$NOTIFY"; decide eeee 0 "all=0"; chk '[ ! -s "$NOTIFY" ]' "green -> green silent"
  decide ffff 99 "clone failed"; chk '[ "$(prev status)" = error ] && grep -q ERROR "$NOTIFY"' "error -> notify"
  local y=$S/g/s/.github/workflows/gate.yml; mkdir -p "${y%/*}"
  printf '      - run: uv run ruff check .\n      - run: uv run mypy src\n        run: uv run synthorg promise lint\n        run: uv run pytest -m "not flaky"\n        env:\n          SYNTHORG_LOAD_GUARD: "1"\n        run: uv run pytest -m flaky --reruns 2 --reruns-delay 5\n        continue-on-error: true\n        run: uv run pytest -m "not flaky and not slow"\n        run: |\n' > "$y"
  out=$(argvdrift "$y"); rc=$?; chk '[ $rc = 0 ]' "argv: gate.yml matching EXPECT -> rc 0"
  cp "$y" "$y.ok"; echo '      - run: uv run synthorg new-lint' >> "$y"; sed -i '/mypy src/d' "$y"; out=$(argvdrift "$y"); rc=$?
  chk '[ $rc = 1 ] && echo "$out" | grep -qF "+synthorg new-lint" && echo "$out" | grep -qF -- "-mypy src"' "argv: added + removed CI command -> rc 1, both named"
  out=$(argvdrift "$S/nope.yml"); rc=$?; chk '[ $rc = 1 ] && echo "$out" | grep -qF -- "-ruff check ."' "argv: missing gate.yml -> rc 1"
  sed '/continue-on-error/d' "$y.ok" > "$y"; out=$(argvdrift "$y"); rc=$?
  chk '[ $rc = 1 ] && echo "$out" | grep -qF -- "-continue-on-error on flaky lane"' "argv: flaky lane loses continue-on-error -> rc 1, named"
  sed '/SYNTHORG_LOAD_GUARD/d' "$y.ok" > "$y"; out=$(argvdrift "$y"); rc=$?
  chk '[ $rc = 1 ] && echo "$out" | grep -qF -- "-env SYNTHORG_LOAD_GUARD=1 on main lane"' "argv: main lane loses SYNTHORG_LOAD_GUARD -> rc 1, named"
  mv "$y.ok" "$y"; uv() { case "$*" in *'not flaky'*) echo "lg=${SYNTHORG_LOAD_GUARD:-unset}" ;; *) echo fine ;; esac; return 0; }; timeout() { shift; "$@"; }
  parts=$(gate "$S/g"); rc=$?; unset -f uv timeout
  chk '[ $rc = 0 ] && echo "$parts" | grep -q "argv=0(gate.yml argv matches)" && echo "$parts" | grep -q "pytest=0(lg=1)"' "gate: all parts clean -> rc 0; main lane ran with SYNTHORG_LOAD_GUARD=1"
  uv() { case "$*" in *'-m flaky'*) echo "2 failed"; return 1 ;; *) echo fine; return 0 ;; esac; }; timeout() { shift; "$@"; }
  parts=$(gate "$S/g"); rc=$?; unset -f uv timeout
  chk '[ $rc = 0 ] && echo "$parts" | grep -q "pytestflaky=1(2 failed) timeouts=0 report-only"' "gate: red flaky lane is reported, never red (continue-on-error)"
  uv() { case "$*" in *ruff*) echo "Found 3 errors."; return 1 ;; *) echo fine; return 0 ;; esac; }; timeout() { shift; "$@"; }
  parts=$(gate "$S/g"); rc=$?; unset -f uv timeout
  chk '[ $rc = 1 ] && echo "$parts" | grep -q "ruff=1(Found 3 errors.)" && echo "$parts" | grep -q "pytest=0(fine) timeouts=0"' "gate: one part red -> rc 1, part named"
  uv() { case "$*" in *pytest*) echo "E   Failed: Timeout >600.0s"; echo "1 passed"; return 0 ;; *) echo fine; return 0 ;; esac; }; timeout() { shift; "$@"; }
  parts=$(gate "$S/g"); rc=$?; unset -f uv timeout
  chk '[ $rc = 1 ] && echo "$parts" | grep -q "pytest=1(1 passed) timeouts=1"' "gate: a timed-out test is red even when pytest exits 0"
  # --- clock (plint-l3): line present / absent / dash keys, same-sha clock-only tick, failed lint keeps the clock
  local L=$S/lint.out c
  printf 'noise\npromise-lint-clock: surface_age_days=7 expired_allow=2 expired_keys=host.a.b,host.c.d\nOK\n' > "$L"; c=$(mkclock "$L" 1)
  chk 'echo "$c" | python3 -I -c "import json,sys; c=json.load(sys.stdin); assert c[\"line_present\"] and c[\"surface_age_days\"]==7 and c[\"expired_allow\"]==2 and c[\"expired_keys\"]==[\"host.a.b\",\"host.c.d\"] and c[\"expected\"] is True and c[\"ts\"]"' "clock: line present -> parsed fields, expected=true, ts"
  printf 'promise lint: 0 errors\n' > "$L"; c=$(mkclock "$L" 0)
  chk 'echo "$c" | python3 -I -c "import json,sys; c=json.load(sys.stdin); assert c[\"line_present\"] is False and c[\"surface_age_days\"] is None and c[\"expired_keys\"]==[] and c[\"expected\"] is False"' "clock: line absent -> line_present=false, expected=false"
  printf 'promise-lint-clock: surface_age_days=0 expired_allow=0 expired_keys=-\n' > "$L"; c=$(mkclock "$L" 1)
  chk 'echo "$c" | python3 -I -c "import json,sys; c=json.load(sys.stdin); assert c[\"line_present\"] and c[\"expired_keys\"]==[] and c[\"expired_allow\"]==0"' "clock: expired_keys=- -> empty list"
  c=$(mkclock "$S/nope.out" 1); chk 'echo "$c" | grep -q "\"line_present\": false"' "clock: missing lint output file -> line_present=false"
  decide gggg 0 "all=0"; : > "$NOTIFY"; local before; before=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("clock",None); print(json.dumps(d,sort_keys=True))' "$OUT")
  git() { printf 'gggg\trefs/heads/master\n'; }
  lintclone() { printf 'promise-lint-clock: surface_age_days=3 expired_allow=1 expired_keys=k1\n' > "$2/promise.clock.out"; echo 1 > "$2/expected"; return 0; }
  main
  chk '[ "$(prev status)" = green ] && [ "$(prev sha)" = gggg ] && [ ! -s "$NOTIFY" ] && [ "$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); c=d.pop(\"clock\"); print(json.dumps(d,sort_keys=True)); assert c[\"expired_keys\"]==[\"k1\"] and c[\"ts\"]" "$OUT")" = "$before" ]' "clock: same-sha tick rewrites ONLY clock (sha/status/parts/ts/notify untouched)"
  lintclone() { printf 'no clock line here\n' > "$2/promise.clock.out"; echo 0 > "$2/expected"; return 1; }
  main; chk 'python3 -I -c "import json,sys; c=json.load(open(sys.argv[1]))[\"clock\"]; assert c[\"expired_keys\"]==[\"k1\"]" "$OUT"' "clock: clone/sync failure on a same-sha tick keeps the previous clock"
  lintclone() { printf 'promise lint: ok (exit 1 ignored)\n' > "$2/promise.clock.out"; echo 1 > "$2/expected"; return 0; }
  main; chk 'python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); c=d[\"clock\"]; assert c[\"line_present\"] is False and c[\"expected\"] is True and d[\"status\"]==\"green\"" "$OUT"' "clock: line absent on a same-sha tick -> line_present=false, expected=true, status still green"
  unset -f git lintclone
  CLK='{"line_present":true,"ts":"x"}'; decide hhhh 0 "all=0"; unset CLK
  chk '[ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[\"clock\"][\"ts\"])" "$OUT")" = x ]' "clock: decide saves the clock passed in CLK"
  decide iiii 99 "clone failed"; chk '[ "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))[\"clock\"][\"ts\"])" "$OUT")" = x ]' "clock: an error save carries the previous clock over"
  rm -rf "$S"; [ $fail = 0 ] && echo "selftest ok" || echo "selftest FAIL"; return $fail
}
if [ "$SELF" = 1 ]; then selftest; exit $?; fi
main
