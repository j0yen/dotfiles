#!/usr/bin/env bash
# tests/sudo-stdin-guard.test.sh -- .claude/hooks/sudo-stdin-guard.sh: a stdin-sudo may only validate (-v/-k/-K, or `true`); the literal wm-sudo/pass may appear only as
# the `<` redirect of such a validate-only sudo. Feeds hook JSON on stdin, asserts deny (rc 2, one reason line) vs allow (rc 0, silent). Plain bash, from the repo root:
#   bash tests/sudo-stdin-guard.test.sh
# Every command below is only a JSON string fed to the hook; nothing here runs sudo or reads a real secret. The fixture pass file is /nonexistent/fixture-pass.
# Four mutants of the hook (copied to a temp dir, sed-edited) are run through the same cases; a mutant that survives (no case reddens) is a FAIL.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${SUDO_STDIN_GUARD_UNDER_TEST:-$here/.claude/hooks/sudo-stdin-guard.sh}"
F=/nonexistent/fixture-pass
REAL='~/.config/wm-sudo/pass'
pass=0; fail=0; failed=()

# run_case <hook> <want: deny|allow> <command>  -> 0 when the hook behaves as wanted
run_case() {
  local h=$1 want=$2 cmd=$3 err rc
  err=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$h" 2>&1 >/dev/null); rc=$?
  verdict "$want" "$rc" "$err"
}
# run_raw <hook> <want> <raw stdin payload> [PATH override]  -> same check, payload fed verbatim (no jq wrapping)
run_raw() {
  local h=$1 want=$2 raw=$3 p=${4:-$PATH} err rc
  err=$(printf '%s' "$raw" | PATH=$p bash "$h" 2>&1 >/dev/null); rc=$?
  verdict "$want" "$rc" "$err"
}
verdict() {
  local want=$1 rc=$2 err=$3
  if [ "$want" = deny ]; then
    [ $rc = 2 ] && [[ "$err" == "sudo-stdin-guard: "* ]] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ]
  else
    [ $rc = 0 ] && [ -z "$err" ]
  fi
}

# the case table: "<deny|allow>|<name>|<command>" built in one array so mutants replay it
CASES=()
add() { CASES+=("$1|$2|$3"); }
add deny  deny-1  "echo x | sudo -S tee -a /etc/fstab < $F"
add deny  deny-2  "echo x | sudo -S sh"
add deny  deny-3  "sudo -S systemctl restart foo < $F"
add deny  deny-4  "sudo --stdin mount /dev/sdb1 /mnt < $F"
add deny  deny-5  "sudo -kS tee f < $F"
add deny  deny-6  "ssh redbaron 'sudo -S tee -a /etc/fstab < $F'"
add deny  deny-7  "ssh redbaron \"echo x | sudo -S sh -c 'cat >> /etc/fstab'\""
add deny  deny-8  "sudo -S -p \"\" -v < $F && sudo -S tee f < $F"
add deny  deny-9  "sudo -n tee -a /etc/fstab < $REAL"
add deny  deny-10 "cat $REAL | sudo -n sh"
add deny  deny-11 $'sudo -S \\\ntee f'
add deny  deny-12 "/usr/bin/sudo -S tee f < $F"
add deny  deny-13a "sudo -S -i < $F"
add deny  deny-13b "sudo -S -s < $F"
add deny  deny-13c "sudo -S -e /etc/fstab < $F"
add deny  deny-13d "sudo -S -l < $F"
add deny  deny-14 "sudo -S -v tee -a f < $F"
add deny  deny-15 "ssh redbaron \"sudo -S -p '' -v < $REAL && cat \\\"\$HOME/.config/wm-sudo/pass\\\" | sh\""
add deny  deny-16 "sudo -n sh -c 'sudo -S tee f < $F'"
add allow allow-1  "sudo -S -p \"\" -v < $F && sudo -n tee -a /etc/fstab"
add allow allow-2  "ssh redbaron 'sudo -S -p \"\" -v < $F && sudo -n systemctl daemon-reload'"
add allow allow-3  "sudo -S -p '' -v < $F"
add allow allow-4  "sudo -n true"
add allow allow-5  "sudo -k"
add allow allow-6  "sudo -S true < $F"
add allow allow-7  "ls /etc/sudoers.d"
add allow allow-8  "echo pseudo -S"
add allow allow-9  "ssh redbaron \"sudo -S -p '' -v < $REAL && sudo -n true\""
add allow allow-10 "sudo -Sp '' -v < $REAL"
add allow allow-11a "sudo -S -p \"\" -v < $REAL && sudo -n tee -a /etc/fstab"
add allow allow-11b "ssh redbaron 'sudo -S -p \"\" -v < $REAL && sudo -n systemctl daemon-reload'"

