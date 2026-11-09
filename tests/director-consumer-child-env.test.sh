#!/usr/bin/env bash
# director-consumer-child-env.test.sh: worker launch carries an explicit env allowlist, fails closed on live homes and runs
# inside an enforced systemd boundary. Stub child commands only: no real Hermes, no provider, no credentials, no network.
# The unit tests start real transient `systemd-run --user` units. Usage: <this> [test-name]   (default: all)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="$HERE/.local/bin/director-event-consumer.py"
SCR="$HOME/.cache/director-scratch"
P="dirtest-$$"
T="$(mktemp -d)"
cleanup(){ rm -rf "$T" "$SCR/$P"-*; }
trap cleanup EXIT
mkdir -p "$SCR"
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }

printf '#!/usr/bin/env bash\necho called >> %s/provider.calls; env | sort > %s/provider.env\n' "$T" "$T" > "$T/provider"
chmod +x "$T/provider"
# a unit scratch dir with home + hermes-home, as the launcher creates them
mk_unit(){ local u="$SCR/$P-$1"; mkdir -p "$u/home" "$u/hermes-home" "$u/st" "$u/wmstate"; echo "$u"; }
# env for child-exec in isolation mode against unit dir $1
iso_env(){ local u="$1"; echo DIRECTOR_STATE="$u/st" WM_ASKS_CMD="$u/wm-asks" WM_DECIDE_STATE="$u/wmstate" DIRECTOR_ISOLATION=1 \
  DIRECTOR_SCRATCH="$u" HOME="$u/home" HERMES_HOME="$u/hermes-home" DIRECTOR_CHILD_REQUIRE=DIRECTOR_STATE,WM_ASKS_CMD,WM_DECIDE_STATE,DIRECTOR_SCRATCH,HOME,HERMES_HOME; }
run_ce(){ env "$@" PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>"$T/err"; }

