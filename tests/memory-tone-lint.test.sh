#!/usr/bin/env bash
# memory-tone-lint: 1 tier-1 + 1 tier-2 + allowlisted + code-fenced -> exactly 2 hits; empty tree -> exit 0.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
L=$HERE/.local/bin/memory-tone-lint.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; ok(){ [ "$2" = "$3" ] && echo "ok $1" || { echo "FAIL $1: got '$3' want '$2'"; fail=1; }; }
export TONE_LINT_OUT=$T/out.json
H=$T/empty; mkdir -p $H/.claude/projects/p/memory; : > $H/.claude/projects/p/memory/a.md
TONE_LINT_HOME=$H "$L" >/dev/null; ok empty-exit0 0 $?
H=$T/h; mkdir -p $H/.claude/projects/p/memory $H/Notes/wiki
cat > $H/.claude/projects/p/memory/a.md <<'F'
this was a stupid mistake
NEVER DELAY the batch
use a lazy import here
STOP WRITING: label form
```
class: seared
NEVER SKIP inside a fence
```
a neutral line: trap, defect, failed
F
cp $H/.claude/projects/p/memory/a.md $H/Notes/wiki/b.md
n=$(TONE_LINT_HOME=$H "$L" | grep -c ':'); ok two-hits-per-file 4 "$n"
TONE_LINT_HOME=$H "$L" >/dev/null; ok exit1 1 $?
j=$(TONE_LINT_HOME=$H "$L" --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["count"],sorted({h["tier"] for h in d["hits"]}))')
ok json "4 [1, 2]" "$j"
ok cache 4 "$(python3 -c "import json;print(json.load(open('$TONE_LINT_OUT'))['hits'])")"
ok usage 64 "$("$L" --bogus 2>/dev/null; echo $?)"
exit $fail
