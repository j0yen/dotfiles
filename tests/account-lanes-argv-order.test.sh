#!/usr/bin/env bash
# Launcher option placement: options the launcher injects (--session-id, --effort, managed --model) must appear BEFORE the caller's first bare `--`;
# everything from that separator on is the caller's opaque payload, byte-exact, never parsed by the launcher (so an option-looking prompt token
# like --model/--resume/--effort/--session-id cannot change account, session, effort or pins). A fake child records its argv; this proves only what
# the launcher hands the child, not how the native CLI parses it. Temp HOME/state, dummy credentials; no provider call. AL_ROOT=<tree> replays.
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
export SKILL_ROUTE_POLICY="$D/.config/skill-routing/policy.json" SKILL_ROUTE_LEDGER_IDS="$T/ids.txt"; printf 'A1300\n' > "$T/ids.txt"
p=0; f=0; ck(){ if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
run(){ rm -f "$T/argv.bin"; "$L" "$@" >"$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
rc(){ cat "$T/rc"; }
# py <expr over list a>: evaluate a python predicate on the recorded argv
py(){ python3 -c 'import sys;d=open(sys.argv[1],"rb").read();a=[x.decode("utf-8","surrogateescape") for x in d.split(b"\0")] if d else []
i=a.index("--") if "--" in a else len(a)
h,t=a[:i],a[i:]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$T/argv.bin" "$1"; }
UU='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
S1=11111111-2222-3333-4444-555555555551; S2=11111111-2222-3333-4444-555555555552
NF="--model claude-sonnet-5-5"

echo "== fresh launch: injected --session-id before the caller's separator, payload byte-exact"
rm -rf "$T/lanes"; run -p $NF --disallowedTools Bash Edit -- "do it"
ck "fresh: --session-id <uuid> is in the head, tail is exactly ['--','do it']" 'py "h[-2]==\"--session-id\" and __import__(\"re\").fullmatch(\"'"$UU"'\",h[-1]) and t==[\"--\",\"do it\"]"'
ck "fresh: --disallowedTools Bash Edit stay in the head, before the injected option" 'py "h[h.index(\"--disallowedTools\"):h.index(\"--disallowedTools\")+3]==[\"--disallowedTools\",\"Bash\",\"Edit\"]"'
rm -rf "$T/lanes"; run -p $NF --effort medium --disallowedTools Bash -- "x"
ck "caller --effort medium: injected --effort medium is in the head before the separator" 'py "h[-2:]==[\"--effort\",\"medium\"] and t==[\"--\",\"x\"]"'
rm -rf "$T/lanes"; run -p --model claude-fable-5-1 -- "x"
ck "fable default effort high is injected before the separator" 'py "h[-2:]==[\"--effort\",\"high\"] and \"--session-id\" in h and t==[\"--\",\"x\"]"'

echo "== opaque payload: option-looking, empty and whitespace tokens after the separator are never parsed"
rm -rf "$T/lanes"; run -p $NF -- "" " " "--model" "claude-opus-5-5" "--effort" "max" "--resume" "$S1" "--session-id" "$S2" "--route-request" "/x" "-p" "--output-format" "xml" "--" "--"
ck "launcher accepted the run (rc 0): tokens after '--' did not trigger duplicate/format/resume refusals" '[ "$(rc)" = 0 ]'
ck "tail is byte-exact incl. empty, space, option-like tokens and later separators" 'py "t==[\"--\",\"\",\" \",\"--model\",\"claude-opus-5-5\",\"--effort\",\"max\",\"--resume\",\"'$S1'\",\"--session-id\",\"'$S2'\",\"--route-request\",\"/x\",\"-p\",\"--output-format\",\"xml\",\"--\",\"--\"]"'
ck "the account/model stay those of the head (sonnet -> josephsyen), not the payload's opus" 'grep -q "account=josephsyen model=claude-sonnet-5-5" $T/err'
ck "payload --session-id/--resume did not become the session: a fresh uuid was injected in the head" 'py "h[-2]==\"--session-id\" and h[-1] not in (\"'$S1'\",\"'$S2'\")"'
rm -rf "$T/lanes"; run -p $NF -- "--effort" "high"
ck "payload '--effort high' is not parsed as effort: nothing is injected as effort" 'py "\"--effort\" not in h and t==[\"--\",\"--effort\",\"high\"]"'
rm -rf "$T/lanes"; run -p $NF -- "a" -- "b" -- "c"
ck "multiple later separators preserved" 'py "t==[\"--\",\"a\",\"--\",\"b\",\"--\",\"c\"]"'

echo "== explicit session id / resume / pins / unknown effect with a separator"
rm -rf "$T/lanes"; run -p $NF --session-id $S1 -- "x"
ck "explicit --session-id kept once in the head (no second injected), session mapped" 'py "h.count(\"--session-id\")==1 and h[h.index(\"--session-id\")+1]==\"'$S1'\" and t==[\"--\",\"x\"]" && jq -e --arg s $S1 ".sessions[\$s].account==\"josephsyen\"" $T/lanes/sessions.json >/dev/null'
run -p $NF --session-id=$S2 -- "x"
ck "explicit --session-id=<id> kept in the head, none injected" 'py "\"--session-id=\" + \"'$S2'\" in h and \"--session-id\" not in h and t==[\"--\",\"x\"]"'
run -p $NF --session-id $S1 -- "x"; ck "reusing a mapped id as fresh is still refused (session_exists)" '[ "$(rc)" != 0 ] && [ ! -e $T/argv.bin ]'
python3 -I "$P" session-mark-unknown --session $S1 --by test --reason "argv order test marks unknown" >/dev/null 2>&1
run -p $NF --resume $S1 -- "x"; ck "resume of an unknown-effect session still needs the ack (77), nothing started" '[ "$(rc)" = 77 ] && [ ! -e $T/argv.bin ]'
python3 - "$T/lanes/sessions.json" "$S1" <<'PY'
import json,sys
p,s=sys.argv[1:]; d=json.load(open(p)); d["sessions"][s].update(state="clean", unknown_effect=False, claim=None); json.dump(d,open(p,"w"))
PY
run -p $NF --resume $S1 -- "x"; ck "clean mapped resume: --resume <id> in the head, pinned to josephsyen, tail exact" '[ "$(rc)" = 0 ] && py "h[h.index(\"--resume\")+1]==\"'$S1'\" and \"--session-id\" not in h and t==[\"--\",\"x\"]" && grep -q "account=josephsyen" $T/err'
run -p $NF -- "--resume" "$S2"; ck "payload --resume does not make a resume: fresh launch (injected --session-id), no resume in head" 'py "\"--resume\" not in h and \"--session-id\" in h"'
run -p --model claude-sonnet-5-5 --model claude-opus-5-5 -- x; ck "duplicate --model in the head still refused (64)" '[ "$(rc)" = 64 ] && [ ! -e $T/argv.bin ]'
run -p $NF --effort low --effort high -- x; ck "duplicate --effort in the head still refused (64)" '[ "$(rc)" = 64 ]'
run -p $NF --continue -- x; ck "--continue in the head still refused (64)" '[ "$(rc)" = 64 ]'
run -p $NF -- --continue; ck "'--continue' after the separator is payload, not refused" '[ "$(rc)" = 0 ] && py "t==[\"--\",\"--continue\"]"'

echo "== managed route (--route-request): injected model/effort before the separator, payload opaque"
printf '{"task_id":"B1","skill":"wwhtbt"}' > "$T/req.json"; rm -rf "$T/lanes"
run --route-request "$T/req.json" -p -- "prompt" "--model" "claude-fable-5-1"
ck "managed: --model claude-sonnet-5-5 --effort medium and --session-id in the head, tail exact (payload --model not stripped nor parsed)" 'py "h[h.index(\"--model\")+1]==\"claude-sonnet-5-5\" and h[-2:]==[\"--effort\",\"medium\"] and \"--session-id\" in h and t==[\"--\",\"prompt\",\"--model\",\"claude-fable-5-1\"]" && grep -q "acct\|account=josephsyen" $T/err'
ck "managed: exactly one --model in the head" 'py "h.count(\"--model\")==1"'

echo "== no separator: unchanged placement (injected options appended after the caller's args)"
rm -rf "$T/lanes"; run -p $NF "hello"
ck "no separator: caller args first, injected --session-id last (as before)" 'py "t==[] and h[:4]==[\"-p\",\"--model\",\"claude-sonnet-5-5\",\"hello\"] and h[-2]==\"--session-id\""'

echo "== isolation"
ck "no live HOME state written" '[ "$(ls -la "$REALSTATE" 2>&1 | md5sum)" = "$before_real" ]'
echo "pass=$p fail=$f"; [ $f = 0 ] && echo ALL PASS
