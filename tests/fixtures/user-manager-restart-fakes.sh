#!/usr/bin/env bash
# Fake mode for tests/user-manager-restart.test.sh. Usage: user-manager-restart-fakes.sh <bindir>
# writes fake systemctl/useradd/userdel/getent/kill/sudo/id/mkdir/rmdir/rm/tee into <bindir>; every fake but
# sudo and id logs its call to $STATE/calls.log. Fakes read STATE (dir), FAKE_MODE (ok | norestart | restartonstop),
# FAKE_UID (default 990), FAKE_CALLER_UID (default 1001), FAKE_NOSUDO=1, FAKE_PREEXIST=1 (getent answers uid 990 for
# any umtest-* name), FAKE_USERADD_RC (nonzero = useradd fails, no account), FAKE_PREACTIVE=1 (manager active before start).
# Usage: user-manager-restart-fakes.sh --seed-dropdir <rundir> <uid>  makes <rundir>/user@<uid>.service.d/sentinel
# (a pre-existing drop-in dir) and prints the sentinel's sha256.
set -eu
if [ "$1" = --seed-dropdir ]; then
  dd=$2/user@$3.service.d; mkdir -p "$dd"
  printf 'sentinel %s\n' "$3" > "$dd/sentinel"
  sha256sum < "$dd/sentinel" | cut -d' ' -f1
  exit 0
fi
d=$1; mkdir -p "$d"
w() { cat > "$d/$1"; chmod +x "$d/$1"; }
w fsudo <<'F'
#!/usr/bin/env bash
[ "${FAKE_NOSUDO:-0}" = 1 ] && exit 1
exec "$@"
F
w fid <<'F'
#!/usr/bin/env bash
[ "$*" = -u ] && echo "${FAKE_CALLER_UID:-1001}"
F
w fgetent <<'F'
#!/usr/bin/env bash
echo "getent $*" >> "$STATE/calls.log"
[ "$1" = passwd ] || exit 1
case $2 in umtest-*) [ "${FAKE_PREEXIST:-0}" = 1 ] && { echo "$2:x:990:990::/var/tmp/$2:/usr/sbin/nologin"; exit 0; } ;; esac
[ -f "$STATE/users/$2" ] || exit 2
echo "$2:x:$(cat "$STATE/users/$2"):$(cat "$STATE/users/$2")::/var/tmp/$2:/usr/sbin/nologin"
F
w fuseradd <<'F'
#!/usr/bin/env bash
echo "useradd $*" >> "$STATE/calls.log"
[ "${FAKE_USERADD_RC:-0}" = 0 ] || exit "$FAKE_USERADD_RC"
name=${!#}; mkdir -p "$STATE/users"
[ -e "$STATE/users/$name" ] && exit 9
echo "${FAKE_UID:-990}" > "$STATE/users/$name"
F
w fuserdel <<'F'
#!/usr/bin/env bash
echo "userdel $*" >> "$STATE/calls.log"; rm -f "$STATE/users/${!#}"
F
for c in mkdir rmdir rm tee; do
  w "f$c" <<F
#!/usr/bin/env bash
echo "$c \$*" >> "\$STATE/calls.log"
exec $c "\$@"
F
done
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
  show) d=inactive; [ "${FAKE_PREACTIVE:-0}" = 1 ] && d=active
    a=$(cat "$STATE/active" 2>/dev/null || echo $d)
    case $4 in
      MainPID) [ "$a" = active ] && cat "$STATE/mainpid" || echo 0 ;;
      NRestarts) cat "$STATE/nrestarts" ;;
      ActiveState) echo "$a" ;;
      SubState) [ "$a" = active ] && echo running || echo dead ;;
    esac ;;
esac
F
