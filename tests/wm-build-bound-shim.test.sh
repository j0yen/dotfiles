#!/usr/bin/env bash
# wm-build-bound-shim.test.sh - the wm-build memory-bound shim (.local/bin/wm-build-bound-shim.sh) and its install/promote tool
# (.local/bin/wm-build-shim-ctl.sh). No real wm-build, no real systemd-run: WM_BUILD_REAL points at a stub that records its argv, and a fake
# systemd-run on PATH records its args (and XDG_RUNTIME_DIR) then execs the rest.
# --version FAKE for the ctl tests: tiny sh scripts stand in for ELF binaries; WM_BUILD_SHIM_ELF_MAGIC='#!/b' makes ctl treat a file whose first
# 4 bytes are "#!/b" as an ELF, and each stub's --version prints "wm-build stub <ver>". One test uses a real ELF (a copy of /bin/true) with the default magic.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shim=$here/.local/bin/wm-build-bound-shim.sh
ctl=$here/.local/bin/wm-build-shim-ctl.sh
units=$here/.config/systemd/user
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

bash -n "$shim" && bash -n "$ctl" && ok "bash -n" || bad "bash -n"
[ -x "$shim" ] && [ -x "$ctl" ] && ok "scripts executable" || bad "scripts executable"

# --- stubs --------------------------------------------------------------------------------------------------------------------------
mkdir -p "$t/fakebin" "$t/rundir"
real=$t/real-stub
cat > "$real" <<'STUB'
#!/bin/sh
echo "STUB-RAN" >> "${STUB_LOG:-/dev/null}"
echo "REAL-ARGV: $*"
exit "${STUB_RC:-0}"
STUB
chmod 755 "$real"
cat > "$t/fakebin/systemd-run" <<'FAKE'
#!/bin/sh
echo "ARGS: $*" >> "$SDR_LOG"
echo "XDG: ${XDG_RUNTIME_DIR:-}" >> "$SDR_LOG"
while [ "$1" != "--" ]; do shift; done; shift
exec "$@"
FAKE
chmod 755 "$t/fakebin/systemd-run"
: > "$t/rundir/bus"   # a fake bus socket (the shim only tests existence)

runshim() { # <argv...>; env: XDG_RUNTIME_DIR unset unless given by caller
  env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" \
      STUB_LOG="$t/stub.log" SDR_LOG="$t/sdr.log" "$shim" "$@"
}

# --- the shim's own selftest --------------------------------------------------------------------------------------------------------
out=$("$shim" --selftest 2>&1); rc=$?
if [ $rc -eq 0 ] && [[ $out == "selftest OK n="* ]]; then ok "shim --selftest ($out)"; else bad "shim --selftest rc=$rc $out"; fi

