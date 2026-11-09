#!/usr/bin/env bash
# Fake mode for tests/user-manager-restart.test.sh. Usage: user-manager-restart-fakes.sh <bindir>
# writes fake systemctl/useradd/userdel/kill/sudo/id into <bindir>. Fakes read STATE (dir) and
# FAKE_MODE (ok | norestart | restartonstop), FAKE_UID (default 990), FAKE_NOSUDO=1 at run time.
set -eu
d=$1; mkdir -p "$d"
w() { cat > "$d/$1"; chmod +x "$d/$1"; }
w fsudo <<'F'
#!/usr/bin/env bash
[ "${FAKE_NOSUDO:-0}" = 1 ] && exit 1
exec "$@"
F
w fid <<'F'
#!/usr/bin/env bash
[ "$1" = -u ] || exit 1
if [ $# -ge 2 ]; then [ -f "$STATE/uid" ] && cat "$STATE/uid" || exit 1; else echo "${FAKE_CALLER_UID:-1001}"; fi
F
w fuseradd <<'F'
#!/usr/bin/env bash
echo "useradd $*" >> "$STATE/calls.log"; echo "${FAKE_UID:-990}" > "$STATE/uid"
F
w fuserdel <<'F'
#!/usr/bin/env bash
echo "userdel $*" >> "$STATE/calls.log"; rm -f "$STATE/uid"
F
w fkill <<'F'
#!/usr/bin/env bash
echo "kill $*" >> "$STATE/calls.log"
pid=$2
[ "$pid" = "$(cat "$STATE/mainpid")" ] || exit 1
if [ "${FAKE_MODE:-ok}" = norestart ]; then echo inactive > "$STATE/active"
else echo $((pid + 1)) > "$STATE/mainpid"; echo $(( $(cat "$STATE/nrestarts") + 1 )) > "$STATE/nrestarts"; fi
F
w fsystemctl <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STATE/calls.log"
case $1 in
  daemon-reload) ;;
  start) echo 4200 > "$STATE/mainpid"; echo 0 > "$STATE/nrestarts"; echo active > "$STATE/active" ;;
  stop) echo inactive > "$STATE/active"
    if [ "${FAKE_MODE:-ok}" = restartonstop ]; then
      echo $(( $(cat "$STATE/mainpid") + 1 )) > "$STATE/mainpid"; echo $(( $(cat "$STATE/nrestarts") + 1 )) > "$STATE/nrestarts"; echo active > "$STATE/active"
    fi ;;
  show) a=$(cat "$STATE/active" 2>/dev/null || echo inactive)
    case $4 in
      MainPID) [ "$a" = active ] && cat "$STATE/mainpid" || echo 0 ;;
      NRestarts) cat "$STATE/nrestarts" ;;
      ActiveState) echo "$a" ;;
      SubState) [ "$a" = active ] && echo running || echo dead ;;
    esac ;;
esac
F
