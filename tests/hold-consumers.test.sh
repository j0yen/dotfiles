#!/usr/bin/env bash
# hold-consumers.test.sh: hermetic test of .local/bin/aide-hold.sh (1071 M4). No real ssh, no real systemctl, no real wm-build.
# A PATH shim `ssh` runs the remote command locally with HOME = a per-host fake home and PATH = a per-host stub bin, so flag and marker files are real files
# and only `systemctl` / `wm-build` are stubs. The FIRST assertions replay tests/fixtures/1071/hosts-hold-read-20261031T0250.txt: orch's `systemctl --user show -p
# ConditionPathExists` prints EMPTY (a probe built on `show -p` reads orch as none) while `systemctl --user cat` returns the 90-grading-hold.conf drop-in (txt lines 27-29).
# Run: bash tests/hold-consumers.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
AH=$repo/.local/bin/aide-hold.sh
TXT=$here/fixtures/1071/hosts-hold-read-20261031T0250.txt
SHARED=$here/fixtures/shared/hold-consumers.json
BASE=$(mktemp -d "${TMPDIR:-/tmp}/hold-consumers-test.XXXXXX") || exit 2
trap 'chmod -R u+w "$BASE" 2>/dev/null; rm -rf -- "${BASE:?}"' EXIT
fail=0
ok() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
NOW=1793440200
HOSTLIST="carbon orch redbaron ryzen7"

# mk NAME: a sandbox holding the captured 02:50 AM 10-31 state
mk() {
  S=$BASE/$1; mkdir -p "$S/bin" "$S/out"
  cat > "$S/bin/ssh" <<'EOS'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in -o) shift 2;; -*) shift;; *) break;; esac; done
host=$1; shift
case ",${STUB_SSH_FAIL:-}," in *,"$host",*) echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255;; esac
printf '%s %s\n' "$host" "$*" >> "$STUB_ROOT/ssh.calls"
HOME="$STUB_ROOT/homes/$host" PATH="$STUB_ROOT/hostbin/$host:$PATH" exec bash -c "$*"
EOS
  chmod +x "$S/bin/ssh"; : > "$S/ssh.calls"
  local h
  for h in $HOSTLIST; do mkdir -p "$S/homes/$h/.local/bin" "$S/homes/$h/.local/state/aide" "$S/homes/$h/.cargo/bin" "$S/hostbin/$h"; done
  # flags as captured: orch, redbaron present; ryzen7 and carbon absent
  printf 'APPROVAL=105\nREASON=captured\nEXPIRES=\n' > "$S/homes/orch/.local/state/aide/grading-hold"
  printf 'APPROVAL=108\nREASON=captured\nEXPIRES=\n' > "$S/homes/redbaron/.local/state/aide/grading-hold"
  # the orch drop-in text comes from the captured txt (lines 27-29), the unit files around it are the stub's
  { for u in on-land release-checkout release catchup; do
      printf '# /home/jsy/.config/systemd/user/mcphost-deploy-%s.path\n[Path]\nPathChanged=/x\n\n' "$u"
      printf '# /home/jsy/.config/systemd/user/mcphost-deploy-%s.service\n[Service]\nExecStart=/bin/true\n\n' "$u"
      printf '# /home/jsy/.config/systemd/user/mcphost-deploy-%s.service.d/90-grading-hold.conf\n' "$u"
      sed -n 27,29p "$TXT"; printf '\n'
    done; } > "$S/orch-cat.txt"
  cat > "$S/hostbin/orch/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$STUB_ROOT/systemctl.calls"
case "$*" in
  "--user cat mcphost-deploy-*") cat "$STUB_ROOT/orch-cat.txt";;
  "--user show -p ConditionPathExists "*) : ;;
  *) exit 1;;
esac
EOS
  for h in redbaron ryzen7; do
    cat > "$S/hostbin/$h/systemctl" <<'EOS'
#!/bin/bash
case "$*" in
  "--user is-active rb-land-hold-watch.timer") echo active;;
  *) exit 1;;
