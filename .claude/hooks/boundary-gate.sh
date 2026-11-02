#!/usr/bin/env bash
# boundary-gate.sh <PreToolUse|Stop>: evaluates the classifier rules of gen/boundary-rules.json
# whose hook is this file. PreToolUse prints a deny JSON, Stop prints a block JSON; allow = no output.
# Rules scoped by when_env apply only when that env var is non-empty. Allows on any error.
# Env: BOUNDARY_RULES (table path). A237, L4.
set -u
event="${1:-}"
here=$(cd "$(dirname "$0")/../.." && pwd)
export BOUNDARY_RULES="${BOUNDARY_RULES:-$here/gen/boundary-rules.json}"
[ -r "$BOUNDARY_RULES" ] || exit 0
BG_EVENT="$event" python3 -I -c '
import json, os, re, sys
try:
    ev = os.environ["BG_EVENT"]
    d = json.load(sys.stdin)
    rules = json.load(open(os.environ["BOUNDARY_RULES"]))["rules"]
    if ev == "Stop" and d.get("stop_hook_active"):
        sys.exit(0)
    for r in rules:
        if r.get("status") != "installed" or r.get("event") != ev or not r.get("hook", "").endswith("boundary-gate.sh"):
            continue
        if r.get("when_env") and not os.environ.get(r["when_env"]):
            continue
        why = "boundary-gate: %s: %s" % (r["id"], r.get("reason", "refused"))
        if ev == "PreToolUse":
            if re.search(r.get("tool", "^$"), d.get("tool_name", "")):
                print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": why}}))
                sys.exit(0)
        elif ev == "Stop":
            msg = d.get("last_assistant_message") or ""
            if re.search(r["pattern"], msg, re.I) and not (r.get("unless_pattern") and re.search(r["unless_pattern"], msg)):
                print(json.dumps({"decision": "block", "reason": why}))
                sys.exit(0)
except SystemExit:
    raise
except Exception:
    pass
'
exit 0
