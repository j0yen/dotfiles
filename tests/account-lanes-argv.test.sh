#!/usr/bin/env bash
# Argv boundary of the supervisor: `account-lane.py run ... -- <cmd...>` must remove ONLY the supervisor's own leading separator; every later
# literal `--` (variadic --disallowedTools ... -- "<prompt>"), whitespace, empty and option-like values reach the child unchanged. Real fake child
# records its argv byte-exactly (NUL separated). Temp HOME/state, dummy credentials; no provider call. AL_ROOT=<tree> replays other bytes.
set -u
D="${AL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"; L="$D/.local/bin/fable-launch.sh"; P="$D/.local/lib/account-lane.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALSTATE="$HOME/.local/state/account-lanes"; before_real="$(ls -la "$REALSTATE" 2>&1 | md5sum)"
mkdir -p "$T/store" "$T/home"; for a in josephsyen:JOSEPH jyen.tech:TECH jyen.pm:PM mcphost.dev:MCP; do printf 'TOKEN-%s-dummy0000' "${a#*:}" > "$T/store/${a%%:*}"; done
cat > "$T/child" <<'S'
#!/usr/bin/env python3
import os, sys
open(os.environ["ARGVLOG"], "wb").write(b"\0".join(a.encode("utf-8", "surrogateescape") for a in sys.argv[1:]))
S
chmod +x "$T/child"
export HOME="$T/home" ACCOUNT_LANE_STATE="$T/lanes" ACCOUNT_LANE_POLICY="$D/tests/fixtures/account-lanes/policy.test.json" ACCOUNT_LANE_TEST=1 ACCOUNT_LANE_NOW=1800000000
export FABLE_LAUNCH_TEST=1 FABLE_TOKEN_STORE="$T/store" FABLE_CLAUDE_BIN="$T/child" ARGVLOG="$T/argv.bin" SKILL_ROUTING_DECISIONS="$T/dec.jsonl"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
argv(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read();print(repr([x.decode("utf-8","surrogateescape") for x in d.split(b"\0")] if d else []))' "$T/argv.bin"; }
want(){ python3 -c 'import sys,json;print(repr(json.loads(sys.argv[1])))' "$1"; }
sup(){ rm -f "$T/argv.bin"; rm -rf "$T/lanes"; python3 -I "$P" run --output-format text --account josephsyen --lane nonfable --session "" "$@" >/dev/null 2>&1; echo $? > "$T/rc"; }
CH="$T/child"

echo "== supervisor: exactly the leading separator is removed"
sup -- "$CH" a -- b -- c;                       ck "later literal '--' preserved (a -- b -- c)" '[ "$(argv)" = "$(want "[\"a\",\"--\",\"b\",\"--\",\"c\"]")" ]'
sup -- "$CH" --disallowedTools Bash Edit -- "do the thing"; ck "variadic --disallowedTools ... -- <prompt> keeps its separator" '[ "$(argv)" = "$(want "[\"--disallowedTools\",\"Bash\",\"Edit\",\"--\",\"do the thing\"]")" ]'
sup -- "$CH" -- --;                             ck "child's own '--' args kept after the supervisor separator" '[ "$(argv)" = "$(want "[\"--\",\"--\"]")" ]'
sup -- "$CH" "" " " "  lead and trail  " "-x" "--flag=--" $'a\nb' "--";  ck "empty, whitespace, option-like and trailing '--' values byte-exact" '[ "$(argv)" = "$(want "[\"\",\" \",\"  lead and trail  \",\"-x\",\"--flag=--\",\"a\\nb\",\"--\"]")" ]'
sup -- "$CH";                                   ck "child with no args runs with empty argv" '[ "$(cat $T/rc)" = 0 ] && [ "$(argv)" = "[]" ]'
sup "$CH" a -- b;                               ck "no leading separator: nothing removed, later '--' preserved" '[ "$(argv)" = "$(want "[\"a\",\"--\",\"b\"]")" ]'
sup;                                            ck "no command at all is still refused" '[ "$(cat $T/rc)" != 0 ] && [ ! -e $T/argv.bin ]'

echo "== through the launcher (headless supervisor path)"
has(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read().split(b"\0");w=[x.encode() for x in sys.argv[2:]];sys.exit(0 if any(d[k:k+len(w)]==w for k in range(len(d)-len(w)+1)) else 1)' "$T/argv.bin" "$@"; }
ends(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read().split(b"\0");w=[x.encode() for x in sys.argv[2:]];sys.exit(0 if d[-len(w):]==w else 1)' "$T/argv.bin" "$@"; }
rm -rf "$T/lanes"; "$L" -p --model claude-sonnet-5-5 --disallowedTools Bash Edit -- "final prompt -- with dashes" >/dev/null 2>&1
ck "launcher: variadic --disallowedTools ... then the separator and prompt are the exact tail (injected options precede it: see account-lanes-argv-order)" 'has --disallowedTools Bash Edit && ends -- "final prompt -- with dashes"'
rm -rf "$T/lanes"; "$L" -p "" --model claude-sonnet-5-5 -- "x" >/dev/null 2>&1
ck "launcher: empty print prompt kept and the later separator + payload are the exact tail" 'has -p "" --model claude-sonnet-5-5 && ends -- x'

echo "== lane policy / unknown-effect untouched by the fix"
rm -rf "$T/lanes"; "$L" --model claude-sonnet-5-5 -p x >/dev/null 2>&1; S=cccccccc-2222-3333-4444-555555555555
"$L" --model claude-sonnet-5-5 --resume $S -p x >/dev/null 2>&1; ck "unmapped resume still blocks (75)" '[ $? = 75 ]'
echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