esac
EOS
    # the watcher as captured: keyed on premise-lifted, never reads the canonical flag
    printf '#!/bin/bash\n# enforces while ~/.local/state/rb-land-hold/premise-lifted is ABSENT and before EXPIRES 2026-11-07T20:00Z\n' > "$S/homes/$h/.local/bin/rb-land-hold-watch.sh"
  done
  chmod +x "$S"/hostbin/*/systemctl; : > "$S/systemctl.calls"
  OUTJ=$S/out/hold-consumers.json
}
run() { # args -> aide-hold.sh in the sandbox
  env -i HOME="$S/homes/carbon" PATH="$S/bin:/usr/bin:/bin" TZ=UTC STUB_ROOT="$S" STUB_SSH_FAIL="${FAILHOSTS:-}" \
    AIDE_HOLD_OUT="$OUTJ" AIDE_HOLD_NOW="$NOW" AIDE_HOLD_SSH="$S/bin/ssh" bash "$AH" "$@"
}
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]][sys.argv[3]])' "$OUTJ" "$1" "$2"; }
repoint() { # make redbaron + ryzen7 watchers and a carbon merge script read the canonical path
  local h
  for h in redbaron ryzen7; do printf '#!/bin/bash\nf="$HOME/.local/state/aide/grading-hold"\n[ -e "$f" ] && exit 1\n' > "$S/homes/$h/.local/bin/rb-land-hold-watch.sh"; done
  printf '#!/bin/bash\n[ -e "$HOME/.local/state/aide/grading-hold" ]\n' > "$S/homes/carbon/.local/bin/rb-merge.sh"
}

bash -n "$AH" && ok "bash -n aide-hold.sh" 0 || ok "bash -n aide-hold.sh" 1
[ -x "$AH" ] && ok "aide-hold.sh is executable" 0 || ok "aide-hold.sh is executable" 1

# 1. FIRST: replay the captured 02:50 AM state (show -p EMPTY, cat returns the drop-in)
mk captured
run probe >"$S/probe.out" 2>&1; rc=$?
ok "captured: probe exits 0 (rc=$rc)" "$rc"
python3 -I - "$OUTJ" "$SHARED" <<'PY'; ok "captured: probe json == shared hold-consumers.json (orch consumer = drop-in from cat, redbaron present + none, ryzen7 absent, carbon absent)" $?
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
sys.exit(0 if a == b else (print("got", a, "\nwant", b) or 1))
PY
[ "$(jget orch consumer)" = "mcphost-deploy-*.service 90-grading-hold.conf" ] && ok "captured: orch consumer names 90-grading-hold.conf" 0 || ok "captured: orch consumer names 90-grading-hold.conf" 1
[ "$(jget redbaron flag)/$(jget redbaron consumer)" = "present/none" ] && ok "captured: redbaron flag present, consumer none (watcher never reads the flag)" 0 || ok "captured: redbaron flag present, consumer none" 1
[ "$(jget ryzen7 flag)" = absent ] && ok "captured: ryzen7 flag absent" 0 || ok "captured: ryzen7 flag absent" 1
if grep -q 'show' "$S/systemctl.calls"; then ok "captured: probe never calls systemctl show -p" 1; else ok "captured: probe never calls systemctl show -p" 0; fi
grep -q -- "cat mcphost-deploy-\*" "$S/systemctl.calls" && ok "captured: probe read orch with systemctl cat" 0 || ok "captured: probe read orch with systemctl cat" 1
run place --approval 125 --reason "test hold" --expires 2026-11-07T20:00:00Z >"$S/place.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q redbaron "$S/place.out" && ok "captured: place exits non-zero ($rc) and names redbaron" 0 || { ok "captured: place exits non-zero and names redbaron" 1; cat "$S/place.out"; }
[ -e "$S/homes/ryzen7/.local/state/aide/grading-hold" ] && grep -q '^APPROVAL=125$' "$S/homes/ryzen7/.local/state/aide/grading-hold" && ok "captured: place wrote the flag on ryzen7 before proving" 0 || ok "captured: place wrote the flag on ryzen7 before proving" 1

# 2. repointed watchers + carbon reader -> place exits 0 with a consumer on every host
mk repointed; repoint
run place --approval 125 --reason "test hold" --expires 2026-11-07T20:00:00Z >"$S/place.out" 2>&1; rc=$?
ok "repointed: place exits 0 (rc=$rc)" "$rc"
all=0; for h in $HOSTLIST; do [ "$(jget $h flag)" = present ] || all=1; [ "$(jget $h consumer)" != none ] || all=1; done
ok "repointed: every host flag=present with a consumer" "$all"
[ "$(jget redbaron consumer)" = rb-land-hold-watch.sh ] && [ "$(jget carbon consumer)" = rb-merge.sh ] && ok "repointed: consumers named (rb-land-hold-watch.sh, rb-merge.sh)" 0 || ok "repointed: consumers named" 1
[ "$(jget redbaron expires)" = 2026-11-07T20:00:00Z ] && ok "repointed: expires read from the flag" 0 || ok "repointed: expires read from the flag" 1
grep -q '^APPROVAL=125$' "$S/homes/orch/.local/state/aide/grading-hold" && ok "repointed: flag written on orch over ssh" 0 || ok "repointed: flag written on orch over ssh" 1
run place --approval x --reason r --expires 2026-11-07 >/dev/null 2>&1; [ $? -eq 64 ] && ok "place with a bad --approval -> 64" 0 || ok "place with a bad --approval -> 64" 1
run bogus >/dev/null 2>&1; [ $? -eq 64 ] && ok "unknown subcommand -> 64" 0 || ok "unknown subcommand -> 64" 1

# 3. wm-build land.hold_file naming the canonical path is a consumer on its own
mk cfgkey
cat > "$S/homes/redbaron/.cargo/bin/wm-build" <<'EOS'
#!/bin/bash
[ "$1 $2" = "config show" ] && { echo "land.max_runs = 2"; echo "land.hold_file = ~/.local/state/aide/grading-hold"; }
EOS
chmod +x "$S/homes/redbaron/.cargo/bin/wm-build"
run probe >/dev/null 2>&1
[ "$(jget redbaron consumer)" = "wm-build land.hold_file" ] && ok "wm-build land.hold_file on the canonical path -> consumer" 0 || ok "wm-build land.hold_file on the canonical path -> consumer" 1

# 4. ssh failure: unread, previous consumer kept, never none; place refuses
mk sshfail; repoint
run place --approval 125 --reason "test hold" --expires 2026-11-07T20:00:00Z >/dev/null 2>&1
FAILHOSTS=ryzen7 run probe >/dev/null 2>&1
[ "$(jget ryzen7 flag)" = unread ] && [ "$(jget ryzen7 consumer)" = rb-land-hold-watch.sh ] && ok "ssh failure: ryzen7 flag unread, previous consumer kept (not none)" 0 || { ok "ssh failure: ryzen7 flag unread, previous consumer kept" 1; cat "$OUTJ"; }
[ "$(jget ryzen7 ts)" = "$NOW" ] && ok "ssh failure: ts is the last good reading" 0 || ok "ssh failure: ts is the last good reading" 1
[ "$(jget redbaron flag)" = present ] && ok "ssh failure: other hosts still read" 0 || ok "ssh failure: other hosts still read" 1
FAILHOSTS=ryzen7 run place --approval 126 --reason r --expires 2026-11-07T20:00:00Z >"$S/place.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q ryzen7 "$S/place.out" && ok "ssh failure: place exits non-zero naming ryzen7" 0 || ok "ssh failure: place exits non-zero naming ryzen7" 1
mk sshfirst; FAILHOSTS=orch run probe >/dev/null 2>&1
[ "$(jget orch flag)/$(jget orch consumer)" = "unread/unread" ] && ok "ssh failure with no previous reading: unread/unread, never none" 0 || ok "ssh failure with no previous reading: unread/unread" 1

# 5. lift
mk lift; repoint
run place --approval 125 --reason "test hold" --expires 2026-11-07T20:00:00Z >/dev/null 2>&1
run lift --approval 125 --reason "hold released" >"$S/lift.out" 2>&1; rc=$?
ok "lift: exits 0 when every flag is gone (rc=$rc)" "$rc"
n=0; for h in $HOSTLIST; do [ -e "$S/homes/$h/.local/state/aide/grading-hold" ] && n=$((n+1)); done
ok "lift: flag removed on all hosts" "$n"
[ -e "$S/homes/redbaron/.local/state/rb-land-hold/premise-lifted" ] && [ -e "$S/homes/ryzen7/.local/state/rb-land-hold/premise-lifted" ] && ok "lift: premise-lifted marker written on redbaron and ryzen7" 0 || ok "lift: premise-lifted marker written" 1
mk liftfail; repoint
run place --approval 125 --reason "test hold" --expires 2026-11-07T20:00:00Z >/dev/null 2>&1
chmod a-w "$S/homes/redbaron/.local/state/aide"   # the flag cannot be removed: a consumer keeps enforcing
run lift --approval 125 --reason "hold released" >"$S/lift.out" 2>&1; rc=$?
chmod u+w "$S/homes/redbaron/.local/state/aide"
[ "$rc" -ne 0 ] && grep -q redbaron "$S/lift.out" && ok "lift with a consumer still enforcing: non-zero ($rc) naming redbaron" 0 || { ok "lift with a consumer still enforcing: non-zero naming redbaron" 1; cat "$S/lift.out"; }

# 6. units
u=$repo/.config/systemd/user
t=$u/aide-hold-probe.timer; s=$u/aide-hold-probe.service
grep -qx 'OnUnitActiveSec=15min' "$t" && grep -qx 'Persistent=true' "$t" && grep -qx 'WantedBy=timers.target' "$t" && ok "aide-hold-probe.timer: every 15 min, persistent" 0 || ok "aide-hold-probe.timer: every 15 min, persistent" 1
grep -qx 'Type=oneshot' "$s" && grep -q 'ExecStart=.*\.local/bin/aide-hold\.sh probe"$' "$s" && grep -qx 'ConditionHost=carbon' "$s" && ok "aide-hold-probe.service: oneshot aide-hold.sh probe, carbon only" 0 || ok "aide-hold-probe.service" 1
d=$u/mcphost-deploy-catchup.service.d/90-grading-hold.conf
cmp -s <(sed -n 27,29p "$TXT") "$d" && ok "orch drop-in 90-grading-hold.conf == captured txt lines 27-29" 0 || ok "orch drop-in 90-grading-hold.conf == captured txt lines 27-29" 1
n=0; for x in on-land release-checkout release catchup; do cmp -s "$d" "$u/mcphost-deploy-$x.service.d/90-grading-hold.conf" || n=1; done
ok "orch drop-in tracked for all four mcphost-deploy services" "$n"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fail"; fi
exit "$fail"
