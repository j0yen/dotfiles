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
uc("x11-own", "\0/tmp/.X11-unix/" + sys.argv[4])      # abstract listener this test binds itself, so the control never depends on a running X server
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
xsrv = socket.socket(socket.AF_UNIX); xname = p + "-x11own"; xsrv.bind("\0/tmp/.X11-unix/" + xname); xsrv.listen(8)   # abstract socket in the host netns
argv = mod.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py", port, m, sc + "/result", xname])
open(t + "/ipc.argv", "w").write(" ".join(argv))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
sys.stderr.write(r.stderr[-300:])
if os.path.exists("/dev/shm/%s-child" % m):      # a write that reached the host
    open(t + "/iso-shm-child", "w").close(); os.unlink("/dev/shm/%s-child" % m)
r2 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-ctl", "--", "/usr/bin/python3", sc + "/probe.py", port, m, sc + "/control", xname],
                    capture_output=True, text=True)
sys.stderr.write(r2.stderr[-300:])
PY
  local u="$SCR/$P-ipcunit" res ctl w; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res"; echo "--- control (no boundary):"; echo "$ctl"
  local host_leak=no ctl_leak=no; [ -e "$T/iso-shm-child" ] && host_leak=yes; [ -e "/dev/shm/$m-child" ] && ctl_leak=yes
  echo "host-visible /dev/shm write from isolated child: $host_leak; from control child: $ctl_leak"; rm -f "/dev/shm/$m-host" "/dev/shm/$m-child"
  for w in docker docker-run dbus snapd tailscale cups x11-abstract x11-abstract1 x11-own tcp-loopback; do
    echo "$res" | grep -q "^$w OPEN" && { bad unit_ipc_net_shm "$w reachable inside the boundary"; return; }
    echo "$res" | grep -q "^$w FAIL " || { bad unit_ipc_net_shm "$w not probed"; return; }
  done
  for w in docker dbus tcp-loopback x11-own; do
    echo "$ctl" | grep -q "^$w OPEN" || { bad unit_ipc_net_shm "control cannot reach $w (test not discriminating)"; return; }
  done
  echo "$ctl" | grep -q "^shm-host-marker VISIBLE" && [ "$ctl_leak" = yes ] || { bad unit_ipc_net_shm "control does not share /dev/shm (test not discriminating)"; return; }
  echo "$res" | grep -q "^shm-host-marker HIDDEN" && [ "$host_leak" = no ] || { bad unit_ipc_net_shm "host /dev/shm shared with the isolated child"; return; }
  ok unit_ipc_net_shm
}
DEV_PROBE='
import glob, os, sys
out = []
for d in sorted(glob.glob("/dev/input/event*"))[:4] + ["/dev/input/mice", "/dev/video0", "/dev/snd/controlC0", "/dev/snd/pcmC0D0c", "/dev/dri/card1", "/dev/dri/renderD128", "/dev/fuse"]:
    try:
        os.close(os.open(d, os.O_RDONLY | os.O_NONBLOCK)); out.append("dev %s OPEN" % d)      # open+close only, nothing read
    except OSError as e:
        out.append("dev %s FAIL %s" % (d, e.errno))
try:
    open("/dev/shm/" + sys.argv[1] + "-child", "w").close(); out.append("shm-write OK")
except OSError as e:
    out.append("shm-write FAIL %s" % e.errno)
out.append("shm-host-marker " + ("VISIBLE" if os.path.exists("/dev/shm/" + sys.argv[1] + "-host") else "HIDDEN"))
pids = [p for p in os.listdir("/proc") if p.isdigit()]; rd = 0
for p in pids:
    try:
        os.close(os.open("/proc/%s/cmdline" % p, os.O_RDONLY)); rd += 1      # openable count only, content never read
    except OSError:
        pass
