#!/bin/bash
# session-read.sh <orch session jsonl path>...: the ONLY way r7 reads truth-tier session logs (guarded by session-jsonl-read-guard.sh).
# Prints a fixed set of keys per event; never args/response/text/claim/key fields (r7 correction 10-23 11:5x: a raw grep printed a
# claim-URL prefix from a signup response).
#   session-read.sh <path>            filtered events (KEEP keys only)
#   session-read.sh --counts <path>...  per file: event-type / tool / top-level key-set shape counts, never values
#   session-read.sh --selftest        a line carrying a claim_url and key never prints them (both modes)
filt='import json,sys
KEEP=("type","t","turn","role","tool","kind","ms","allowed_tools_count","allowed_tools_source","anon","error_kind")
for l in sys.stdin:
  try: x=json.loads(l)
  except Exception: continue
  out={k:x[k] for k in KEEP if k in x}
  e=x.get("error")
  if isinstance(e,str): out["error"]=e[:80].split("http")[0]
  print(json.dumps(out))'
# --counts program: argv[1] = file label. Only enum-looking type/tool values are echoed; anything else counts as "<other>".
cnt='import json,sys,re,collections
ok=re.compile(r"^[A-Za-z0-9_.:-]{1,48}$")
def enum(v): return v if isinstance(v,str) and ok.match(v) else "<other>"
n=bad=0; ty=collections.Counter(); tl=collections.Counter(); sh=collections.Counter()
for l in sys.stdin:
  try: x=json.loads(l)
  except Exception: bad+=1; continue
  if not isinstance(x,dict): bad+=1; continue
  n+=1
  if "type" in x: ty[enum(x["type"])]+=1
  if "tool" in x: tl[enum(x["tool"])]+=1
  sh[",".join(sorted(enum(k) for k in x))]+=1
print(json.dumps({"file":sys.argv[1].split("/")[-1][:48],"events":n,"unparsed":bad,"type":dict(ty),"tool":dict(tl),"shapes":dict(sh)}))'
if [ "$1" = --selftest ]; then
  line='{"type":"call","tool":"signup","response":"{\"claim_url\": \"https://x/claim/abc\"}","args":{"key":"sk-1"},"error":"boom https://x/claim/abc"}'
  r=$(echo "$line" | python3 -c "$filt"); echo "$r" | grep -qE 'claim|sk-1|https' && { echo "SELFTEST FAIL (filter)"; exit 1; }
  c=$(printf '%s\nnot json\n{"type":"https://x/claim/abc","tool":"sk-1 secret"}\n' "$line" | python3 -c "$cnt" /x/s.jsonl)
  echo "$c" | grep -qE 'claim|sk-1|https|secret' && { echo "SELFTEST FAIL (counts leak)"; exit 1; }
  echo "$c" | grep -q '"events": 2' && echo "$c" | grep -q '"unparsed": 1' && echo "$c" | grep -q '"signup": 1' || { echo "SELFTEST FAIL (counts shape)"; exit 1; }
  echo "SELFTEST OK"; exit 0
fi
mode=filt; [ "$1" = --counts ] && { mode=cnt; shift; }
[ $# -ge 1 ] || { echo "usage: session-read.sh [--counts] <path>... | --selftest" >&2; exit 64; }
for p in "$@"; do
  case $p in *\'*) echo "session-read.sh: refusing path with a quote" >&2; exit 64;; esac
  if [ $mode = cnt ]; then ssh -o ConnectTimeout=15 orch "cat '$p'" | python3 -c "$cnt" "$p"
  else ssh -o ConnectTimeout=15 orch "cat '$p'" | python3 -c "$filt"; fi
done
