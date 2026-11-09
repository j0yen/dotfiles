#!/usr/bin/env bash
# A1296 W3: old path (plain cp from a 0664 source) leaves a hook that fails direct exec; adopt-exec-file.sh gives a direct-exec-able hook, keeps a backup, and refuses a non-executable mode.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; A="$here/.local/bin/adopt-exec-file.sh"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT; p=0; f=0
ck() { if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
printf '#!/usr/bin/env bash\necho hook-ran\n' > "$d/src.sh"; chmod 664 "$d/src.sh"
cp "$d/src.sh" "$d/old.sh"
ck "old install path: direct exec fails (RED reproduction)" '! "$d/old.sh" >/dev/null 2>&1'
echo old > "$d/dest.sh"; chmod 640 "$d/dest.sh"
out="$("$A" "$d/src.sh" "$d/dest.sh" 2>&1)"; rc=$?
ck "adopt rc 0" '[ $rc = 0 ]'
ck "adopt: direct exec passes" '[ "$("$d/dest.sh")" = hook-ran ]'
ck "adopt: mode 755" '[ "$(stat -c %a "$d/dest.sh")" = 755 ]'
ck "adopt: backup keeps old bytes and mode" 'b=$(ls "$d"/dest.sh.bak-* | head -1); [ "$(cat "$b")" = old ] && [ "$(stat -c %a "$b")" = 640 ]'
ck "adopt: no temp file left" '! ls "$d"/.adopt.* >/dev/null 2>&1'
echo keep > "$d/d2.sh"; chmod 755 "$d/d2.sh"
"$A" "$d/src.sh" "$d/d2.sh" 644 >/dev/null 2>&1; rc=$?
ck "non-executable mode refused (exit 3) and dest restored" '[ $rc = 3 ] && [ "$(cat "$d/d2.sh")" = keep ] && [ -x "$d/d2.sh" ]'
"$A" "$d/nosuch" "$d/x" >/dev/null 2>&1; ck "missing src exit 64" '[ $? = 64 ]'
echo "pass=$p fail=$f"; [ $f = 0 ]