# raw-payload cases (fail-closed on sudo): "<deny|allow>|<name>|<raw payload>"
RAWCASES=()
addr() { RAWCASES+=("$1|$2|$3"); }
addr deny  fc-deny-1 '{not json sudo -S tee f'
addr deny  fc-deny-2 '{"tool_name":"Bash","tool_input":{"cmd":"sudo -S tee f"}}'
addr deny  fc-deny-3 '{"tool_name":"Bash","tool_input":{"command":["sudo","-S","tee","f"]}}'
addr allow fc-allow-1 '{not json ls'
addr allow fc-allow-2 ''
addr allow fc-allow-3 '{"tool_name":"Bash","tool_input":{}}'

replay() {  # replay <hook> -> prints the names of the cases that fail
  local h=$1 row want name cmd
  for row in "${RAWCASES[@]}"; do
    want=${row%%|*}; row=${row#*|}; name=${row%%|*}; cmd=${row#*|}
    run_raw "$h" "$want" "$cmd" || echo "$name"
  done
  for row in "${CASES[@]}"; do
    want=${row%%|*}; row=${row#*|}; name=${row%%|*}; cmd=${row#*|}
    run_case "$h" "$want" "$cmd" || echo "$name"
  done
}

for row in "${CASES[@]}"; do
  want=${row%%|*}; r=${row#*|}; name=${r%%|*}; cmd=${r#*|}
  if run_case "$hook" "$want" "$cmd"; then pass=$((pass+1)); echo "ok - $name ($want)"
  else fail=$((fail+1)); failed+=("$name"); echo "NOT OK - $name ($want): $cmd"; fi
done

for row in "${RAWCASES[@]}"; do
  want=${row%%|*}; r=${row#*|}; name=${r%%|*}; cmd=${r#*|}
  if run_raw "$hook" "$want" "$cmd"; then pass=$((pass+1)); echo "ok - $name ($want)"
  else fail=$((fail+1)); failed+=("$name"); echo "NOT OK - $name ($want): $cmd"; fi
done

# no python3 on PATH: a temp bin dir holds only bash + cat; the shim must deny a payload containing sudo and allow one without
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sudo-guard-mut.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/nopy"; ln -s "$(command -v bash)" "$tmp/nopy/bash"; ln -s "$(command -v cat)" "$tmp/nopy/cat"
for row in 'deny|nopy-deny|{"tool_name":"Bash","tool_input":{"command":"ls; sudo -S tee f"}}' 'allow|nopy-allow|{"tool_name":"Bash","tool_input":{"command":"ls /etc"}}'; do
  want=${row%%|*}; r=${row#*|}; name=${r%%|*}; cmd=${r#*|}
  if PATH=$tmp/nopy command -v python3 >/dev/null; then fail=$((fail+1)); failed+=("$name-python-present"); echo "NOT OK - $name: python3 still on the test PATH"; continue; fi
  if run_raw "$hook" "$want" "$cmd" "$tmp/nopy"; then pass=$((pass+1)); echo "ok - $name ($want)"
  else fail=$((fail+1)); failed+=("$name"); echo "NOT OK - $name ($want): $cmd"; fi
done

# mutants: each must redden at least one case; the list of reddened cases is printed
mutate() {  # mutate <label> <sed-expr> <expected-case-prefix>...
  local label=$1 expr=$2; shift 2
  local m="$tmp/$label.sh" red
  sed -E "$expr" "$here/.claude/hooks/sudo-stdin-guard.sh" > "$m"
  if cmp -s "$m" "$here/.claude/hooks/sudo-stdin-guard.sh"; then fail=$((fail+1)); failed+=("$label-not-applied"); echo "NOT OK - $label: sed did not change the hook"; return; fi
  red=$(replay "$m" | tr '\n' ' ')
  if [ -z "$red" ]; then fail=$((fail+1)); failed+=("$label-survived"); echo "NOT OK - $label SURVIVED (no case reddened)"; return; fi
  local want ok=1
  for want in "$@"; do [[ " $red" == *" $want "* ]] || ok=0; done
  if [ $ok = 1 ]; then pass=$((pass+1)); echo "ok - $label killed: reddens $red"
  else fail=$((fail+1)); failed+=("$label-wrong"); echo "NOT OK - $label reddens [$red], expected $*"; fi
}
mutate m1-no-quoted-scan 's/for sub in subs:  # RECURSE-LINE/for sub in []:/' deny-6 deny-7
mutate m2-any-v-is-safe 's/^( *)safe = .*# SAFE-LINE/\1safe = "v" in acts/' deny-14
mutate m3-no-rule2 's/bad = True  # RULE2-LINE/pass/' deny-9 deny-10
mutate m4-fail-open '/FAILCLOSED-LINE/s/"sudo" in raw/False/g' fc-deny-1 fc-deny-2 fc-deny-3

echo "PASS $pass / FAIL $fail"
[ $fail = 0 ] || { printf 'failed: %s\n' "${failed[*]}"; exit 1; }
exit 0
