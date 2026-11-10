#!/usr/bin/env bash
# Fake mode for tests/user-manager-restart.test.sh. Usage: user-manager-restart-fakes.sh <bindir>
# writes fake systemctl/useradd/userdel/getent/kill/sudo/id/mkdir/rmdir/rm/tee into <bindir>; fake sudo drops a
# leading -n (the test calls "$SUDO" -n "$X" ...); every fake but sudo and id logs its call to $STATE/calls.log.
# A1488: fake sudo runs only a regular executable directly inside its own bindir (not itself); "true" alone (the
# test's "$SUDO" -n true probe) exits 0 running nothing; anything else logs "fsudo-refused <argv1> <resolved>", exit 126.
# A1488 D3: every fake is #!/bin/bash -p (no BASH_ENV, no imported functions) and sets the fixed PATH
# /usr/sbin:/usr/bin:/sbin:/bin (sudo's secure_path) before any other command, so a fake and the target fsudo execs
# never run a command from the caller's PATH.
# Fakes read STATE (dir), FAKE_MODE (ok | norestart | restartonstop),
# FAKE_UID (default 990), FAKE_CALLER_UID (default 1001; set empty = fid -u prints an empty line), FAKE_ID_RC (fid exit
# status, default 0), FAKE_NOSUDO=1, FAKE_PREEXIST=1 (getent answers uid 990 for
# any umtest-* name), FAKE_USERADD_RC (nonzero = useradd fails, no account), FAKE_PREACTIVE=1 (manager active before start), FAKE_STARTRC (nonzero = systemctl start fails).
# Usage: user-manager-restart-fakes.sh --seed-dropdir <rundir> <uid>  makes <rundir>/user@<uid>.service.d/sentinel
# (a pre-existing drop-in dir) and prints the sentinel's sha256.
set -eu
if [ "$1" = --seed-dropdir ]; then
  dd=$2/user@$3.service.d; mkdir -p "$dd"
  printf 'sentinel %s\n' "$3" > "$dd/sentinel"
  sha256sum < "$dd/sentinel" | cut -d' ' -f1
  exit 0
fi
d=$1; mkdir -p "$d"; chmod go-w "$d"
# w <name>: the fake body on stdin, after the fixed shebang and PATH
w() { { printf '#!/bin/bash -p\nPATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH\n'; cat; } > "$d/$1"; chmod +x "$d/$1"; }
w fsudo <<'F'
[ "${FAKE_NOSUDO:-0}" = 1 ] && exit 1
[ "${1:-}" = -n ] && shift
[ "$*" = true ] && exit 0
self=$(realpath -e -- "$0") || exit 126
t=$(command -v -- "${1:-}") && t=$(realpath -e -- "$t") || t=
if [ -z "$t" ] || [ "$t" = "$self" ] || [ "$(dirname -- "$t")" != "$(dirname -- "$self")" ] || [ ! -f "$t" ] || [ ! -x "$t" ]; then
  [ -n "${STATE:-}" ] && echo "fsudo-refused ${1:-} ${t:--}" >> "$STATE/calls.log"
  echo "fsudo: refused ${1:-} (${t:--}): not a fake in $(dirname -- "$self")" >&2
  exit 126
fi
shift
exec "$t" "$@"
F
w fid <<'F'
[ "$*" = -u ] && echo "${FAKE_CALLER_UID-1001}"
exit "${FAKE_ID_RC:-0}"
F
w fgetent <<'F'
echo "getent $*" >> "$STATE/calls.log"
[ "$1" = passwd ] || exit 1
case $2 in umtest-*) [ "${FAKE_PREEXIST:-0}" = 1 ] && { echo "$2:x:990:990::/var/tmp/$2:/usr/sbin/nologin"; exit 0; } ;; esac
[ -f "$STATE/users/$2" ] || exit 2
echo "$2:x:$(cat "$STATE/users/$2"):$(cat "$STATE/users/$2")::/var/tmp/$2:/usr/sbin/nologin"
F
w fuseradd <<'F'
echo "useradd $*" >> "$STATE/calls.log"
[ "${FAKE_USERADD_RC:-0}" = 0 ] || exit "$FAKE_USERADD_RC"
name=${!#}; mkdir -p "$STATE/users"
[ -e "$STATE/users/$name" ] && exit 9
echo "${FAKE_UID:-990}" > "$STATE/users/$name"
F
w fuserdel <<'F'
echo "userdel $*" >> "$STATE/calls.log"; rm -f "$STATE/users/${!#}"
F
for c in mkdir rmdir rm tee; do
  w "f$c" <<F
echo "$c \$*" >> "\$STATE/calls.log"
exec $c "\$@"
F
done
w fkill <<'F'
echo "kill $*" >> "$STATE/calls.log"
pid=$2
[ "$pid" = "$(cat "$STATE/mainpid")" ] || exit 1
if [ "${FAKE_MODE:-ok}" = norestart ]; then echo inactive > "$STATE/active"
else echo $((pid + 1)) > "$STATE/mainpid"; echo $(( $(cat "$STATE/nrestarts") + 1 )) > "$STATE/nrestarts"; fi
F
w fsystemctl <<'F'
echo "systemctl $*" >> "$STATE/calls.log"
case $1 in
  daemon-reload) ;;
  start) [ "${FAKE_STARTRC:-0}" = 0 ] || exit "$FAKE_STARTRC"
    echo 4200 > "$STATE/mainpid"; echo 0 > "$STATE/nrestarts"; echo active > "$STATE/active" ;;
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