t_credential_stripped(){
  rm -f "$T/provider.calls" "$T/provider.env"; local u; u="$(mk_unit cred)"
  env $(iso_env "$u") PATH="$PATH" ANTHROPIC_API_KEY=fake-secret-1 CLAUDE_CODE_OAUTH_TOKEN=fake-secret-2 \
      OPENAI_API_KEY=fake-secret-3 GH_TOKEN=fake-secret-4 python3 "$C" child-exec -- "$T/provider"; rc=$?
  [ "$rc" = 0 ] && [ -s "$T/provider.calls" ] || { bad credential_stripped "rc=$rc, provider not run"; return; }
  if grep -Eq 'fake-secret|API_KEY|TOKEN' "$T/provider.env"; then bad credential_stripped "credential reached the child"; return; fi
  grep -q "^WM_ASKS_CMD=$u/wm-asks$" "$T/provider.env" && grep -q "^WM_DECIDE_STATE=$u/wmstate$" "$T/provider.env" \
    && grep -q "^DIRECTOR_STATE=$u/st$" "$T/provider.env" && grep -q "^HOME=$u/home$" "$T/provider.env" && ok credential_stripped || bad credential_stripped "isolation vars missing in child"
}
t_missing_var_fails_closed(){
  rm -f "$T/provider.calls"; local u; u="$(mk_unit miss)"
  env DIRECTOR_STATE="$u/st" WM_DECIDE_STATE="$u/wmstate" DIRECTOR_ISOLATION=1 DIRECTOR_SCRATCH="$u" HOME="$u/home" HERMES_HOME="$u/hermes-home" \
      DIRECTOR_CHILD_REQUIRE=DIRECTOR_STATE,WM_ASKS_CMD,WM_DECIDE_STATE PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>"$T/err"; rc=$?
  [ "$rc" = 78 ] && [ ! -e "$T/provider.calls" ] && grep -q "WM_ASKS_CMD" "$T/err" && ok missing_var_fails_closed || bad missing_var_fails_closed "rc=$rc calls=$(cat "$T/provider.calls" 2>/dev/null)"
}
t_live_path_fails_closed(){
  rm -f "$T/provider.calls"; local r1 r2 r3 u; u="$(mk_unit livepath)"
  run_ce $(iso_env "$u") DIRECTOR_STATE="$HOME/.local/state/director-consumer"; r1=$?
  run_ce $(iso_env "$u") WM_DECIDE_STATE="$HOME/.local/state/swarm-decide"; r2=$?
  run_ce $(iso_env "$u") WM_ASKS_CMD=wm-asks; r3=$?
  [ "$r1 $r2 $r3" = "78 78 78" ] && [ ! -e "$T/provider.calls" ] && ok live_path_fails_closed || bad live_path_fails_closed "rc=$r1 $r2 $r3"
}
t_live_home_fails_closed(){
  rm -f "$T/provider.calls"; local u rcs="" v n; u="$(mk_unit livehome)"
  for v in "HOME=$HOME" "HOME=$HOME/.hermes" "HERMES_HOME=$HOME/.hermes" "HERMES_HOME=$HOME" "HOME=$HOME/.claude" "HOME=$HOME/.config" \
           "HERMES_HOME=$HOME/.ssh" "HOME=$HOME/.local/state" "HOME=$HOME/.config/fleet-token" "HERMES_HOME=$HOME/.local/state/swarm-decide" \
           "DIRECTOR_CHILD_HOME=$HOME" "HOME=/tmp" "HOME=$SCR" "HERMES_HOME=$u" "HOME=" "HERMES_HOME=$u/nonexistent"; do
    run_ce $(iso_env "$u") "$v"; rcs="$rcs $?"
  done
  n=$(echo $rcs | tr ' ' '\n' | grep -vc '^78$')
  [ "$n" = 0 ] && [ ! -e "$T/provider.calls" ] && ok live_home_fails_closed || bad live_home_fails_closed "rcs=$rcs"
}
t_symlink_alias_fails_closed(){
  rm -f "$T/provider.calls"; local u rcs="" v n; u="$(mk_unit alias)"
  ln -s "$HOME" "$u/to-home"; ln -s "$HOME/.hermes" "$u/to-hermes"; ln -s "$u/to-hermes" "$u/chain"; ln -s /tmp "$u/to-tmp"
  ln -s "$HOME/.claude" "$T/outside-alias"; ln -s "$HOME" "$SCR/$P-toplevel-alias"
  mkdir -p "$u/home/sub"; ln -s ../.. "$u/home/sub/up"
  for v in "HOME=$u/to-home" "HERMES_HOME=$u/to-hermes" "HERMES_HOME=$u/chain" "HOME=$u/to-tmp" "HOME=$T/outside-alias" \
           "HOME=$SCR/$P-toplevel-alias" "HOME=$SCR/$P-toplevel-alias/.hermes" "HOME=$u/home/../../.." "HERMES_HOME=$u/home/sub/up/.." \
           "HOME=$u/to-home/.cache/director-scratch/$P-other/home"; do
    run_ce $(iso_env "$u") "$v"; rcs="$rcs $?"
  done
  n=$(echo $rcs | tr ' ' '\n' | grep -vc '^78$')
  [ "$n" = 0 ] && [ ! -e "$T/provider.calls" ] && ok symlink_alias_fails_closed || bad symlink_alias_fails_closed "rcs=$rcs"
}
t_scratch_home_positive(){
  rm -f "$T/provider.calls"; local u; u="$(mk_unit pos)"
  ln -s "$u/home" "$u/home-alias"   # a symlink alias that resolves INSIDE the unit scratch dir is fine
  run_ce $(iso_env "$u") HOME="$u/home-alias"; rc=$?
  [ "$rc" = 0 ] && [ -s "$T/provider.calls" ] && ok scratch_home_positive || bad scratch_home_positive "rc=$rc $(cat "$T/err")"
}

# --- real transient units -------------------------------------------------------------------------------------------
PROBE='
import os, socket, sys
out = []
def op(name, path):
    try:
        os.close(os.open(path, os.O_RDONLY)); out.append("%s OPEN" % name)      # open only, never read
    except OSError as e:
        out.append("%s FAIL %s" % (name, e.errno))
def ls(name, path):
    try:
        os.listdir(path); out.append("%s OPEN" % name)
    except OSError as e:
        out.append("%s FAIL %s" % (name, e.errno))