out.append("proc pids=%d cmdline-openable=%d" % (len(pids), rd))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
'
t_unit_devices_proc(){
  # Real transient units with the real isolation props: device nodes (open+close only), a private /dev/shm next to the private
  # /dev, and how many host pids (and their cmdline) the child can see. The control unit has no properties.
  # Probed in the user manager: DevicePolicy=closed+DeviceAllow and ProtectProc/ProcSubset do not apply; PrivateDevices and PrivatePIDs do.
  local m="$P-dev"; rm -f "/dev/shm/$m-host" "/dev/shm/$m-child"; echo host > "/dev/shm/$m-host"
  python3 - "$C" "$P" "$T" "$DEV_PROBE" "$m" <<'PY'
import importlib.util, os, subprocess, sys
c, p, t, probe, m = sys.argv[1:6]
home = os.path.expanduser("~"); unit = p + "-devunit"; sc = home + "/.cache/director-scratch/" + unit
os.makedirs(sc + "/st"); os.makedirs(sc + "/wmstate")
os.environ.update(DIRECTOR_STATE=sc + "/st", WM_DECIDE_STATE=sc + "/wmstate", WM_ASKS_CMD=sc + "/wm-asks")
spec = importlib.util.spec_from_file_location("dec", c); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
open(sc + "/probe.py", "w").write(probe)
argv = mod.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py", m, sc + "/result"])
open(t + "/dev.argv", "w").write(" ".join(argv))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
sys.stderr.write(r.stderr[-300:])
if os.path.exists("/dev/shm/%s-child" % m):
    open(t + "/iso-shm-child", "w").close(); os.unlink("/dev/shm/%s-child" % m)
r2 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-ctl", "--", "/usr/bin/python3", sc + "/probe.py", m, sc + "/control"],
                    capture_output=True, text=True)
sys.stderr.write(r2.stderr[-300:])
PY
  local u="$SCR/$P-devunit" res ctl; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res"; echo "--- control (no boundary):"; echo "$ctl"
  local host_leak=no; [ -e "$T/iso-shm-child" ] && host_leak=yes; rm -f "/dev/shm/$m-host" "/dev/shm/$m-child"
  [ -n "$res" ] && [ -n "$ctl" ] || { bad unit_devices_proc "no probe output"; return; }
  [ "$(echo "$ctl" | grep -c '^dev .* OPEN')" -ge 3 ] || { bad unit_devices_proc "control opens fewer than 3 device nodes (test not discriminating)"; return; }
  echo "$res" | grep -q '^dev .* OPEN' && { bad unit_devices_proc "device node openable inside the boundary: $(echo "$res" | grep '^dev .* OPEN' | tr '\n' ' ')"; return; }
  echo "$res" | grep -q '^dev ' || { bad unit_devices_proc "no device probed"; return; }
  echo "$ctl" | grep -q '^shm-host-marker VISIBLE' || { bad unit_devices_proc "control does not share /dev/shm (test not discriminating)"; return; }
  echo "$res" | grep -q '^shm-host-marker HIDDEN' && [ "$host_leak" = no ] || { bad unit_devices_proc "host /dev/shm visible or written from the isolated child"; return; }
  local rp cp; rp="$(echo "$res" | sed -n 's/.*cmdline-openable=//p')"; cp="$(echo "$ctl" | sed -n 's/.*cmdline-openable=//p')"
  [ "${cp:-0}" -gt 10 ] || { bad unit_devices_proc "control sees too few pids (test not discriminating)"; return; }
  [ "${rp:-99}" -le 1 ] || { bad unit_devices_proc "host process cmdline openable inside the boundary: $rp"; return; }
  ok unit_devices_proc
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
od = scr + "/ov-" + os.path.basename(t) + "-dir"; os.makedirs(od, mode=0o700); os.chmod(od, 0o700)
inside = od + "/launcher"; open(inside, "w").write("#!/bin/sh\nexit 0\n"); os.chmod(inside, 0o755)
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
  local rc=$?; rm -rf "$SCR/ov-"*; [ $rc = 0 ] && ok override_refused || bad override_refused "rc=$rc"
}
SOCK_PROBE='
import json, os, socket, sys
out = []
for path in json.load(open(sys.argv[1])):
    r = []
    for name, t in (("dgram", socket.SOCK_DGRAM), ("stream", socket.SOCK_STREAM)):
        s = socket.socket(socket.AF_UNIX, t); s.settimeout(3)
        try:
            s.connect(path); r.append("OPEN"); break                       # connect only, nothing is sent or read
        except OSError as e:
            r.append(str(e.errno))
        finally:
            s.close()
    out.append("sock %s %s" % (path, r[0] if r[0] == "OPEN" or len(r) == 1 else ("OPEN" if "OPEN" in r else "FAIL " + "/".join(r))))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
