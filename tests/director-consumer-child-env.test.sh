#!/usr/bin/env bash
# director-consumer-child-env.test.sh: worker launch carries an explicit env allowlist and fails closed. Stub provider only:
# no real Hermes, no credentials, no network, no systemd unit started. Usage: <this> [test-name]   (default: all four)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
C="$HERE/.local/bin/director-event-consumer.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok(){ echo "PASS $1"; }
bad(){ echo "FAIL $1${2:+: $2}"; fails=$((fails+1)); }

printf '#!/usr/bin/env bash\necho called >> %s/provider.calls; env | sort > %s/provider.env\n' "$T" "$T" > "$T/provider"
chmod +x "$T/provider"
ISO=(DIRECTOR_STATE="$T/st" WM_ASKS_CMD="$T/wm-asks" WM_DECIDE_STATE="$T/wmstate" DIRECTOR_ISOLATION=1 DIRECTOR_CHILD_REQUIRE=DIRECTOR_STATE,WM_ASKS_CMD,WM_DECIDE_STATE)

t_credential_stripped(){
  rm -f "$T/provider.calls" "$T/provider.env"
  env "${ISO[@]}" PATH="$PATH" HOME="$T/home" ANTHROPIC_API_KEY=fake-secret-1 CLAUDE_CODE_OAUTH_TOKEN=fake-secret-2 \
      OPENAI_API_KEY=fake-secret-3 GH_TOKEN=fake-secret-4 python3 "$C" child-exec -- "$T/provider"; rc=$?
  [ "$rc" = 0 ] && [ -s "$T/provider.calls" ] || { bad credential_stripped "rc=$rc, provider not run"; return; }
  if grep -Eq 'fake-secret|API_KEY|TOKEN' "$T/provider.env"; then bad credential_stripped "credential reached the child"; return; fi
  grep -q "^WM_ASKS_CMD=$T/wm-asks$" "$T/provider.env" && grep -q "^WM_DECIDE_STATE=$T/wmstate$" "$T/provider.env" \
    && grep -q "^DIRECTOR_STATE=$T/st$" "$T/provider.env" && ok credential_stripped || bad credential_stripped "isolation vars missing in child"
}
t_missing_var_fails_closed(){
  rm -f "$T/provider.calls"
  env DIRECTOR_STATE="$T/st" WM_DECIDE_STATE="$T/wmstate" DIRECTOR_ISOLATION=1 DIRECTOR_CHILD_REQUIRE=DIRECTOR_STATE,WM_ASKS_CMD,WM_DECIDE_STATE \
      PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>"$T/err"; rc=$?
  [ "$rc" = 78 ] && [ ! -e "$T/provider.calls" ] && grep -q "WM_ASKS_CMD" "$T/err" && ok missing_var_fails_closed || bad missing_var_fails_closed "rc=$rc calls=$(cat "$T/provider.calls" 2>/dev/null)"
}
t_live_path_fails_closed(){
  rm -f "$T/provider.calls"; local r1 r2 r3
  env "${ISO[@]}" DIRECTOR_STATE="$HOME/.local/state/director-consumer" PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>/dev/null; r1=$?
  env "${ISO[@]}" WM_DECIDE_STATE="$HOME/.local/state/swarm-decide" PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>/dev/null; r2=$?
  env "${ISO[@]}" WM_ASKS_CMD=wm-asks PATH="$PATH" python3 "$C" child-exec -- "$T/provider" 2>/dev/null; r3=$?
  [ "$r1 $r2 $r3" = "78 78 78" ] && [ ! -e "$T/provider.calls" ] && ok live_path_fails_closed || bad live_path_fails_closed "rc=$r1 $r2 $r3"
}
t_launch_argv(){
  python3 - "$C" "$T" <<'PY'
import importlib.util, os, sys
c, t = sys.argv[1:3]
os.environ.update(DIRECTOR_STATE=t + "/st", WM_ASKS_CMD=t + "/wm-asks", WM_DECIDE_STATE=t + "/wmstate", ANTHROPIC_API_KEY="fake-secret-1")
sp = importlib.util.spec_from_file_location("dec", c); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
a = m.launch_argv("u1", "/e.md")
j = " ".join(a)
assert a[:3] == ["systemd-run", "--user", "--unit"], a
for need in ("--setenv WM_ASKS_CMD=" + t + "/wm-asks", "--setenv WM_DECIDE_STATE=" + t + "/wmstate", "--setenv DIRECTOR_STATE=" + t + "/st",
             "--setenv DIRECTOR_ISOLATION=1", "-p ProtectHome=read-only", "-p NoNewPrivileges=yes", " child-exec -- "):
    assert need in j, need
assert "fake-secret" not in j and "API_KEY" not in j, "credential on the unit"
for cap in ("RuntimeMaxSec", "MemoryMax", "CPUQuota", "TimeoutStopSec", "max-turns", "budget"):
    assert cap not in j, cap
print("vars:", ",".join(sorted(x.split("=")[0] for x in a if "=" in x and a[a.index(x) - 1] == "--setenv")))
PY
  [ $? = 0 ] && ok launch_argv || bad launch_argv
}
if [ $# -gt 0 ]; then "t_$1"; else t_credential_stripped; t_missing_var_fails_closed; t_live_path_fails_closed; t_launch_argv; fi
[ "$fails" -eq 0 ] || { echo "FAILURES: $fails"; exit 1; }
