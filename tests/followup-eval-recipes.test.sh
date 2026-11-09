#!/usr/bin/env bash
# A1346 recipe contract: every wm-asks command the evaluator advises uses the real verb (`wm-asks asks claim|query|update`), and alive() ignores
# its own ancestor shells (pgrep -f matches any argv, including the caller's own command line that names the token).
set -u
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ev="$here/.local/bin/followup-eval.py"
p=0; f=0; ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1 (got [$2] want [$3])"; fi; }
bad(){ grep -cE 'wm-asks (claim|query|update|add|accept|resolve|events)\b' "$1"; }
ck "evaluator advises no bare wm-asks verb" "$(bad "$ev")" 0
ck "evaluator advises wm-asks asks claim" "$([ "$(grep -c 'wm-asks asks claim' "$ev")" -ge 4 ] && echo yes || echo no)" yes
ck "followup-lib comment names the real query verb" "$(grep -c 'wm-asks query' "$here/.claude/hooks/followup-lib.sh")" 0
# negative control: the pre-fix evaluator (git) fails the same check
old="$(mktemp)"; if git -C "$here" show d7e50ec:.local/bin/followup-eval.py >"$old" 2>/dev/null; then ck "pre-fix evaluator d7e50ec is caught" "$([ "$(bad "$old")" -ge 3 ] && echo caught || echo missed)" caught; else echo "SKIP pre-fix control (no git history)"; fi; rm -f "$old"
# alive(): a runtime-random token that appears ONLY in an ancestor shell's command line is not a live worker
tok="zq$RANDOM$RANDOM$$"
got="$(bash -c "python3 -I -c \"import importlib.util as u,sys; s=u.spec_from_file_location('fe','$ev'); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.alive('seat:$tok'))\" # $tok")"
ck "alive ignores an ancestor shell naming the token" "$got" False
# a real unrelated process carrying the token is live
bash -c "exec -a sleeper-$tok sleep 20" & sp=$!
got2="$(python3 -I -c "import importlib.util as u; s=u.spec_from_file_location('fe','$ev'); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.alive('seat:sleeper-$tok'))")"
kill $sp 2>/dev/null; wait $sp 2>/dev/null
ck "alive still sees a real process carrying the token" "$got2" True
echo "followup-eval-recipes: $p PASS $f FAIL"; [ "$f" = 0 ]