'
LIST_PROBE='
import os, sys
out = []
for d in sys.argv[2:]:
    try:
        out.append("ls %s %d" % (d, len(os.listdir(d))))
    except OSError as e:
        out.append("ls %s FAIL %s" % (d, e.errno))
open(sys.argv[1], "w").write("\n".join(out) + "\n")
'
# run_three NAME PROBE-SOURCE JSON-ARGS [sockets]: run the probe in: isolation unit (real props), sockets-only unit (only the new
# InaccessiblePaths), and a control unit (no properties). Prints nothing; results land in $SCR/$P-<name>unit/{result,only,control}.
run_three(){
  python3 - "$C" "$P" "$1" "$2" "$3" "${4:-}" <<'PY'
import importlib.util, json, os, subprocess, sys
c, p, name, probe, args, only = sys.argv[1:7]
home = os.path.expanduser("~"); unit = p + "-" + name + "unit"; sc = home + "/.cache/director-scratch/" + unit
os.makedirs(sc + "/st"); os.makedirs(sc + "/wmstate")
os.environ.update(DIRECTOR_STATE=sc + "/st", WM_DECIDE_STATE=sc + "/wmstate", WM_ASKS_CMD=sc + "/wm-asks")
spec = importlib.util.spec_from_file_location("dec", c); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
open(sc + "/probe.py", "w").write(probe)
if name == "sock":
    json.dump(json.loads(args), open(sc + "/paths.json", "w")); targs = lambda res: [sc + "/paths.json", sc + "/" + res]
else:
    targs = lambda res: [sc + "/" + res] + json.loads(args)
argv = mod.launch_argv(unit, "/e.md", tail=["/usr/bin/python3", sc + "/probe.py"] + targs("result"))
r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True); sys.stderr.write(r.stderr[-300:])
if only == "sockets":      # only the socket denial, nothing else: shows the InaccessiblePaths themselves close the names
    deny = getattr(mod, "socket_deny_paths", lambda: [])()
    props = ["-p", "InaccessiblePaths=" + " ".join("-" + d for d in deny)] if deny else []
    r1 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-only"] + props + ["--", "/usr/bin/python3", sc + "/probe.py"] + targs("only"), capture_output=True, text=True); sys.stderr.write(r1.stderr[-300:])
r2 = subprocess.run(["systemd-run", "--user", "--wait", "--pipe", "--collect", "--unit", unit + "-ctl", "--", "/usr/bin/python3", sc + "/probe.py"] + targs("control"), capture_output=True, text=True); sys.stderr.write(r2.stderr[-300:])
PY
}
t_unit_sockets(){
  # Connect-only attempts (no data sent, errno reported) at journald/syslog, systemd varlink services and the manager notify socket,
  # from the real isolation unit, from a unit holding only the new InaccessiblePaths, and from a control unit with no properties.
  local paths; paths="$(python3 -c '
import glob, json, os
l = ["/dev/log", "/run/systemd/notify"] + sorted(glob.glob("/run/systemd/journal/*")) + sorted(glob.glob("/run/systemd/io.systemd.*")) + sorted(glob.glob("/run/systemd/*/io.systemd.*"))
print(json.dumps([x for x in l if os.path.lexists(x) and not os.path.isdir(x) and (os.path.islink(x) or __import__("stat").S_ISSOCK(os.stat(x).st_mode))]))')"
  run_three sock "$SOCK_PROBE" "$paths" sockets
  local u="$SCR/$P-sockunit" res ctl only; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"; only="$(cat "$u/only" 2>/dev/null)"
  echo "--- inside the boundary (errno shown):"; echo "$res"; echo "--- only the socket InaccessiblePaths:"; echo "$only"; echo "--- control (no boundary):"; echo "$ctl"
  [ -n "$res" ] && [ -n "$ctl" ] || { bad unit_sockets "no probe output"; return; }
  local w
  for w in /dev/log /run/systemd/notify /run/systemd/journal/dev-log /run/systemd/journal/stdout /run/systemd/journal/socket /run/systemd/io.systemd.Hostname /run/systemd/io.systemd.Login; do
    echo "$ctl" | grep -q "^sock $w OPEN" || { bad unit_sockets "control cannot connect to $w (test not discriminating)"; return; }
  done
  echo "$res" | grep -q ' OPEN$' && { bad unit_sockets "connectable inside the boundary: $(echo "$res" | grep ' OPEN$' | cut -d' ' -f2 | tr '\n' ' ')"; return; }
  echo "$only" | grep -q ' OPEN$' && { bad unit_sockets "connectable with the InaccessiblePaths alone: $(echo "$only" | grep ' OPEN$' | cut -d' ' -f2 | tr '\n' ' ')"; return; }
  [ "$(echo "$res" | grep -c ' FAIL ')" = "$(echo "$ctl" | grep -c '^sock')" ] || { bad unit_sockets "a path was not probed or not refused"; return; }
  ok unit_sockets
}
SOCKNEG_PROBE='
import errno, os, socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("CONNECT OPEN")           # connect only, no data sent
except OSError as e:
    print("CONNECT FAIL %s" % errno.errorcode.get(e.errno, e.errno))
