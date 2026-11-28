#!/usr/bin/env bash
# tests/hermetic_sqlite3.sh — source me from a test that builds a sqlite fixture with the `sqlite3` CLI.
# A host whose PATH `sqlite3` cannot CREATE a database (ryzen7: ~/.local/bin/sqlite3 is a read-only python
# wrapper, `connect(...?mode=ro)`) made every fixture build fail with "unable to open database file".
# This probes the PATH sqlite3 once; if it cannot create a db it puts a read-write python3 stand-in first on
# PATH (exported, so the scripts under test and child test files use it too). A host whose sqlite3 works is
# untouched. No python3 and no working sqlite3 -> FAIL loudly (exit 2), never a skip.
_hs_probe="$(mktemp -d "${TMPDIR:-/tmp}/hs3probe.XXXXXX")" || { echo "FAIL: hermetic_sqlite3: no temp dir" >&2; exit 2; }
if ! sqlite3 "$_hs_probe/p.db" "create table t(x); insert into t values (1);" >/dev/null 2>&1 \
   || [ "$(sqlite3 "$_hs_probe/p.db" 'select x from t' 2>/dev/null)" != 1 ]; then
  command -v python3 >/dev/null 2>&1 || { echo "FAIL: hermetic_sqlite3: PATH sqlite3 cannot create a db and python3 is absent" >&2; rm -rf "$_hs_probe"; exit 2; }
  _hs_dir="${TMPDIR:-/tmp}/hermetic-sqlite3.$(id -u)"
  mkdir -p "$_hs_dir" && cat > "$_hs_dir/sqlite3.$$" <<'PY'
#!/usr/bin/env -S python3 -I -S
# -I -S: no site import, ~half the startup reads (ocard_ac02 counts every child's read bytes)
# read-write stand-in for the sqlite3 CLI: [-readonly] [-json] [-separator S] [-noheader] [-bail] DB [SQL...] (SQL may come on stdin)
import sqlite3, sys
args, sep, ro, js, i = sys.argv[1:], "|", False, False, 0
rest = []
while i < len(args):
    a = args[i]
    if a == "-readonly": ro = True
    elif a == "-json": js = True
    elif a == "-separator": sep = args[i + 1]; i += 1
    elif a in ("-noheader", "-bail", "-batch"): pass
    elif a.startswith("-") and len(a) > 1 and a[1].isalpha(): sys.exit("sqlite3 stand-in: flag not implemented: " + a)
    else: rest.append(a)
    i += 1
if not rest: sys.exit("sqlite3 stand-in: no database argument")
db, sql = rest[0], " ".join(rest[1:]) if len(rest) > 1 else sys.stdin.read()
for ln in sql.splitlines():
    if ln.lstrip().startswith("."): sys.exit("sqlite3 stand-in: dot-commands unsupported: " + ln.split()[0])
try:
    c = sqlite3.connect("file:%s?mode=%s" % (db, "ro" if ro else "rwc"), uri=True, timeout=5)
    buf, jrows = "", []
    def run(stmt):
        cur = c.execute(stmt)
        if js: import json
        for r in cur.fetchall():
            if js: jrows.append(json.dumps({d[0]: v for d, v in zip(cur.description, r)}, separators=(",", ":")))
            else: print(sep.join("" if v is None else str(v) for v in r))
    for ch in sql:
        buf += ch
        if ch == ";" and sqlite3.complete_statement(buf):
            run(buf); buf = ""
    if buf.strip(): run(buf)
    if jrows: print("[" + ",\n".join(jrows) + "]")
    c.commit(); c.close()
except sqlite3.Error as e:
    sys.exit("Error: " + str(e))
PY
  chmod +x "$_hs_dir/sqlite3.$$" && mv -f "$_hs_dir/sqlite3.$$" "$_hs_dir/sqlite3" || { echo "FAIL: hermetic_sqlite3: cannot install the stand-in" >&2; rm -rf "$_hs_probe"; exit 2; }
  export PATH="$_hs_dir:$PATH"
  echo "hermetic_sqlite3: active $_hs_dir/sqlite3 (PATH sqlite3 cannot create a db)" >&2
  sqlite3 "$_hs_probe/q.db" "create table t(x); insert into t values (1);" >/dev/null 2>&1 \
    && [ "$(sqlite3 "$_hs_probe/q.db" 'select x from t' 2>/dev/null)" = 1 ] \
    || { echo "FAIL: hermetic_sqlite3: stand-in cannot create a db either" >&2; rm -rf "$_hs_probe"; exit 2; }
fi
rm -rf "$_hs_probe"; unset _hs_probe _hs_dir