# --- classifier table through the shim: bound (goes via systemd-run with the limits) vs pass (straight to the stub) --------------------
bound_cases=(
  "status" "runs" "status --json" "--state-dir /x status --brief" "--config /c runs" "--prd-dir /p --state-dir /s status"
  "-j4 status" "--json status" "--set a=status status" "--state-dir=/x runs" "status --flakes --days 3"
)
pass_cases=(
  "run close 5 --reason status" "run redrive 5 --from land" "drive --run 1042" "daemon" "--version" "run show 5" "builder probe" "queue"
  "--set status=1 queue" "--config status queue"
)
for c in "${bound_cases[@]}"; do
  : > "$t/sdr.log"; : > "$t/stub.log"
  # shellcheck disable=SC2086
  out=$(runshim $c 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -q "MemoryMax=2G" "$t/sdr.log" && grep -q "MemorySwapMax=0" "$t/sdr.log" \
     && grep -q -- "--user --scope --quiet --collect" "$t/sdr.log" && [ "$out" = "REAL-ARGV: $c" ]; then ok "bound: $c"; else bad "bound: $c (rc=$rc out=$out sdr=$(tr '\n' '|' < "$t/sdr.log"))"; fi
done
for c in "${pass_cases[@]}"; do
  : > "$t/sdr.log"
  # shellcheck disable=SC2086
  out=$(runshim $c 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$t/sdr.log" ] && [ "$out" = "REAL-ARGV: $c" ]; then ok "pass-through: $c"; else bad "pass-through: $c (rc=$rc out=$out)"; fi
done
# exit code and argv spacing survive
STUB_RC=7 runshim daemon >/dev/null 2>&1; eq "pass-through keeps exit code" $? 7
out=$(runshim run close 5 --reason "two words" 2>&1); eq "pass-through keeps argv words" "$out" "REAL-ARGV: run close 5 --reason two words"

# --- XDG_RUNTIME_DIR export: unset + rundir/bus exists -> exported; already set -> kept ------------------------------------------------
: > "$t/sdr.log"; runshim status >/dev/null 2>&1
eq "XDG_RUNTIME_DIR exported from rundir" "$(grep '^XDG:' "$t/sdr.log")" "XDG: $t/rundir"
: > "$t/sdr.log"
env PATH="$t/fakebin:$PATH" XDG_RUNTIME_DIR="$t/rundir" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR=/nonexistent SDR_LOG="$t/sdr.log" "$shim" runs >/dev/null 2>&1
eq "preset XDG_RUNTIME_DIR with a bus is kept" "$(grep '^XDG:' "$t/sdr.log")" "XDG: $t/rundir"

# --- refusal: no bus -> exit 2, stub NOT run, never unbounded ------------------------------------------------------------------------
: > "$t/stub.log"; : > "$t/sdr.log"
out=$(env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/norun" STUB_LOG="$t/stub.log" SDR_LOG="$t/sdr.log" "$shim" status 2>&1); rc=$?
eq "no bus: exit 2" "$rc" 2
[[ $out == *"status/runs refused, no memory bound available; read ~/.cache/fleet-dash/status.json"* ]] && ok "no bus: refusal line" || bad "no bus: refusal line ($out)"
[ ! -s "$t/stub.log" ] && [ ! -s "$t/sdr.log" ] && ok "no bus: stub not run" || bad "no bus: stub ran"
# systemd-run missing (a PATH with only the tools the shim needs)
mkdir -p "$t/minbin"; for b in id dirname readlink env; do ln -sf "$(command -v $b)" "$t/minbin/$b"; done
: > "$t/stub.log"
env -u XDG_RUNTIME_DIR PATH="$t/minbin" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" STUB_LOG="$t/stub.log" "$(command -v bash)" "$shim" runs >/dev/null 2>&1
rc=$?
eq "no systemd-run: exit 2" "$rc" 2
[ ! -s "$t/stub.log" ] && ok "no systemd-run: stub not run" || bad "no systemd-run: stub ran"
# a pass-through call still works with no bus
out=$(env -u XDG_RUNTIME_DIR PATH="$t/minbin" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/norun" "$(command -v bash)" "$shim" daemon 2>&1)
eq "no bus: pass-through unaffected" "$out" "REAL-ARGV: daemon"
# REAL defaults to wm-build.real beside the (resolved) script
mkdir -p "$t/beside"; cp "$shim" "$t/beside/wm-build"; cp "$real" "$t/beside/wm-build.real"
out=$(env -u WM_BUILD_REAL "$t/beside/wm-build" daemon 2>&1); eq "default REAL = wm-build.real beside the shim" "$out" "REAL-ARGV: daemon"

# --- ctl: stub "ELF" binaries (see header) -------------------------------------------------------------------------------------------
export WM_BUILD_SHIM_ELF_MAGIC='#!/b' WM_BUILD_SHIM_STATE=$t/state WM_BUILD_SHIM_EXPIRES=2999-01-01 WM_BUILD_SHIM_TODAY=2026-10-24
mkstub() { # <path> <version>
  # shellcheck disable=SC2016
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "wm-build stub %s"; exit 0; }\necho STUB-RAN "$@"\n' "$2" > "$1"; chmod 755 "$1"
}
ver() { "$1" --version 2>/dev/null; }
d=$t/cargo-bin; mkdir -p "$d"
mkstub "$d/wm-build" 0.1.0; mkstub "$t/cand" 0.2.0; printf 'not an elf\n' > "$t/nonelf"
c() { "$ctl" --dir "$d" "$@"; }

eq "check before install" "$(c check)" missing-real
ino_before=$(stat -c %i "$d/wm-build")
c install >/dev/null 2>&1; eq "install rc" $? 0
eq "install: hard-link inode kept (old path inode == .real)" "$(stat -c %i "$d/wm-build.real")" "$ino_before"
eq "install: path is the shim, not the stub" "$(cmp -s "$d/wm-build" "$shim" && echo same)" same
eq "install: --version through shim unchanged" "$(ver "$d/wm-build")" "wm-build stub 0.1.0"
"$d/wm-build" --selftest >/dev/null 2>&1; eq "install: shim --selftest at the path" $? 0
eq "check ok" "$(c check)" ok
c check >/dev/null; eq "check ok exit 0" $? 0
[[ $(cat "$t/state") == *" ok" ]] && ok "check writes the state file with a timestamp" || bad "state file ($(cat "$t/state"))"

# place: shim intact, .real takes the new version (the promote-target no-drift test)
shim_sum=$(sha256sum "$d/wm-build" | cut -d' ' -f1)
out=$(c place "$t/cand" 2>&1); eq "place rc/print" "$out" "placed $d/wm-build.real wm-build stub 0.2.0"
eq "place: shim untouched" "$(sha256sum "$d/wm-build" | cut -d' ' -f1)" "$shim_sum"
eq "place: .real has the new version" "$(ver "$d/wm-build.real")" "wm-build stub 0.2.0"
eq "place: through the shim shows the new version" "$(ver "$d/wm-build")" "wm-build stub 0.2.0"
c place "$t/nonelf" >/dev/null 2>&1; eq "place refuses a non-ELF candidate" $? 1

# rollback
c rollback >/dev/null 2>&1; eq "rollback rc" $? 0
eq "rollback: path is the real binary again" "$(ver "$d/wm-build")" "wm-build stub 0.2.0"
[ ! -e "$d/wm-build.real" ] && ok "rollback: .real consumed by the rename" || bad "rollback: .real still there"
c rollback >/dev/null 2>&1; eq "rollback refuses when the path is an ELF" $? 1

# promote overwrote the shim: elf-at-path; plain install refuses (version mismatch), --replace fixes
c install >/dev/null 2>&1; mkstub "$d/wm-build" 0.3.0   # a promote mv'd a new binary over the shim
eq "check elf-at-path" "$(c check)" elf-at-path
c check >/dev/null; eq "check elf-at-path exit 1" $? 1
c install >/dev/null 2>&1; eq "install refuses a version mismatch without --replace" $? 1
eq "refused install left .real alone" "$(ver "$d/wm-build.real")" "wm-build stub 0.2.0"
c install --replace >/dev/null 2>&1; eq "install --replace rc" $? 0
eq "install --replace: .real is the new version" "$(ver "$d/wm-build.real")" "wm-build stub 0.3.0"
eq "check ok after --replace" "$(c check)" ok

# obsolete / expired / missing-real
eq "check obsolete (.real >= OBSOLETE_AT)" "$(WM_BUILD_SHIM_OBSOLETE_AT=0.3.0 c check)" obsolete
eq "check ok below OBSOLETE_AT" "$(WM_BUILD_SHIM_OBSOLETE_AT=0.4.0 c check)" ok
eq "check expired" "$(WM_BUILD_SHIM_TODAY=2999-01-02 c check)" expired
WM_BUILD_SHIM_TODAY=2999-01-02 c place "$t/cand" >/dev/null 2>&1; eq "expired place goes to the path" "$(ver "$d/wm-build")" "wm-build stub 0.2.0"
d2=$t/cb2; mkdir -p "$d2"; mkstub "$d2/wm-build" 0.1.0
WM_BUILD_SHIM_TODAY=2999-01-02 "$ctl" --dir "$d2" install >/dev/null 2>&1; eq "expired install refuses" $? 1
eq "expired install left the path alone" "$(ver "$d2/wm-build")" "wm-build stub 0.1.0"
d3=$t/cb3; mkdir -p "$d3"; mkstub "$d3/wm-build" 0.1.0
eq "check missing-real (no .real)" "$("$ctl" --dir "$d3" check)" missing-real
printf 'plain\n' > "$d3/wm-build"; "$ctl" --dir "$d3" install >/dev/null 2>&1; eq "install refuses a non-ELF path" $? 1

# real ELF + default magic: a copy of /bin/true (end to end, nothing faked)
unset WM_BUILD_SHIM_ELF_MAGIC
d4=$t/cb4; mkdir -p "$d4"; cp /bin/true "$d4/wm-build"
vwant=$("$d4/wm-build" --version | head -n1)
"$ctl" --dir "$d4" install >/dev/null 2>&1; eq "real ELF: install rc" $? 0
eq "real ELF: --version through the shim" "$("$d4/wm-build" --version | head -n1)" "$vwant"
eq "real ELF: check ok" "$("$ctl" --dir "$d4" check)" ok

# --- guard26 refresh (aide 10-30): no loop with the RB PATH shim, daemon-side subcommands never bound, fires log, new expiry ----------
# NO-LOOP: REAL is resolved from the shim's own readlink -f path, never through PATH. A decoy "PATH shim" ahead on PATH named wm-build
# (what ~/.local/bin/wm-build is) would log LOOP if the shim re-resolved wm-build via PATH. Invoked via a symlink found by PATH lookup.
mkdir -p "$t/nl/cargo-bin" "$t/nl/link" "$t/nl/decoy"
cp "$shim" "$t/nl/cargo-bin/wm-build"; cp "$real" "$t/nl/cargo-bin/wm-build.real"
ln -s "$t/nl/cargo-bin/wm-build" "$t/nl/link/wm-build"
printf '#!/bin/sh\necho LOOP >> "%s/nl/loop.log"\nexit 99\n' "$t" > "$t/nl/decoy/wm-build"; chmod 755 "$t/nl/decoy/wm-build"
: > "$t/nl/loop.log"
out=$(env -u WM_BUILD_REAL PATH="$t/nl/link:$t/nl/decoy:$PATH" STUB_LOG="$t/stub.log" wm-build daemon 2>&1); rc=$?
eq "no loop: symlink via PATH, WM_BUILD_REAL unset -> wm-build.real beside the target" "$out" "REAL-ARGV: daemon"
[ ! -s "$t/nl/loop.log" ] && ok "no loop: decoy PATH shim never re-entered" || bad "no loop: decoy PATH shim was re-entered"
: > "$t/sdr.log"
out=$(env -u WM_BUILD_REAL -u XDG_RUNTIME_DIR PATH="$t/fakebin:$t/nl/decoy:$PATH" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="$t/nl/fires0.log" "$t/nl/link/wm-build" status 2>&1)
eq "no loop: bound branch hands systemd-run the real beside the shim" "$out" "REAL-ARGV: status"
grep -q -- "-- $t/nl/cargo-bin/wm-build.real status" "$t/sdr.log" && ok "no loop: systemd-run argv names wm-build.real by absolute path" || bad "no loop: systemd-run argv ($(tr '\n' '|' < "$t/sdr.log"))"
[ ! -s "$t/nl/loop.log" ] && ok "no loop: decoy untouched on the bound path" || bad "no loop: decoy hit on the bound path"

# F2: every non-status/runs subcommand reaches the real with argv intact, same PID (exec), no systemd-run scope wrap, no fires line
cat > "$t/pidreal" <<'PIDSTUB'
#!/bin/sh
echo "PID=$$ ARGV=$*"
PIDSTUB
chmod 755 "$t/pidreal"
cat > "$t/pidwrap" <<'PIDWRAP'
#!/bin/bash
# prints this shell's PID after exec'ing the shim: the stub must report the same PID
echo "WRAPPID=$$"
exec "$@"
PIDWRAP
chmod 755 "$t/pidwrap"
f2_cases=("daemon" "daemon --foreground" "drive --run 1042" "driver --run 7" "gate run 5" "land 5 --now" "place /tmp/cand" "run redrive 5 --from land" "--version" "-V" "--state-dir /x daemon" "--config /c --set a=b land 9")
for c in "${f2_cases[@]}"; do
  : > "$t/sdr.log"; rm -f "$t/f2fires.log"
  # shellcheck disable=SC2086
  out=$(env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$t/pidreal" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="$t/f2fires.log" "$t/pidwrap" "$shim" $c 2>&1)
  wp=$(printf '%s\n' "$out" | sed -n 's/^WRAPPID=//p'); sp=$(printf '%s\n' "$out" | sed -n 's/^PID=\([0-9]*\) .*/\1/p')
  av=$(printf '%s\n' "$out" | sed -n 's/^PID=[0-9]* ARGV=//p')
  if [ -n "$wp" ] && [ "$wp" = "$sp" ] && [ "$av" = "$c" ] && [ ! -s "$t/sdr.log" ] && [ ! -e "$t/f2fires.log" ]; then ok "F2 exec pass-through: $c"; else bad "F2 exec pass-through: $c (out=$out sdr=$(tr '\n' '|' < "$t/sdr.log"))"; fi
done

# F5: fires log, one line per bound call, written before systemd-run; unset the log dir -> still runs; unwritable -> still runs
rm -f "$t/fires.log"; : > "$t/sdr.log"
out=$(env -u XDG_RUNTIME_DIR SSH_CLIENT="203.0.113.9 5555 22" PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="$t/fires/sub/fires.log" "$shim" runs --json 2>&1); rc=$?
eq "F5: bound call still runs with the fires dir created" "$out|$rc" "REAL-ARGV: runs --json|0"
fl=$t/fires/sub/fires.log
eq "F5: exactly one fires line" "$(wc -l < "$fl")" 1
[[ $(cat "$fl") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+\ sub=runs\ ppid=[0-9]+\ comm=.+\ cmdline=.*\ ssh=203\.0\.113\.9\ 5555\ 22$ ]] && ok "F5: line carries ts, subcommand, ppid, comm, cmdline, ssh" || bad "F5: line shape ($(cat "$fl"))"
env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="$fl" "$shim" status >/dev/null 2>&1
eq "F5: second bound call appends" "$(wc -l < "$fl")" 2
[[ $(tail -n1 "$fl") == *"ssh=none" ]] && ok "F5: SSH_CLIENT unset -> none" || bad "F5: ssh=none ($(tail -n1 "$fl"))"
secret=SHIM_FIRES_CANARY_ENV_VALUE
env -u XDG_RUNTIME_DIR CANARY_VAR=$secret PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="$fl" "$shim" status >/dev/null 2>&1
grep -q "$secret" "$fl" && bad "F5: environment leaked into the fires log" || ok "F5: environment never written"
out=$(env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/rundir" SDR_LOG="$t/sdr.log" WM_BUILD_SHIM_FIRES="/proc/nonexistent/x/fires.log" "$shim" status 2>&1); rc=$?
eq "F5: unwritable fires log does not block the call" "$out|$rc" "REAL-ARGV: status|0"
out=$(env -u XDG_RUNTIME_DIR PATH="$t/fakebin:$PATH" WM_BUILD_REAL="$real" WM_BUILD_SHIM_RUNDIR="$t/norun" WM_BUILD_SHIM_FIRES="$t/fires/refused.log" "$shim" status 2>&1); rc=$?
eq "F5: refusal path still exits 2 with the fires log on" "$rc" 2

# new expiry 2026-11-14 (default, no WM_BUILD_SHIM_EXPIRES): not expired on the day, expired the day after; text agrees everywhere
d5=$t/cb5; mkdir -p "$d5"; mkstub "$d5/wm-build" 0.1.0
env -u WM_BUILD_SHIM_EXPIRES WM_BUILD_SHIM_ELF_MAGIC="#!/b" WM_BUILD_SHIM_TODAY=2026-11-14 "$ctl" --dir "$d5" install >/dev/null 2>&1; eq "expiry default: install allowed on 2026-11-14" $? 0
eq "expiry default: 2026-11-14 not expired" "$(env -u WM_BUILD_SHIM_EXPIRES WM_BUILD_SHIM_ELF_MAGIC="#!/b" WM_BUILD_SHIM_TODAY=2026-11-14 "$ctl" --dir "$d5" check)" ok
eq "expiry default: 2026-11-15 expired" "$(env -u WM_BUILD_SHIM_EXPIRES WM_BUILD_SHIM_ELF_MAGIC="#!/b" WM_BUILD_SHIM_TODAY=2026-11-15 "$ctl" --dir "$d5" check)" expired
n_old=$(grep -c '2026-10-31' "$shim" "$ctl" "$units"/wm-build-shim-check.service "$units"/wm-build-shim-check.timer | awk -F: '{s+=$2} END{print s}')
eq "expiry text: no 2026-10-31 left" "$n_old" 0
[ "$(grep -l '2026-11-14' "$shim" "$ctl" "$units"/wm-build-shim-check.service "$units"/wm-build-shim-check.timer | wc -l)" = 4 ] && ok "expiry text: 2026-11-14 in shim, ctl, both units" || bad "expiry text 2026-11-14"

# ctl --selftest and the units
out=$(WM_BUILD_SHIM_ELF_MAGIC='' "$ctl" --selftest 2>&1); rc=$?
if [ $rc -eq 0 ] && [[ $out == "selftest OK n="* ]]; then ok "ctl --selftest ($out)"; else bad "ctl --selftest rc=$rc $out"; fi
s=$units/wm-build-shim-check.service tm=$units/wm-build-shim-check.timer
grep -qx 'ConditionPathExists=%h/.cargo/bin/wm-build.real' "$s" && grep -qx 'Type=oneshot' "$s" && grep -qx 'ExecStart=%h/.local/bin/wm-build-shim-ctl.sh check' "$s" \
  && ok "service: oneshot check, conditional on wm-build.real" || bad "service fields"
grep -qx 'OnUnitActiveSec=5min' "$tm" && grep -qx 'WantedBy=timers.target' "$tm" && ok "timer: every 5 min" || bad "timer fields"

echo "passed=$pass failed=$fail"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
