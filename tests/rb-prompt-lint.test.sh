#!/usr/bin/env bash
# rb-prompt-lint.test.sh - rb_prompt_pair_lint (.local/lib/rb-prompt-lint.sh): a `wm-decide record` with --target AND --pr is refused.
# Hermetic: every fixture lives under a mktemp -d root this test created; sources the lib directly; no ssh, no claude.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../.local/lib/rb-prompt-lint.sh"
R=$(mktemp -d "${TMPDIR:-/tmp}/rb-prompt-lint-test.XXXXXX") || exit 2
trap 'case "$R" in */rb-prompt-lint-test.*) rm -rf "$R";; esac' EXIT
n=0; fail=0; groups=""   # n = number of lettered case groups a..h (sub-cases b-*, c2-* count under their letter)
# t NAME WANT_RC WANT_STDERR_SUBSTRING(or "") : fixture text arrives on stdin
t() {
  local name=$1 want=$2 sub=$3 f="$R/$1.prompt" err rc
  cat > "$f"
  err=$(rb_prompt_pair_lint "$f" 2>&1 >/dev/null); rc=$?
  case $groups in *"${name:0:1}"*) ;; *) groups+=${name:0:1}; n=$((n + 1));; esac
  if [ "$rc" = "$want" ] && { [ -z "$sub" ] || [[ $err == *"$sub"* ]]; }; then echo "PASS: ($name) rc=$rc ${err:+msg='$err'}"
  else echo "FAIL: ($name) rc=$rc want=$want msg='$err' want-msg='$sub'"; fail=1; fi
}
MSG='--target with --pr (wm-decide refuses the pair; drop --target)'
t a-one-line 1 "line 1: $MSG" <<'X'
wm-decide record --agent rb --kind verdict --target redbaron --pr 'wm-build#347' --what "x"
X
t b-continuation 1 "line 3: $MSG" < <(printf 'intro\n\nwm-decide record --agent rb \\\n  --target redbaron \\\n  --pr x\n')
t b-trailing-space-tab 1 "line 1: $MSG" < <(printf 'wm-decide record --agent rb \\ \n  --target redbaron \\\t\n  --pr x\n')
t b-crlf 1 "line 2: $MSG" < <(printf 'x\r\nwm-decide record --agent rb \\\r\n  --target redbaron \\\r\n  --pr x\r\n')
t b-wmd-var 1 "line 1: $MSG" < <(printf '"$WMD" record --agent rb --target redbaron --pr x\n')
t c-pr-only 0 "" < <(printf 'wm-decide record --agent rb --pr x --what "y"\n')
t d-target-only 0 "" < <(printf 'wm-decide record --agent rb --target redbaron --what "y"\n')
t e-different-commands 0 "" < <(printf 'wm-decide record --agent rb --target redbaron --what y\nwm-decide record --agent rb --pr x --what y\n')
# f: the real v347r.prompt line (verbatim copy of ~/.cache/rb-seat/coders/v347r.prompt:15, the line wm-decide refused)
t f-real-v347r-line 1 "line 1: $MSG" <<'X'
  wm-decide record --agent rb --via verifier --model sonnet --kind verdict --gates d-20261023-083017-rb-e5cb --attach $d/<L1> --attach $d/<L2> --attach $d/<L3> --target redbaron --pr 'wm-build#347' --what "MERGE-OK j0yen/wm-build#347 COMMIT=b4fea1a8d289684724c6f46e34ad042c04ceb6bb agent=verifier:rb-verifier-347r recorded_by=unit:rb-coder-v347r (L1 squash_guard, L2 -D warnings, L3 clippy delta=0; suite head-only resolved alone)" --evidence "<STEP 1 counts + STEP 2 alone results, verbatim lines>"
X
t g-other-subcommand 0 "" < <(printf 'wm-decide show --target redbaron --pr x\nwm-decide list --pr x --target redbaron\n')
t h-comment 0 "" < <(printf '# wm-decide record --target redbaron --pr x\n   # wm-decide record --target redbaron --pr x\n')
t c2-whole-token-only 0 "" < <(printf 'wm-decide record --pr-url x --targets y --what "--prefix --target-host"\n')
t b-equals-form 1 "line 1: $MSG" < <(printf 'wm-decide record --target=redbaron --pr=x\n')
[ "$fail" = 0 ] && echo "PASS rb-prompt-lint n=$n" || { echo "FAIL rb-prompt-lint n=$n"; exit 1; }
