#!/usr/bin/env bash
# disk-health-sudoers.test.sh - NO-DRIFT test: the sudoers rule `disk-health-sudoers --render` produces is exactly what disk-health.sh asks sudo to run.
# A fake `sudo` on a sandbox PATH is the oracle: `-n -l <cmd>` exits 0 iff the command line matches a Cmnd of the render (sudoers glob semantics for
# [a-z] / [0-9] only), `-n <cmd>` runs the fake tool only on a match and is refused like a password-required sudo otherwise. disk-health.sh's real
# collector runs against fake lsblk/smartctl/nvme (sda = usb bridge, nvme0n1); the fake smartctl for sda fails plain and every -d type, so every
# fallback is asked. Asserts: sudo accepts every line the collector sends (no missing grant), every Cmnd was used by at least one line (no dead
# grant), and the render passes a lint (no '*', '?', '!', ALL, sudoedit, odd char class, relative path, ',' in a Cmnd, -s/-t/-X/--set).
# Then (full mode) three mutations, each in a mktemp copy of the repo, must turn this test red: a new smartctl flag in disk-health.sh, an extra
# Cmnd in the template, a '*' in the template. No sudo is run, nothing under /etc or $HOME is written.
#   disk-health-sudoers.test.sh          full (core + mutations)
#   disk-health-sudoers.test.sh --core   core only (what the mutations re-run)
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
script=$root/.local/bin/disk-health.sh
inst=$root/.local/bin/disk-health-sudoers
tmpl=$root/.local/share/disk-health/sudoers.tmpl
mode=${1:-full}
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

