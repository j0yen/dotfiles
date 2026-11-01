#!/bin/bash
# HARD RULE (Joe 2026-10-11 11:4x am PDT): no non-permanent Hetzner boxes. Deletes any server not in the fixed fleet.
# `--selftest` is hermetic: no token read, no API call, no delete; it only exercises the decision function below.
set -u
ALLOW="hub orch mcphost-1"

# The keep/delete decision, shared by the live run and --selftest: exact-name match against the allow list.
# An empty server list yields an empty delete list (fail closed).
read -r -d '' PYDECIDE <<'PY'
def extra_servers(servers, allow):
    return [s for s in servers if s["name"] not in allow]
PY

if [ "${1:-}" = "--selftest" ]; then
  ALLOW="$ALLOW" PYDECIDE="$PYDECIDE" python3 -I -c '
import os,sys
exec(os.environ["PYDECIDE"])
allow=set(os.environ["ALLOW"].split())
def run(names): return [s["name"] for s in extra_servers([{"name":n} for n in names], allow)]
cases=[
 ("a hub,orch,mcphost-1 deletes nothing", ["hub","orch","mcphost-1"], []),
 ("b plus box-123 deletes exactly box-123", ["hub","orch","mcphost-1","box-123"], ["box-123"]),
 ("c empty list deletes nothing (fail closed)", [], []),
 ("d substring names orch-2,xhub are deleted (exact match only)", ["hub","orch-2","xhub"], ["orch-2","xhub"]),
]
bad=0
for label,names,want in cases:
    got=run(names); ok=(got==want); bad+=0 if ok else 1
    print("%s %s (got=%s)" % ("PASS" if ok else "FAIL", label, ",".join(got) or "-"))
sys.exit(1 if bad else 0)
'
  exit $?
fi

export ALLOW
export T=$(cat "$HOME/.config/hetzner-guard/token") || exit 2
export PYDECIDE
LOG="$HOME/.local/state/hetzner-guard.log"; mkdir -p "$(dirname "$LOG")"
json=$(curl -s --max-time 30 -H "Authorization: Bearer $T" 'https://api.hetzner.cloud/v1/servers?per_page=50') || { echo "$(date -Is) list failed" >> "$LOG"; exit 1; }
printf '%s' "$json" | python3 -I -c '
import json,sys,os,subprocess
exec(os.environ["PYDECIDE"])
allow=set(os.environ["ALLOW"].split()); d=json.load(sys.stdin); t=os.environ["T"]
names=[s["name"] for s in d["servers"]]
extra=extra_servers(d["servers"], allow)
print("ok servers=%s" % ",".join(names))
for s in extra:
    code=subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}","-X","DELETE","-H","Authorization: Bearer "+t,"https://api.hetzner.cloud/v1/servers/%d"%s["id"]],capture_output=True,text=True).stdout
    print("DELETED non-fleet server %s (%s) -> %s" % (s["name"], s["server_type"]["name"], code))
' | while read -r line; do echo "$(date -Is) $line"; done | tee -a "$LOG"