'
t_unit_socket_negative(){
  # Discriminating socket control: a unix socket this test owns (so file mode never denies it) is connectable from a plain child and
  # from a plain transient unit, and must NOT be connectable from a unit that lists its directory in InaccessiblePaths.
  # Listen/connect only, nothing sent, no network, no privileged socket.
  local d="$SCR/$P-sockneg" r plain unit neg
  mkdir -p "$d/s"; printf '%s\n' "$SOCKNEG_PROBE" > "$d/probe.py"
  if ! r="$(systemd-run --user --wait --collect --pipe /usr/bin/true 2>&1)"; then
    echo "SKIP unit_socket_negative: SKIP-WITH-REASON systemd-run --user cannot run a transient unit here: $(echo "$r" | tail -c 200 | tr '\n' ' ')"; return
  fi
  python3 -I - "$d/s/sock" "$d" <<'PY' &
import os, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
open(sys.argv[2] + "/ready", "w").close()
time.sleep(60)
PY
  local spid=$! n=0
  while [ ! -e "$d/ready" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  plain="$(python3 -I "$d/probe.py" "$d/s/sock" 2>&1)"
  unit="$(systemd-run --user --quiet --wait --collect --pipe -- /usr/bin/python3 -I "$d/probe.py" "$d/s/sock" 2>&1)"
  neg="$(systemd-run --user --quiet --wait --collect --pipe -p "InaccessiblePaths=$d/s" -- /usr/bin/python3 -I "$d/probe.py" "$d/s/sock" 2>&1)"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  echo "positive (plain child): $plain"; echo "positive (plain unit): $unit"; echo "negative (InaccessiblePaths=$d/s): $(echo "$neg" | tail -n 3 | tr '\n' ' ')"
  [ "$plain" = "CONNECT OPEN" ] || { bad unit_socket_negative "positive control: plain child cannot connect (test not discriminating)"; return; }
  echo "$unit" | grep -qx "CONNECT OPEN" || { bad unit_socket_negative "positive control: plain unit cannot connect (test not discriminating)"; return; }
  echo "$neg" | grep -qE '^CONNECT FAIL (ENOENT|EACCES|ENOTDIR)$' || { bad unit_socket_negative "socket reachable or unit failed inside InaccessiblePaths: $(echo "$neg" | tail -n 3 | tr '\n' ' ')"; return; }
  ok unit_socket_negative
}
t_unit_socket_installed_builder(){
  # Binds the socket control to the consumer's own launcher: the unit argv comes from launch_argv() in $C (the code the installed
  # consumer runs), not from a hand-written systemd-run line. An owned unix socket is connectable through the builder's unit with the stock
  # deny list and refused once the socket is added to SOCKET_DENY_STATIC (the mechanism that builds InaccessiblePaths). Listen/connect
  # only; plain unit is the positive control; no provider, network or privileged socket.
  local tag="$P-sockbld" d r out
  d="$SCR/$tag"; mkdir -p "$d/st" "$d/wmstate" "$d/own"; printf '%s\n' "$SOCKNEG_PROBE" > "$d/probe.py"
  if ! r="$(systemd-run --user --wait --collect --pipe /usr/bin/true 2>&1)"; then
    echo "SKIP unit_socket_installed_builder: SKIP-WITH-REASON systemd-run --user cannot run a transient unit here: $(echo "$r" | tail -c 200 | tr '\n' ' ')"; return
  fi
  out="$(DIRECTOR_STATE="$d/st" WM_DECIDE_STATE="$d/wmstate" WM_ASKS_CMD="$d/wm-asks" python3 -I - "$C" "$d" "$tag" <<'PY' 2>&1
import importlib.util, socket, subprocess, sys, threading
C, d, tag = sys.argv[1:4]
sock = d + "/own/s"
srv = socket.socket(socket.AF_UNIX); srv.bind(sock); srv.listen(8)
threading.Thread(target=lambda: [srv.accept()[0].close() for _ in range(8)], daemon=True).start()
def load():
    spec = importlib.util.spec_from_file_location("dec_" + tag.replace("-", "_"), C); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
def run(m):
    argv = m.launch_argv(tag, "/e.md", tail=["/usr/bin/python3", "-I", d + "/probe.py", sock])
    r = subprocess.run(argv[:1] + ["--wait", "--pipe"] + argv[1:], capture_output=True, text=True)
    return (r.stdout.strip().splitlines() or ["NO OUTPUT " + r.stderr[-160:].replace("\n", " ")])[-1]
m0 = load(); print("allowed:", run(m0))
m1 = load(); m1.SOCKET_DENY_STATIC = tuple(m1.SOCKET_DENY_STATIC) + (sock,); print("denied:", run(m1))
PY
)"
  echo "builder-launched unit: $(echo "$out" | tr '\n' ' ')"
  echo "$out" | grep -qx 'allowed: CONNECT OPEN' || { bad unit_socket_installed_builder "positive control: builder unit cannot reach the owned socket (not discriminating): $(echo "$out" | tr '\n' ' ')"; return; }
  echo "$out" | grep -qE '^denied: CONNECT FAIL (ENOENT|EACCES|ENOTDIR)$' || { bad unit_socket_installed_builder "socket still reachable with it on SOCKET_DENY_STATIC: $(echo "$out" | tr '\n' ' ')"; return; }
  ok unit_socket_installed_builder
}
LISTING_CLOSED='["/run", "/run/udev", "/run/lock", "/run/systemd", "/run/systemd/journal", "/sys/class/input", "/sys/class/hidraw", "/proc/bus/input"]'
# Documented residuals: still listable in the unit (names only, no data). /sys/devices and /sys/dev/char expose device names and numbers,
# /sys/class/* the other device classes; closing them hides hardware sysfs that ordinary tools read, which no worker needs but a unit cannot
# prove safe to remove wholesale, so they are recorded rather than denied.
LISTING_RESIDUAL='["/sys/devices", "/sys/dev/char", "/sys/class", "/sys/class/sound", "/sys/class/drm", "/sys/class/net", "/sys/block", "/proc/bus"]'
# Empty-host allowance for the POSITIVE enumeration only: /sys/class/hidraw with a control count of exactly 0. Never a waiver of the in-boundary denial.
listing_na(){ [ "$1" = /sys/class/hidraw ] && [ "$2" = 0 ]; }
t_listing_na_selfcheck(){
  listing_na /sys/class/hidraw 0 || { bad listing_na_selfcheck "hidraw with count 0 must be N/A"; return; }
  local p c
  for c in 1 6; do listing_na /sys/class/hidraw "$c" && { bad listing_na_selfcheck "hidraw with count $c must not be N/A"; return; }; done
  for p in /run /run/udev /run/lock /run/systemd /run/systemd/journal /sys/class/input /proc/bus/input; do
    listing_na "$p" 0 && { bad listing_na_selfcheck "$p with count 0 must not be N/A"; return; }
  done
  listing_na /sys/class/hidraw "" && { bad listing_na_selfcheck "hidraw with no count must not be N/A"; return; }
  ok listing_na_selfcheck
}
t_unit_listing(){
  run_three list "$LIST_PROBE" "$(python3 -c "import json,sys; print(json.dumps(json.loads('$LISTING_CLOSED')+json.loads('$LISTING_RESIDUAL')))")"
  local u="$SCR/$P-listunit" res ctl w; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res"; echo "--- control (no boundary):"; echo "$ctl"
  [ -n "$res" ] && [ -n "$ctl" ] || { bad unit_listing "no probe output"; return; }
  local na="" cnt
  for w in $(python3 -c "import json; print(' '.join(json.loads('$LISTING_CLOSED')))"); do
    cnt="$(echo "$ctl" | sed -n "s|^ls $w \([0-9][0-9]*\)$|\1|p" | head -1)"
    if listing_na "$w" "$cnt"; then na="$na $w"; echo "note: $w is empty on this host (no HID device), nothing to enumerate; the in-boundary denial below still applies"
    else echo "$ctl" | grep -Eq "^ls $w [1-9][0-9]*$" || { bad unit_listing "control cannot list $w (test not discriminating)"; return; }; fi
    echo "$res" | grep -Eq "^ls $w (FAIL [0-9]+|0)$" || { bad unit_listing "names under $w still listable: $(echo "$res" | grep "^ls $w ")"; return; }
  done
  # the N/A branch fires for hidraw alone; any other path in it means the empty-host allowance leaked
  [ -z "${na# }" ] || [ "${na# }" = /sys/class/hidraw ] || { bad unit_listing "N/A branch fired for:$na"; return; }
  # non-empty anchors: the unit always has /run and /run/systemd entries, so these never take the N/A branch on any host
  for w in /run /run/systemd; do
    echo "$ctl" | grep -Eq "^ls $w [1-9][0-9]*$" || { bad unit_listing "anchor $w has no control entries (test not discriminating)"; return; }
    echo "$res" | grep -Eq "^ls $w (FAIL [0-9]+|0)$" || { bad unit_listing "anchor $w still listable inside the boundary: $(echo "$res" | grep "^ls $w ")"; return; }
  done
  echo "residual (documented, still listable): $(echo "$res" | grep -E '^ls [^ ]+ [1-9][0-9]*$' | sed 's/^ls //' | tr '\n' ';')"
  ok unit_listing
}
GROUP_PROBE='
import os, stat, sys
res, named, roots = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
def opens(path, st):
    # open+close only, never a read or write. Read open for a file with no other-read bit, write open for one with no other-write bit.
    got = []
    if stat.S_ISDIR(st.st_mode):
        flags = [(os.O_RDONLY | os.O_DIRECTORY, 4)]
    elif stat.S_ISREG(st.st_mode):
        flags = [(os.O_RDONLY | os.O_NONBLOCK, 4), (os.O_WRONLY | os.O_NONBLOCK, 2)]
    else:
        return got
    for f, bit in flags:
        if st.st_mode & bit:
            continue                     # open to everyone: not group dependent
        try:
            os.close(os.open(path, f)); got.append("rw"[bit == 2])
        except OSError:
            pass
    return got