d=$(mktemp -d "${TMPDIR:-/tmp}/disk-health-sudoers-test.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf -- "$d"' EXIT
bin=$d/bin
mkdir -p "$bin" "$d/etc/sudoers.d"
chmod 755 "$d" "$bin"

bash -n "$inst" && pass "bash -n disk-health-sudoers" || bad "bash -n disk-health-sudoers"
[ -x "$inst" ] && pass "installer is executable" || bad "installer is not executable"

# ---- lint of a rendered file (fix 7). prints one reason per violation; rc 1 when any
lint_render() { # lint_render <file> <user>
  local f=$1 user=$2 line cmnd path rest tok rc=0 stripped n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    if [[ $line =~ ^$user\ ALL=\(root\)\ NOPASSWD:\ (.+)$ ]]; then cmnd=${BASH_REMATCH[1]}; else
      echo "not the one allowed rule shape '<user> ALL=(root) NOPASSWD: <one Cmnd>': $line"; rc=1; continue
    fi
    n=$((n + 1))
    path=${cmnd%% *}; rest=${cmnd#"$path"}
    [[ $path == /* ]] || { echo "relative command path: $cmnd"; rc=1; }
    [[ $path == *'/./'* || $path == *'/../'* ]] && { echo "dot component in command path: $cmnd"; rc=1; }
    [[ $cmnd == *'*'* || $cmnd == *'?'* ]] && { echo "wildcard * or ? in Cmnd: $cmnd"; rc=1; }
    [[ $cmnd == *'!'* ]] && { echo "negation ! in Cmnd: $cmnd"; rc=1; }
    [[ $cmnd == *,* ]] && { echo "',' inside one Cmnd: $cmnd"; rc=1; }
    [[ $path == ALL || ${path##*/} == ALL || ${path##*/} == sudoedit ]] && { echo "ALL or sudoedit as the command: $cmnd"; rc=1; }
    stripped=${cmnd//'[a-z]'/}; stripped=${stripped//'[0-9]'/}
    [[ $stripped == *'['* || $stripped == *']'* ]] && { echo "char class other than [a-z] / [0-9]: $cmnd"; rc=1; }
    for tok in $rest; do
      if [[ $tok == --set* || ( $tok == -[a-zA-Z]* && $tok != --* && $tok =~ [stX] ) ]]; then echo "write-capable smartctl flag $tok: $cmnd"; rc=1; fi
    done
  done <"$f"
  [ $n -gt 0 ] || { echo "no rules in the render"; rc=1; }
  return $rc
}

# the lint must itself reject each bad shape (a lint that passes everything proves nothing)
u=lintuser
lint_ok=1
while IFS='|' read -r label body; do
  printf '%s ALL=(root) NOPASSWD: %s\n' "$u" "$body" >"$d/lint.bad"
  if lint_render "$d/lint.bad" "$u" >/dev/null; then echo "  lint accepted ($label): $body"; lint_ok=0; fi
done <<'EOF'
star|/usr/sbin/smartctl -H -A -d * /dev/sda
star-dev|/usr/sbin/smartctl -H -A /dev/sd*
question|/usr/sbin/smartctl -H -A /dev/sd?
all|ALL
negation|/usr/sbin/smartctl !-s /dev/sda
comma|/usr/sbin/smartctl -H -A /dev/sda,/bin/sh
sudoedit|/usr/bin/sudoedit /etc/hosts
class|/usr/sbin/smartctl -H -A /dev/sd[A-Z]
class2|/usr/sbin/smartctl -H -A /dev/sd[abc]
relative|smartctl -H -A /dev/sda
dotdot|/usr/sbin/../bin/smartctl -H -A /dev/sda
flag-s|/usr/sbin/smartctl -H -A -s on /dev/sda
flag-t|/usr/sbin/smartctl -t long /dev/sda
flag-X|/usr/sbin/smartctl -X /dev/sda
flag-set|/usr/sbin/smartctl --set=standby,now /dev/sda
EOF
printf '%s ALL=(root) NOPASSWD: /usr/sbin/smartctl -H -A /dev/sd[a-z]\n%s ALL=(root) NOPASSWD: /usr/sbin/nvme smart-log /dev/nvme[0-9]n[0-9]\n' "$u" "$u" >"$d/lint.good"
lint_render "$d/lint.good" "$u" >/dev/null || lint_ok=0
[ $lint_ok = 1 ] && pass "render lint rejects every bad shape and accepts the good one" || bad "render lint is not discriminating"

# ---- sandbox: fakes + the real collector
for t in id stat readlink mktemp cat cmp diff head grep rm mv basename; do ln -s "$(type -P "$t")" "$bin/$t"; done
ln -s "$(readlink -f "$(type -P python3)")" "$bin/python3"
printf 'NAME="sda" TRAN="usb" TYPE="disk"\nNAME="nvme0n1" TRAN="nvme" TYPE="disk"\n' >"$d/lsblk.out"
cat >"$bin/lsblk" <<'F'
#!/bin/bash
cat "$FAKE_DIR/lsblk.out"
F
cat >"$bin/smartctl" <<'F'
#!/bin/bash
# sda (usb bridge): plain and every -d type fail except FAKE_OK_DTYPE (none = all fail, so every fallback is asked); nvme0n1 answers plain
dt=""; prev=""; for a in "$@"; do last=$a; [ "$prev" = -d ] && dt=$a; prev=$a; done
case $last in
  /dev/nvme*) ;;
  *) [ -n "$dt" ] && [ "$dt" = "${FAKE_OK_DTYPE:-none}" ] || { printf 'smartctl 7.4\nUnknown USB bridge [0x1234:0x5678 (0x100)]\nPlease specify device type with the -d option.\n'; exit 1; } ;;
esac
printf 'smartctl 7.4\nSMART overall-health self-assessment test result: PASSED\nSMART/Health Information (NVMe Log 0x02)\nPercentage Used:                    3%%\nUnsafe Shutdowns:                   5\nMedia and Data Integrity Errors:    0\n'
F
cat >"$bin/nvme" <<'F'
#!/bin/bash
printf 'Smart Log for NVME device:nvme0n1 namespace-id:ffffffff\ncritical_warning\t\t\t: 0\npercentage_used\t\t\t\t: 3%%\nunsafe_shutdowns\t\t\t: 5\nmedia_errors\t\t\t\t: 0\n'
F
cat >"$bin/sudo" <<'F'
#!/bin/bash
# THE ORACLE. Only `sudo -n ...` is ever legitimate (disk-health.sh must not prompt). `-n true` is refused (the narrow-sudoers shape: no blanket
# grant). `-n -l <cmd>` -> exit 0 iff <cmd> matches a Cmnd of the render; `-n <cmd>` -> run the fake tool iff it matches, else a refusal that disk-health.sh
# reads as needs-sudo. Every decision goes to sudo.log as  <list|exec>|<resolved command line>|<matching Cmnd numbers, empty = refused>
export LC_ALL=C
if [ "${1:-}" != -n ]; then echo "not -n: $*" >>"$FAKE_DIR/sudo.bad"; echo "sudo: a password is required" >&2; exit 1; fi
shift
how=exec; [ "${1:-}" = -l ] && { how=list; shift; }
[ "${1:-}" = true ] && { echo "true|true|" >>"$FAKE_DIR/sudo.nontool"; echo "sudo: a password is required" >&2; exit 1; }
cmd=$1; shift
case $cmd in /*) full=$cmd ;; *) full=$(command -v "$cmd") ;; esac
line="$full $*"
hits=; i=0
while IFS= read -r cm; do
  i=$((i + 1))
  [[ $line == $cm ]] && hits=${hits:+$hits,}$i
done <"$FAKE_DIR/cmnds"
echo "$how|$line|$hits" >>"$FAKE_DIR/sudo.log"
[ -n "$hits" ] || { echo "sudo: a password is required" >&2; exit 1; }
[ $how = list ] && exit 0
exec "$full" "$@"
F
chmod 755 "$bin"/lsblk "$bin"/smartctl "$bin"/nvme "$bin"/sudo

me=$(id -un)
sbx() { env -i HOME="$d" PATH="$bin" TMPDIR="$d" FAKE_DIR="$d" DISK_HEALTH_SUDOERS_TESTROOT="$d" "$@"; }

sbx "$BASH" "$inst" --render >"$d/render" 2>"$d/render.err"; rc=$?
[ $rc -eq 0 ] && pass "disk-health-sudoers --render on the sandbox exits 0" || { bad "render rc=$rc: $(cat "$d/render.err")"; }

if out=$(lint_render "$d/render" "$me"); then pass "render lint (no *, ?, !, ALL, sudoedit, odd class, relative path, ',', -s/-t/-X/--set)"; else bad "render lint: $out"; fi

grep -E '^[^#[:space:]]' "$d/render" | sed -E 's/^[^ ]+ ALL=\(root\) NOPASSWD: //' >"$d/cmnds"
ncm=$(wc -l <"$d/cmnds")
[ "$ncm" -eq 7 ] && pass "render has 7 Cmnds (smartctl x6 incl. every -d type, nvme smart-log)" || bad "render has $ncm Cmnds, expected 7: $(cat "$d/cmnds")"
grep -qx "# nvme: not installed on .*" "$d/render" && bad "render claims nvme absent in a sandbox that has it"

# ---- run the real collector twice: every -d type refused by the device, then the last one answering
: >"$d/sudo.log"
cd "$d" || exit 1
collect() { # collect <out.json> [VAR=val]
  local o=$1; shift
  sbx DISK_HEALTH_OUT="$o" DISK_HEALTH_HOST=fx DISK_HEALTH_EXTRA_PATH= "$@" "$BASH" "$script" >"$o.stdout" 2>"$o.stderr"
  echo $? >"$o.rc"
}
collect "$d/a.json" FAKE_OK_DTYPE=none
collect "$d/b.json" FAKE_OK_DTYPE=sntjmicron
[ "$(cat "$d/a.json.rc")" = 0 ] && [ "$(cat "$d/b.json.rc")" = 0 ] && pass "collector ran twice, exit 0" || bad "collector exit: $(cat "$d/a.json.rc") $(cat "$d/b.json.rc")"

# what the collector actually reads once sudo allows it
py_ok=$(python3 -I - "$d/b.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = {x["dev"]: x for x in d["devices"]}
ok = ("needs-sudo" not in d["errors"] and r["/dev/sda"]["smart_health"] == "PASSED" and r["/dev/sda"]["source"] == "smartctl:sntjmicron"
      and r["/dev/nvme0n1"]["smart_health"] == "PASSED" and r["/dev/nvme0n1"]["source"] == "nvme-cli+smartctl")
print("yes" if ok else "no: " + json.dumps(d["devices"]) + json.dumps(d["errors"]))
PY
)
[ "$py_ok" = yes ] && pass "with the render as the only grant: sda read via the last -d type, nvme0n1 via nvme-cli+smartctl, no needs-sudo" || bad "collector under the render: $py_ok"

nlog=$(wc -l <"$d/sudo.log")
[ "$nlog" -ge 14 ] && pass "oracle decided $nlog command lines" || bad "oracle saw only $nlog command lines (expected the full fallback chain)"
[ ! -s "$d/sudo.bad" ] && pass "every sudo call was non-interactive (-n)" || bad "sudo called without -n: $(cat "$d/sudo.bad")"
[ "$(cat "$d/sudo.nontool" 2>/dev/null | wc -l)" -ge 1 ] && pass "'sudo -n true' was refused, so only the per-command grants carried the read" || bad "collector never probed 'sudo -n true' (narrow-sudoers shape not exercised)"

# (1) no missing grant: sudo refused none of the lines disk-health.sh sent
refused=$(awk -F'|' '$3==""' "$d/sudo.log")
if [ -z "$refused" ]; then pass "sudo accepted every command line disk-health.sh sent (no missing / drifted grant)"; else
  bad "sudo refused a command line disk-health.sh runs (grant missing or its argv drifted):"; printf '%s\n' "$refused" | sed 's/^/        /'
fi
# (2) no dead grant: every Cmnd matched by at least one logged line
dead=0
i=0
while IFS= read -r cm; do
  i=$((i + 1))
  if ! awk -F'|' -v n="$i" '{k=split($3,a,","); for(j=1;j<=k;j++) if (a[j]==n) f=1} END{exit f?0:1}' "$d/sudo.log"; then
    bad "dead grant (no command line disk-health.sh sends matches it): $cm"; dead=1
  fi
done <"$d/cmnds"
[ $dead = 0 ] && pass "every Cmnd in the render is used by at least one disk-health.sh command line (no dead grant)"

# ---- the prose list is gone from disk-health.sh; it points at the code
if ! grep -q 'NOPASSWD' "$script" && grep -q 'disk-health-sudoers' "$script" && grep -q 'sudoers.tmpl' "$script"; then pass "disk-health.sh header points at disk-health-sudoers + sudoers.tmpl, no Cmnd list in prose"; else bad "disk-health.sh header still carries the sudoers list or lacks the pointer"; fi

# ---- visudo parses the render (carbon has visudo-rs; a sandbox render names sandbox paths, syntax only)
vs=$(command -v visudo || ls /usr/sbin/visudo /sbin/visudo 2>/dev/null | head -n1)
if [ -n "$vs" ]; then
  if "$vs" -cf "$d/render" >/dev/null 2>&1; then pass "visudo -cf parses the render"; else bad "visudo -cf rejects the render: $("$vs" -cf "$d/render" 2>&1 | head -n3)"; fi
else
  echo "SKIP: no visudo on this host (installer selftest uses a fake visudo)"
fi

# ---- installer selftest
if out=$("$inst" --selftest 2>&1); then pass "disk-health-sudoers --selftest ($(printf '%s\n' "$out" | tail -n1))"; else bad "disk-health-sudoers --selftest"; printf '%s\n' "$out" | grep -v '^  ok' | tail -n 20; fi

[ "$mode" = --core ] && { [ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"; exit $fail; }

# ---- mutations: each in a mktemp copy of the repo; the copy's own test (--core) must go red with the expected text
mutate() { # mutate <label> <expected red text> <sed-script-or-append> ; sets $m (copy)
  local label=$1 want=$2 how=$3 m="$d/mut.$1" before after out rc
  mkdir -p "$m"
  (cd "$root" && tar --exclude=.git -cf - .local/bin/disk-health.sh .local/bin/disk-health-sudoers .local/share/disk-health tests/disk-health-sudoers.test.sh) | tar -xf - -C "$m"
  case $how in
    sed:*) sed -i -e "${how#sed:}" "$m/.local/bin/disk-health.sh" ;;
    append:*) printf '%s\n' "${how#append:}" >>"$m/.local/share/disk-health/sudoers.tmpl" ;;
    star) sed -i -e '0,/\/dev\/sd\[a-z\]$/s//\/dev\/sd*/' "$m/.local/share/disk-health/sudoers.tmpl" ;;
  esac
  echo "  mutation $label diff vs repo:"
  diff -u "$root/.local/bin/disk-health.sh" "$m/.local/bin/disk-health.sh" | grep '^[+-][^+-]' | sed 's/^/    /'
  diff -u "$tmpl" "$m/.local/share/disk-health/sudoers.tmpl" | grep '^[+-][^+-]' | sed 's/^/    /'
  out=$(bash "$m/tests/disk-health-sudoers.test.sh" --core 2>&1); rc=$?
  if [ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q -- "$want"; then
    pass "mutation '$label' turns the test red"
    printf '%s\n' "$out" | grep -A2 '^FAIL' | head -n 8 | sed 's/^/    red: /'
  else
    bad "mutation '$label' did NOT turn the test red as expected (rc=$rc, wanted: $want)"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/    /'
  fi
}
mutate new-smartctl-flag 'sudo refused a command line disk-health.sh runs' 'sed:s/call(\["smartctl", "-H", "-A", dev\])/call(["smartctl", "-H", "-A", "-x", dev])/'
mutate extra-cmnd 'dead grant' 'append:@USER@ ALL=(root) NOPASSWD: @SMARTCTL@ -H -A -d scsi /dev/sd[a-z]'
mutate star-in-cmnd 'wildcard \* or ? in Cmnd' star

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
