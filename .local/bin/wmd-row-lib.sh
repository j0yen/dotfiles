# wmd-row-lib.sh -- sourced by rb-merge.sh and fd-merge.sh: ONE reader of wm-decide verdict/gated rows.
#   wmd_fetch <wm-decide-bin>   runs `<bin> list --json` ONCE into WMD_LIST; returns 3 (one-line reason on stderr) if the call fails or the output is not a JSON list
#   wmd_pick <row-id>           prints the row object (compact JSON) with that exact id; returns 3 if the id is absent or appears more than once (never first-wins)
#   wmd_field <row-json> <name> prints a field as a string ("" if missing/null)
# There is no `show` verb or id filter in wm-decide, so the whole list is fetched and filtered here. Every failure is CLOSED (3).
wmd_fetch() {
  WMD_LIST="$("$1" list --json 2>/dev/null)" || { echo "wm-decide list --json failed" >&2; return 3; }
  printf '%s' "$WMD_LIST" | python3 -I -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, list) else 1)' || { echo "wm-decide list --json output is not a JSON list" >&2; return 3; }
}
wmd_pick() {
  printf '%s' "$WMD_LIST" | python3 -I -c 'import json,sys
rows = [r for r in json.load(sys.stdin) if isinstance(r, dict) and r.get("id") == sys.argv[1]]
if len(rows) != 1:
    sys.stderr.write("row %s %s\n" % (sys.argv[1], "not found" if not rows else "appears %d times" % len(rows)))
    sys.exit(3)
print(json.dumps(rows[0]))' "$1"
}
wmd_field() {
  printf '%s' "$1" | python3 -I -c 'import json,sys
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else v)' "$2"
}