def wr(name, path):
    try:
        with open(path, "w") as f: f.write("x")
        out.append("%s OK" % name)
    except OSError as e:
        out.append("%s FAIL %s" % (name, e.errno))
def bus():
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect("/run/user/%d/bus" % os.getuid()); out.append("bus OPEN")     # connect only, nothing sent
    except OSError as e:
        out.append("bus FAIL %s" % e.errno)
    s.close()
lh = sys.argv[1]; res = sys.argv[2]; sc = sys.argv[3]
op("auth", lh + "/.hermes/auth.json"); op("claude", lh + "/.claude/sentinel"); op("ssh", lh + "/.ssh/sentinel")
op("fleet-token", lh + "/.config/fleet-token/sentinel"); op("wm-sudo", lh + "/.config/wm-sudo/sentinel")
op("ledger", lh + "/.local/state/swarm-decide/ledger.jsonl"); ls("hermes-dir", lh + "/.hermes"); ls("config-dir", lh + "/.config")
bus()
wr("scratch-write", sc + "/home/probe-write"); wr("livehome-write", lh + "/probe-write")
out.append("HOME=" + os.environ.get("HOME", "")); out.append("HERMES_HOME=" + os.environ.get("HERMES_HOME", ""))
open(res, "w").write("\n".join(out) + "\n")
'
mk_fake_home(){   # $1 = fake live home dir with sentinel files at the protected names
  local lh="$1" d
  for d in .hermes .claude .ssh .config/fleet-token .config/wm-sudo .local/state/swarm-decide; do mkdir -p "$lh/$d"; done
  echo sentinel > "$lh/.hermes/auth.json"; echo sentinel > "$lh/.local/state/swarm-decide/ledger.jsonl"
  for d in .claude .ssh .config/fleet-token .config/wm-sudo; do echo sentinel > "$lh/$d/sentinel"; done
}
t_unit_boundary_fake_home(){
  # Enforced boundary shown on sentinels under a test-only fake live home: same properties, built for that home.
  local lh="$SCR/$P-fake" u res rc; mkdir -p "$lh"; mk_fake_home "$lh"
  python3 - "$C" "$P" "$lh" "$T" "$PROBE" <<'PY'
import importlib.util, os, subprocess, sys
c, p, lh, t, probe = sys.argv[1:6]
unit = p + "-fakeunit"; sc = lh + "/.cache/director-scratch/" + unit
os.makedirs(sc + "/st"); os.makedirs(sc + "/wmstate")
os.environ.update(DIRECTOR_STATE=sc + "/st", WM_DECIDE_STATE=sc + "/wmstate", WM_ASKS_CMD=sc + "/wm-asks")
spec = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sc + "/probe.py", "w").write(probe)
argv = m.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py", lh, sc + "/result", sc], live_home=lh, child_exec=False)
open(t + "/unit.argv", "w").write(" ".join(argv))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
sys.stderr.write(r.stderr[-400:])
# control: the same probe in a plain unit with no boundary
r2 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-ctl", "--", "/usr/bin/python3", sc + "/probe.py",
                     lh, sc + "/control", sc], capture_output=True, text=True)
