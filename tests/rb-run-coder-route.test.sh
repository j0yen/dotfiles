#!/usr/bin/env bash
# rb-run-coder-route.test.sh - repo routing in rb-run-coder.sh (ask A57, Joe 10-27 approvals #49): .config/fleet/coder-hosts.tsv sends synthorg/wm-build coders to ryzen7.
# (a) synthorg prompt on redbaron -> scp + ssh systemd-run on ryzen7 with RB_CODER_HOST pinned, no local claude; (b) mcphost prompt -> local claude;
# (c) remote failure -> 79, no local claude; (d) RB_CODER_HOST=redbaron forces local; (e) carbon still refused 79; (f) pinned RB_CODER_HOST=ryzen7 on ryzen7 runs local (no re-route).
# Every case runs under a fresh HOME with stub hostname/ssh/scp/claude/seat-event/journalctl/systemctl on PATH; nothing real is touched.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runc=${RB_RUN_CODER_UNDER_TEST:-$here/.local/bin/rb-run-coder.sh}
fail=0; pass() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-run-coder-route-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-run-coder-route-test.*) rm -rf "$R";; esac' EXIT
unset RB_CODER_HOST CARBON_ROOM_HOST CARBON_ROOM_RESERVE_MB CARBON_ROOM_HOSTNAME
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/ok-hold"
printf '#!/usr/bin/env bash\necho "room ok: avail=8077 need=$1 reserve=3072 left=1"\n' > "$R/ok-room"
printf '#!/usr/bin/env bash\necho "memcap ok: unit=t high=1 max=2"\n' > "$R/ok-memcap"
chmod +x "$R"/ok-*
body() { # body <first line>: >= 200 bytes, carries both lint rules
  printf '%s\n' "$1"; head -c 300 /dev/zero | tr '\0' 'x'; printf '\nkill only pids you started, by pid\nLIVE CLONES (never commit, checkout, reset or edit in place; clone them into a mktemp -d instead):\n'; }
python3 -I - "$R/hatch.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE decisions (id text, ts text, kind text, model text, what text, evidence text, regrade text)")
db.commit()
PY
# case_ <name> <hostname> <first-line> <ssh-mode ok|fail|scpfail> [env...]; sets H, D, rc
case_() {
  local name=$1 host=$2 first=$3 mode=$4; shift 4
  H=$R/$name; D=$H/.cache/rb-seat/coders; mkdir -p "$H/.config/environment.d" "$H/.local/bin" "$H/bin" "$D"; : > "$H/.config/environment.d/90-claude-oauth.conf"
  body "$first" > "$H/prompt.md"
  local hid=d-$(date +%Y%m%d-%H%M%S)-rb-rt sha; sha=$(body "$first" | sha256sum | cut -d' ' -f1)   # hatch sha = prompt minus the Hatch line
  printf 'Hatch: %s\n' "$hid" >> "$H/prompt.md"
  python3 -I -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("delete from decisions"); d.execute("insert into decisions values (?,?,?,?,?,?,?)", (sys.argv[2],"t","decision",None,"NO-SPEC-SPAWN route fixture","sha256:"+sys.argv[3],None)); d.commit()' "$R/hatch.db" "$hid" "$sha"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/events"\n' "$H" > "$H/.local/bin/seat-event.sh"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/claude.ran"\nexit 0\n' "$H" > "$H/bin/claude"
  printf '#!/usr/bin/env bash\ncase "$1" in -s) echo %s;; *) echo %s;; esac\n' "$host" "$host" > "$H/bin/hostname"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$H/bin/journalctl"; printf '#!/usr/bin/env bash\nexit 0\n' > "$H/bin/systemctl"
  printf '#!/usr/bin/env bash\necho "ssh $*" >> "%s/remote.log"\n[ "%s" = fail ] && [[ "$*" == *systemd-run* ]] && exit 1\nexit 0\n' "$H" "$mode" > "$H/bin/ssh"
  printf '#!/usr/bin/env bash\necho "scp $*" >> "%s/remote.log"\n[ "%s" = scpfail ] && exit 1\nexit 0\n' "$H" "$mode" > "$H/bin/scp"
  chmod +x "$H/.local/bin/"* "$H/bin/"*
  out=$(env PATH="$H/bin:$PATH" HOME="$H" RB_DECISIONS_DB="$R/hatch.db" RB_SPAWN_HOLD_BIN="$R/ok-hold" RB_MEMCAP_BIN="$R/ok-memcap" RB_ROOM_BIN="$R/ok-room" RB_ROOM_PEAK_MB=100 \
    RB_ROOM_MEMGATE_SUM_MB=0 RB_ROOM_HOSTNAME=redbaron "$@" bash "$runc" t "$H/prompt.md" 2>&1); rc=$?
}

