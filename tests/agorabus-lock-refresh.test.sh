#!/usr/bin/env bash
# agorabus-lock-refresh.sh: fakes for git, cargo and hostname on a temp PATH, temp HOME and root (A1487).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="${LOCKREF_SCRIPT:-$here/.local/bin/agorabus-lock-refresh.sh}"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok() { echo "ok - $1"; }
no() { echo "NOT OK - $1"; fail=1; }

# scenario <name> <hostname> <deny rcs, space list> [test rc]
scenario() {
  local host="$2" denys="$3" trc="${4:-0}" d="$tmp/$1"
  mkdir -p "$d/bin" "$d/home" "$d/root"
  # shellcheck disable=SC2086
  printf '%s\n' $denys > "$d/denyq"
  printf '#!/bin/sh\necho %s\n' "$host" > "$d/bin/hostname"
  cat > "$d/bin/git" <<G
#!/bin/sh
echo "git \$*" >> "$d/gitlog"
case "\$1" in
  clone) for a; do last=\$a; done; mkdir -p "\$last"; : > "\$last/Cargo.lock";;
  rev-parse) echo abc1234;;
esac
exit 0
G
  cat > "$d/bin/cargo" <<C
#!/bin/sh
echo "cargo \$*" >> "$d/cargolog"
case "\$1" in
  deny) rc=\$(head -n1 "$d/denyq"); sed -i 1d "$d/denyq"; exit \${rc:-0};;
  test) exit $trc;;
esac
exit 0
C
  chmod +x "$d"/bin/*
  HOME="$d/home" PATH="$d/bin:$PATH" LOCK_REFRESH_ROOT="$d/root" LOCK_REFRESH_STATE="$d/home/state" bash "$S" > "$d/out" 2>&1
}
last() { cat "$tmp/$1/home/state/last.txt" 2>/dev/null; }
pend() { cat "$tmp/$1/home/state/pending.txt" 2>/dev/null; }

# (a) non-redbaron host
scenario a carbon "0"
if grep -q 'skip: not redbaron' "$tmp/a/out" && [ ! -e "$tmp/a/gitlog" ] && [ ! -e "$tmp/a/home/state" ]; then ok "a: skip off redbaron, no clone"; else no "a: skip off redbaron"; fi

# (b) deny green
scenario b redbaron "0"
if last b | grep -q 'deny=green refreshed=no tests=skip' && [ -z "$(pend b)" ] && grep -q 'git clone' "$tmp/b/gitlog"; then ok "b: green -> refreshed=no, nothing pending"; else no "b: green ($(last b))"; fi

# (c) red, then green after update, tests pass
scenario c redbaron "1 0"
if last c | grep -q 'deny=green refreshed=yes tests=pass.*head=abc1234' && pend c | grep -q refreshed=yes \
  && grep -q "checkout -q -b chore/lock-refresh-$(date +%Y%m%d)" "$tmp/c/gitlog" && grep -q 'commit' "$tmp/c/gitlog" && grep -q 'cargo update' "$tmp/c/cargolog"; then
  ok "c: refresh committed locally, pending written"; else no "c: refresh ($(last c))"; fi

# (d) still red after update
scenario d redbaron "1 1"
if last d | grep -q 'deny=red refreshed=no tests=skip' && pend d | grep -q 'deny=red' && ! grep -q commit "$tmp/d/gitlog"; then ok "d: still red -> pending says red, no commit"; else no "d: red ($(last d))"; fi

# (g) deny green after update, tests fail
scenario g redbaron "1 0" 1
if last g | grep -q 'deny=green refreshed=no tests=fail' && pend g | grep -q tests=fail && ! grep -q commit "$tmp/g/gitlog"; then ok "g: tests fail -> no commit, pending"; else no "g: tests fail ($(last g))"; fi

# (e) the source sends nothing to GitHub
if grep -v '^ *#' "$S" | grep -Eq 'git[^|;&]* pu''sh|(^|[;&| ])gh '; then no "e: remote-send call present"; else ok "e: no git send, no gh call"; fi

# (f) prune touches only old dated dirs directly under the configured root
d="$tmp/f"; mkdir -p "$d/root/20200101" "$d/outside/20200101" "$d/root/keepfile" "$d/root/20991231"
touch -d '30 days ago' "$d/root/20200101" "$d/outside/20200101" "$d/root/keepfile"
scenario f redbaron "0"
if [ ! -e "$d/root/20200101" ] && [ -d "$d/outside/20200101" ] && [ -d "$d/root/keepfile" ] && [ -d "$d/root/20991231" ]; then ok "f: prune old dated dir under root only"; else no "f: prune"; fi
exit $fail