sys.stderr.write(r2.stderr[-400:])
PY
  u="$lh/.cache/director-scratch/$P-fakeunit"; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res"; echo "--- control (no boundary):"; echo "$ctl"
  local want="auth claude ssh fleet-token wm-sudo ledger hermes-dir config-dir bus" w
  for w in $want; do
    echo "$res" | grep -q "^$w FAIL " || { bad unit_boundary_fake_home "$w reachable inside the boundary"; return; }
    echo "$ctl" | grep -q "^$w OPEN" || { bad unit_boundary_fake_home "control cannot reach $w (test not discriminating)"; return; }
  done
  echo "$res" | grep -q "^scratch-write OK" || { bad unit_boundary_fake_home "scratch dir not writable"; return; }
  echo "$res" | grep -q "^livehome-write FAIL " || { bad unit_boundary_fake_home "live home writable"; return; }
  ok unit_boundary_fake_home
}
t_unit_real_home(){
  # Real launch_argv + child-exec against the REAL live home: the live names are only opened (never read), each must fail.
  python3 - "$C" "$P" "$T" "$PROBE" <<'PY'
import importlib.util, os, subprocess, sys
c, p, t, probe = sys.argv[1:5]
home = os.path.expanduser("~"); unit = p + "-realunit"; sc = home + "/.cache/director-scratch/" + unit
os.makedirs(sc + "/st"); os.makedirs(sc + "/wmstate")
os.environ.update(DIRECTOR_STATE=sc + "/st", WM_DECIDE_STATE=sc + "/wmstate", WM_ASKS_CMD=sc + "/wm-asks",
                  ANTHROPIC_API_KEY="fake-secret-1", CLAUDE_CODE_OAUTH_TOKEN="fake-secret-2")
spec = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
open(sc + "/probe.py", "w").write(probe)
argv = m.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py", home, sc + "/result", sc])
open(t + "/real.argv", "w").write(" ".join(argv))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
sys.stderr.write(r.stderr[-400:])
PY
  local u="$SCR/$P-realunit" res; res="$(cat "$u/result" 2>/dev/null)"; echo "$res"
  local w
  for w in auth claude ssh fleet-token wm-sudo ledger hermes-dir config-dir bus livehome-write; do
    echo "$res" | grep -q "^$w FAIL " || { bad unit_real_home "$w did not fail inside the unit"; return; }
  done
  echo "$res" | grep -q "^scratch-write OK" && echo "$res" | grep -q "^HOME=$u/home$" && echo "$res" | grep -q "^HERMES_HOME=$u/hermes-home$" \
    || { bad unit_real_home "scratch home not in use"; return; }
  grep -q 'fake-secret' "$T/real.argv" && { bad unit_real_home "credential on the unit command line"; return; }
  ok unit_real_home
}
t_launch_argv(){
  python3 - "$C" "$T" "$SCR/$P-argv" <<'PY'
import importlib.util, os, sys
c, t, sc0 = sys.argv[1:4]
os.environ.update(DIRECTOR_STATE=t + "/st", WM_ASKS_CMD=t + "/wm-asks", WM_DECIDE_STATE=t + "/wmstate", ANTHROPIC_API_KEY="fake-secret-1")
sp = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
os.makedirs(t + "/st"); os.makedirs(t + "/wmstate")
a = m.launch_argv(os.path.basename(sc0), "/e.md")
j = " ".join(a)
assert a[:3] == ["systemd-run", "--user", "--unit"], a
for need in ("--setenv WM_ASKS_CMD=" + t + "/wm-asks", "--setenv WM_DECIDE_STATE=" + t + "/wmstate", "--setenv DIRECTOR_STATE=" + t + "/st",
             "--setenv DIRECTOR_ISOLATION=1", "-p TemporaryFileSystem=", ":ro", "-p BindPaths=", "-p InaccessiblePaths=", "-p PrivateTmp=yes",
             "-p NoNewPrivileges=yes", "-p PrivateNetwork=yes", "/dev/shm", " child-exec -- "):
    assert need in j, need
assert "ReadWritePaths" not in j and "ProtectHome" not in j, "permissive paths back"
for need in ("/.hermes", "/.claude", "/.config/fleet-token", "/.config/wm-sudo", "/.ssh", "/.local/state/swarm-decide", "/run/user/%d" % os.getuid(),
             "/var/run/docker.sock", "/run/docker.sock", "/run/dbus"):
    assert need in j, need
assert "fake-secret" not in j and "API_KEY" not in j, "credential on the unit"
for cap in ("RuntimeMaxSec", "MemoryMax", "CPUQuota", "TimeoutStopSec", "max-turns", "budget"):
    assert cap not in j, cap
print("vars:", ",".join(sorted(x.split("=")[0] for x in a if "=" in x and a[a.index(x) - 1] == "--setenv")))
for x in a:
    if a[a.index(x) - 1] == "-p": print("prop:", x)
PY
  [ $? = 0 ] && ok launch_argv || bad launch_argv
}

IPC_PROBE='
import os, socket, sys
out = []
def uc(name, addr):
    s = socket.socket(socket.AF_UNIX); s.settimeout(5)
    try:
        s.connect(addr); out.append("%s OPEN" % name)      # connect only, nothing sent
    except OSError as e:
        out.append("%s FAIL %s" % (name, e.errno))
    s.close()