case_ a redbaron 'You are a coder on RedBaron for j0yen/synthorg.' ok
if [ $rc = 0 ] && [ ! -e "$H/claude.ran" ] && grep -q 'scp .*ryzen7:.cache/rb-seat/coders/t.prompt' "$H/remote.log" \
  && grep -q 'ssh .*ryzen7 systemd-run --user --unit rb-coder-t --collect -p TasksMax=infinity -p IOWeight=50 --setenv=RB_CODER_HOST=ryzen7 .*rb-run-coder.sh t .*t.prompt' "$H/remote.log" && [[ $out == *'report=ryzen7:'* ]]; then
  pass "(a) synthorg on redbaron -> scp + ssh systemd-run on ryzen7, RB_CODER_HOST pinned, no local claude, $out"; else bad "(a) rc=$rc out=$out log=$(cat "$H/remote.log" 2>&1)"; fi
case_ a2 redbaron 'You are a coder on RedBaron for j0yen/wm-build.' ok
[ $rc = 0 ] && grep -q 'ryzen7 systemd-run' "$H/remote.log" && [ ! -e "$H/claude.ran" ] && pass "(a2) wm-build -> ryzen7" || bad "(a2) rc=$rc out=$out"
case_ b redbaron 'You are a coder on RedBaron for j0yen/mcphost.' ok
if [ $rc = 0 ] && [ -e "$H/claude.ran" ] && [ ! -e "$H/remote.log" ]; then pass "(b) mcphost on redbaron -> local claude, no ssh/scp"; else bad "(b) rc=$rc out=$out"; fi
case_ c redbaron 'You are a coder on RedBaron for j0yen/synthorg.' fail
rep=$(cat "$D/t.report.md" 2>/dev/null)
if [ $rc = 79 ] && [ ! -e "$H/claude.ran" ] && [[ $rep == 'REFUSED remote-launch host=ryzen7'* ]]; then pass "(c) systemd-run fails -> 79, '$rep', no local claude"; else bad "(c) rc=$rc rep=$rep"; fi
case_ c2 redbaron 'You are a coder on RedBaron for j0yen/synthorg.' scpfail
[ $rc = 79 ] && [ ! -e "$H/claude.ran" ] && ! grep -q systemd-run "$H/remote.log" && pass "(c2) scp fails -> 79, no systemd-run, no local claude" || bad "(c2) rc=$rc"
case_ d redbaron 'You are a coder on RedBaron for j0yen/synthorg.' ok RB_CODER_HOST=redbaron
[ $rc = 0 ] && [ -e "$H/claude.ran" ] && [ ! -e "$H/remote.log" ] && pass "(d) RB_CODER_HOST=redbaron forces local" || bad "(d) rc=$rc out=$out"
case_ e carbon 'You are a coder on RedBaron for j0yen/synthorg.' ok
[ $rc = 79 ] && [[ $out == *'REFUSED host=carbon'* ]] && [ ! -e "$H/claude.ran" ] && [ ! -e "$H/remote.log" ] && pass "(e) carbon refused 79" || bad "(e) rc=$rc out=$out"
case_ f ryzen7 'You are a coder on ryzen7 for j0yen/synthorg.' ok RB_CODER_HOST=ryzen7
[ $rc = 0 ] && [ -e "$H/claude.ran" ] && [ ! -e "$H/remote.log" ] && pass "(f) pinned RB_CODER_HOST=ryzen7 on ryzen7 -> local, no re-route" || bad "(f) rc=$rc out=$out"
exit $fail