out = []
for p in named:
    try:
        os.close(os.open(p, os.O_RDONLY | os.O_NONBLOCK)); out.append("named %s OPEN" % p)
    except OSError as e:
        out.append("named %s FAIL %d" % (p, e.errno))
me = os.getuid(); seen = 0; hit = []
for r in roots:
    for top, dirs, files in os.walk(r):
        for n in dirs + files:
            p = os.path.join(top, n)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if stat.S_ISLNK(st.st_mode) or st.st_uid == me:
                continue
            seen += 1
            g = opens(p, st)
            if g:
                hit.append("%s:%s" % (p, "".join(g)))
out.append("walk seen %d groupdep-open %d" % (seen, len(hit)))
out += ["hit " + h for h in hit]
for need in [sys.argv[0], "/usr/bin/python3", "/etc/passwd"]:
    try:
        os.close(os.open(need, os.O_RDONLY)); out.append("need %s OPEN" % need)
    except OSError as e:
        out.append("need %s FAIL %d" % (need, e.errno))
st = os.environ.get("DIRECTOR_STATE")
if st:
    try:
        open(os.path.join(st, "gprobe"), "w").write("x"); os.remove(os.path.join(st, "gprobe")); out.append("need state-bind WRITE OK")
    except OSError as e:
        out.append("need state-bind WRITE FAIL %d" % e.errno)