uc("docker", "/var/run/docker.sock"); uc("docker-run", "/run/docker.sock"); uc("dbus", "/run/dbus/system_bus_socket")
uc("snapd", "/run/snapd.socket"); uc("tailscale", "/run/tailscale/tailscaled.sock"); uc("cups", "/run/cups/cups.sock")
uc("x11-abstract", "\0/tmp/.X11-unix/X0"); uc("x11-abstract1", "\0/tmp/.X11-unix/X1")
s = socket.socket(); s.settimeout(5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); out.append("tcp-loopback OPEN")
except OSError as e:
    out.append("tcp-loopback FAIL %s" % e.errno)
s.close()
try:
    open("/dev/shm/" + sys.argv[2] + "-child", "w").write("x"); out.append("shm-write OK")
except OSError as e:
    out.append("shm-write FAIL %s" % e.errno)
out.append("shm-host-marker " + ("VISIBLE" if os.path.exists("/dev/shm/" + sys.argv[2] + "-host") else "HIDDEN"))
open(sys.argv[3], "w").write("\n".join(out) + "\n")
'
t_unit_ipc_net_shm(){
  # Real transient units with the real isolation props: host IPC sockets, loopback TCP to a listener this test starts, abstract
  # X11 sockets and /dev/shm. The control unit runs the same probe with no boundary and must reach each of them.
  local m="$P-shm"; rm -f "/dev/shm/$m-host" "/dev/shm/$m-child"; echo host > "/dev/shm/$m-host"
  python3 - "$C" "$P" "$T" "$IPC_PROBE" "$m" <<'PY'
import importlib.util, os, socket, subprocess, sys
c, p, t, probe, m = sys.argv[1:6]
home = os.path.expanduser("~"); unit = p + "-ipcunit"; sc = home + "/.cache/director-scratch/" + unit
os.makedirs(sc + "/st"); os.makedirs(sc + "/wmstate")
os.environ.update(DIRECTOR_STATE=sc + "/st", WM_DECIDE_STATE=sc + "/wmstate", WM_ASKS_CMD=sc + "/wm-asks")
spec = importlib.util.spec_from_file_location("dec", c); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
open(sc + "/probe.py", "w").write(probe)
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(8); port = str(srv.getsockname()[1])   # listener of this test, in this process
argv = mod.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py", port, m, sc + "/result"])
open(t + "/ipc.argv", "w").write(" ".join(argv))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
sys.stderr.write(r.stderr[-300:])
if os.path.exists("/dev/shm/%s-child" % m):      # a write that reached the host
    open(t + "/iso-shm-child", "w").close(); os.unlink("/dev/shm/%s-child" % m)
r2 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-ctl", "--", "/usr/bin/python3", sc + "/probe.py", port, m, sc + "/control"],
                    capture_output=True, text=True)
sys.stderr.write(r2.stderr[-300:])
PY
  local u="$SCR/$P-ipcunit" res ctl w; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res"; echo "--- control (no boundary):"; echo "$ctl"
  local host_leak=no ctl_leak=no; [ -e "$T/iso-shm-child" ] && host_leak=yes; [ -e "/dev/shm/$m-child" ] && ctl_leak=yes
  echo "host-visible /dev/shm write from isolated child: $host_leak; from control child: $ctl_leak"; rm -f "/dev/shm/$m-host" "/dev/shm/$m-child"
  for w in docker docker-run dbus snapd tailscale cups x11-abstract x11-abstract1 tcp-loopback; do
    echo "$res" | grep -q "^$w OPEN" && { bad unit_ipc_net_shm "$w reachable inside the boundary"; return; }
    echo "$res" | grep -q "^$w FAIL " || { bad unit_ipc_net_shm "$w not probed"; return; }
  done
  for w in docker dbus tcp-loopback x11-abstract; do
    echo "$ctl" | grep -q "^$w OPEN" || { bad unit_ipc_net_shm "control cannot reach $w (test not discriminating)"; return; }
  done
  echo "$ctl" | grep -q "^shm-host-marker VISIBLE" && [ "$ctl_leak" = yes ] || { bad unit_ipc_net_shm "control does not share /dev/shm (test not discriminating)"; return; }
  echo "$res" | grep -q "^shm-host-marker HIDDEN" && [ "$host_leak" = no ] || { bad unit_ipc_net_shm "host /dev/shm shared with the isolated child"; return; }
  ok unit_ipc_net_shm
}
t_override_refused(){
  # DIRECTOR_LAUNCH_CMD / DIRECTOR_RESET_CMD replace the boundary: in isolation mode they must resolve to a file under the scratch root.
  python3 - "$C" "$T" "$SCR" <<'PY'
import importlib.util, os, sys
c, t, scr = sys.argv[1:4]
os.environ.update(DIRECTOR_STATE=t + "/stov", WM_ASKS_CMD=t + "/wm-asks", WM_DECIDE_STATE=t + "/wmov")
for k in ("DIRECTOR_LAUNCH_CMD", "DIRECTOR_RESET_CMD", "DIRECTOR_ISOLATION"):
    os.environ.pop(k, None)
spec = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.makedirs(t + "/stov", exist_ok=True)
ran = t + "/stub.ran"
outside = t + "/outside-launcher"; open(outside, "w").write("#!/bin/sh\necho x >> %s\n" % ran); os.chmod(outside, 0o755)
inside = scr + "/ov-" + os.path.basename(t) + "-launcher"; open(inside, "w").write("#!/bin/sh\nexit 0\n"); os.chmod(inside, 0o755)
os.symlink(outside, scr + "/ov-" + os.path.basename(t) + "-link")
def refused(**kw):
    for k in ("DIRECTOR_LAUNCH_CMD", "DIRECTOR_RESET_CMD"): os.environ.pop(k, None)
    os.environ.update(kw); return m.check_overrides()
assert refused(DIRECTOR_LAUNCH_CMD=outside) == ["DIRECTOR_LAUNCH_CMD"]
assert refused(DIRECTOR_RESET_CMD=outside) == ["DIRECTOR_RESET_CMD"]
assert refused(DIRECTOR_LAUNCH_CMD="/bin/sh -c true") == ["DIRECTOR_LAUNCH_CMD"], "interpreter outside scratch"
assert refused(DIRECTOR_LAUNCH_CMD="relative-launcher") == ["DIRECTOR_LAUNCH_CMD"]
assert refused(DIRECTOR_LAUNCH_CMD=scr + "/ov-" + os.path.basename(t) + "-link") == ["DIRECTOR_LAUNCH_CMD"], "symlink out of scratch"
assert refused(DIRECTOR_LAUNCH_CMD=scr + "/../.hermes/x") == ["DIRECTOR_LAUNCH_CMD"], "dotdot"
assert refused(DIRECTOR_LAUNCH_CMD=scr) == ["DIRECTOR_LAUNCH_CMD"], "scratch root itself"
assert refused(DIRECTOR_LAUNCH_CMD=inside, DIRECTOR_RESET_CMD=inside) == [], "file under scratch is allowed"
assert refused() == []
# launch() raises before any launcher runs; main() turns it into exit 78
os.environ["DIRECTOR_LAUNCH_CMD"] = outside + " arg"
try:
    m.launch({"event_id": "evt-ov", "ask": "A1"}); raise SystemExit("launch did not refuse")
except m.LaunchRefused:
    pass
assert not os.path.exists(ran), "stub launcher ran"
m.recover_runs = lambda replay=False: m.launch({"event_id": "evt-ov", "ask": "A1"})
assert m.main(["x", "recover"]) == 78 and not os.path.exists(ran)
os.environ["DIRECTOR_ISOLATION"] = ""
print("override refusal ok")
PY
  local rc=$?; rm -f "$SCR/ov-"*; [ $rc = 0 ] && ok override_refused || bad override_refused "rc=$rc"
}
if [ $# -gt 0 ]; then "t_$1"; else for t in credential_stripped missing_var_fails_closed live_path_fails_closed live_home_fails_closed symlink_alias_fails_closed scratch_home_positive launch_argv unit_boundary_fake_home unit_real_home unit_ipc_net_shm override_refused; do "t_$t"; done; fi
[ "$fails" -eq 0 ] || { echo "FAILURES: $fails"; exit 1; }