open(res, "w").write("\n".join(out) + "\n")
'
# Supplementary groups cannot be dropped from a user unit: probed (RED evidence in receipt7) `setpriv --clear-groups` under NoNewPrivileges/PrivateUsers
# and unshare -Ur/-U --map-* all keep the kernel credentials or fail EPERM (no newuidmap, no CAP_SETGID), so the files whose access depends on a group
# are hidden by InaccessiblePaths from a launch-time scan (group_gated_paths). The probe walks the same roots INSIDE the unit and tries to open every
# non-owned file that has no other-read (or other-write) bit: any success is group dependent, independent of the gids the unit displays (65534).
GROUP_NAMED='/var/log/auth.log,/var/log/syslog,/var/log/kern.log,/etc/ppp/peers/provider,/etc/chatscripts/provider'
GROUP_ROOTS='/etc,/var/log,/var/lib,/var/cache,/var/spool,/var/backups,/opt,/srv,/boot,/sys,/usr/sbin,/usr/bin,/usr/share/ppd'
t_unit_groups(){
  run_three grp "$GROUP_PROBE" "$(python3 -c "import json; print(json.dumps(['$GROUP_NAMED','$GROUP_ROOTS']))")"
  local u="$SCR/$P-grpunit" res ctl; res="$(cat "$u/result" 2>/dev/null)"; ctl="$(cat "$u/control" 2>/dev/null)"
  echo "--- inside the boundary:"; echo "$res" | head -40; echo "--- control (no boundary):"; echo "$ctl" | head -40
  [ -n "$res" ] && [ -n "$ctl" ] || { bad unit_groups "no probe output"; return; }
  local w
  for w in /var/log/auth.log /var/log/syslog /var/log/kern.log; do
    echo "$ctl" | grep -q "^named $w OPEN" || { bad unit_groups "control cannot open $w (test not discriminating)"; return; }
  done
  echo "$ctl" | grep -Eq '^walk seen [0-9]+ groupdep-open [1-9][0-9]*$' || { bad unit_groups "control walk found no group-dependent open"; return; }
  echo "$res" | grep -q '^named .* OPEN' && { bad unit_groups "group-gated file opens in the unit: $(echo "$res" | grep '^named .* OPEN' | cut -d' ' -f2 | tr '\n' ' ')"; return; }
  echo "$res" | grep -Eq '^walk seen [0-9]+ groupdep-open 0$' || { bad unit_groups "group-dependent opens in the unit: $(echo "$res" | grep '^hit ' | head -8 | tr '\n' ' ')"; return; }
  for w in /usr/bin/python3 /etc/passwd; do
    echo "$res" | grep -q "^need $w OPEN" || { bad unit_groups "unit lost access to $w"; return; }
  done
  echo "$res" | grep -q '^need .*probe.py OPEN' || { bad unit_groups "unit cannot read its scratch probe"; return; }
  echo "$res" | grep -q 'need state-bind WRITE OK' || { bad unit_groups "state bind not writable"; return; }
  echo "residual (documented): group-gated paths created after launch or outside the scanned roots (/usr/lib, /usr/share besides ppd, /mnt, /media, /home) stay open; override check is launch-time only (same-uid swap); scratch root is 0775 and the launcher dir's ancestors are unchecked; sockets created after launch under /run are hidden only by the /run tmpfs"
  ok unit_groups
}
t_override_hardening(){
  # check_overrides also requires the file to be owned by the current uid, not group/other writable, st_nlink == 1 and outside every
  # child-writable bind (the unit scratch dir, the state dirs). Synthetic files only; the foreign-owner case swaps os.getuid in the test.
  python3 - "$C" "$T" "$SCR" "$P" <<'PY'
import importlib.util, os, sys, shutil
c, t, scr, p = sys.argv[1:5]
base = os.path.dirname(scr) + "/ov6-" + p                         # same filesystem as the scratch root, outside it, for a hardlink source
os.makedirs(base, exist_ok=True)
w = scr + "/ov6-" + p; os.makedirs(w, mode=0o700)                 # a launcher dir (not a unit dir) under the scratch root
unitdir = scr + "/director-run-ov6-" + p + "-a1"; os.makedirs(unitdir + "/home"); os.makedirs(unitdir + "/hermes-home")
st = w + "/state"; os.makedirs(st)
os.environ.update(DIRECTOR_STATE=t + "/st6", WM_ASKS_CMD=t + "/wm-asks", WM_DECIDE_STATE=t + "/wm6", DIRECTOR_SCRATCH=unitdir)
for k in ("DIRECTOR_LAUNCH_CMD", "DIRECTOR_RESET_CMD", "DIRECTOR_ISOLATION"): os.environ.pop(k, None)
spec = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.makedirs(t + "/st6", exist_ok=True)
def mk(path, mode=0o700, body="#!/bin/sh\nexit 0\n"):
    open(path, "w").write(body); os.chmod(path, mode); return path
def refused(path, key="DIRECTOR_LAUNCH_CMD"):
    for k in ("DIRECTOR_LAUNCH_CMD", "DIRECTOR_RESET_CMD"): os.environ.pop(k, None)
    os.environ[key] = path; return m.check_overrides()
good = mk(w + "/good")
assert refused(good) == [], "baseline file must pass: %r" % refused(good)
assert refused(good + " arg1 arg2", "DIRECTOR_RESET_CMD") == [], "args after the file"
outside = mk(base + "/outside")
os.link(outside, w + "/hardlink")
assert refused(w + "/hardlink") == ["DIRECTOR_LAUNCH_CMD"], "hardlink to an outside inode (nlink 2) must be refused"
good2 = mk(w + "/twice"); os.link(good2, w + "/twice-link")
assert refused(good2) == ["DIRECTOR_LAUNCH_CMD"], "file with a second link must be refused"
assert refused(mk(w + "/gw", 0o770)) == ["DIRECTOR_LAUNCH_CMD"], "group-writable"
assert refused(mk(w + "/ow", 0o707)) == ["DIRECTOR_LAUNCH_CMD"], "other-writable"
assert refused(mk(w + "/gw2", 0o720)) == ["DIRECTOR_LAUNCH_CMD"], "group-writable 0720"
assert refused(mk(w + "/rx", 0o755)) == [], "group/other read+exec is fine"
assert refused(mk(unitdir + "/child-wrote")) == ["DIRECTOR_LAUNCH_CMD"], "executable inside the child-writable unit scratch dir"
assert refused(mk(unitdir + "/home/dropper")) == ["DIRECTOR_LAUNCH_CMD"], "executable the child dropped in its home"
other = scr + "/director-run-ov6-" + p + "-a0"; os.makedirs(other + "/home"); os.makedirs(other + "/hermes-home")
assert refused(mk(other + "/prior")) == ["DIRECTOR_LAUNCH_CMD"], "executable a prior child wrote in its own unit dir"
os.environ["DIRECTOR_STATE"] = st
assert refused(mk(st + "/in-state")) == ["DIRECTOR_LAUNCH_CMD"], "executable inside the state dir bind"
os.environ["DIRECTOR_STATE"] = t + "/st6"
real = os.getuid; os.getuid = lambda: real() + 1
try:
    assert refused(good) == ["DIRECTOR_LAUNCH_CMD"], "file owned by another uid"
finally:
    os.getuid = real
assert refused(good) == []
# a symlink in the scratch root whose target is an outside file is still refused (realpath), and the writable parent dir case
os.symlink(outside, w + "/sym"); assert refused(w + "/sym") == ["DIRECTOR_LAUNCH_CMD"]
os.chmod(w, 0o777)
try:
    assert refused(good) == ["DIRECTOR_LAUNCH_CMD"], "file in a group/other-writable directory"
finally:
    os.chmod(w, 0o700)
shutil.rmtree(base); shutil.rmtree(w); shutil.rmtree(unitdir); shutil.rmtree(other)
print("override hardening ok")
PY
  local rc=$?; rm -rf "$SCR/ov6-$P" "$(dirname "$SCR")/ov6-$P" "$SCR/director-run-ov6-$P"-*; [ $rc = 0 ] && ok override_hardening || bad override_hardening "rc=$rc"
}
if [ $# -gt 0 ]; then "t_$1"; else for t in credential_stripped missing_var_fails_closed live_path_fails_closed live_home_fails_closed symlink_alias_fails_closed scratch_home_positive launch_argv unit_boundary_fake_home unit_real_home unit_ipc_net_shm unit_devices_proc override_refused unit_sockets unit_socket_negative unit_socket_installed_builder listing_na_selfcheck unit_listing unit_groups override_hardening; do "t_$t"; done; fi
[ "$fails" -eq 0 ] || { echo "FAILURES: $fails"; exit 1; }
