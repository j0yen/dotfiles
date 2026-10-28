#!/usr/bin/env bash
# coder-liveness.sh follows nested FILE mtimes, never a directory mtime (ctl 66c5).
# CLV=<script> overrides the script under test (used by the mutation check).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
CLV="${CLV:-$here/.local/bin/coder-liveness.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/clv.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "NOT OK - $1"; fail=$((fail+1)); }
run() { CODER_LIVENESS_ROOT="$T" bash "$CLV" "$@"; }
age() { sed -n 's/.* age_s=\([0-9-]*\) .*/\1/p'; }
D="$T/-home-jsy--local-state-wm-build-wt-s1"

# a. nested file, old mtime, then appended
mkdir -p "$D/sub/a"; : > "$D/sub/a/x.jsonl"; touch -d '-1 hour' "$D/sub/a/x.jsonl"
out="$(run s1)"; a="$(printf '%s' "$out" | age)"
[ "${a:-0}" -ge 3500 ] && ok "a1 old nested file age_s=$a >= 3500" || bad "a1 age_s=$a: $out"
echo '{}' >> "$D/sub/a/x.jsonl"
out="$(run s1)"; a="$(printf '%s' "$out" | age)"
[ "${a:-999}" -lt 60 ] && ok "a2 appended nested file age_s=$a < 60" || bad "a2 age_s=$a: $out"

# b. directory mtime newer than every file
touch -d '-2 hours' "$D/sub/a/x.jsonl"; touch -d '-30 minutes' "$D/sub/a/y.jsonl" 2>/dev/null || { : > "$D/sub/a/y.jsonl"; touch -d '-30 minutes' "$D/sub/a/y.jsonl"; }
touch "$D" "$D/sub" "$D/sub/a"
out="$(run s1)"; a="$(printf '%s' "$out" | age)"
if [ "${a:-0}" -ge 1700 ] && [ "$a" -le 1900 ] && printf '%s' "$out" | grep -q 'newest=.*y.jsonl' && printf '%s' "$out" | grep -q 'files=2'; then ok "b newest follows file y.jsonl (age_s=$a), not the fresh dirs"; else bad "b $out"; fi

# c. missing root / no jsonl
run nope >/dev/null 2>&1; rc=$?; [ $rc -eq 3 ] && ok "c1 missing root exit 3" || bad "c1 exit $rc"
mkdir -p "$T/-home-jsy--local-state-wm-build-wt-empty/d"; echo x > "$T/-home-jsy--local-state-wm-build-wt-empty/d/n.txt"
run empty >/dev/null 2>&1; rc=$?; [ $rc -eq 4 ] && ok "c2 no jsonl exit 4" || bad "c2 exit $rc"

# d. usage
run >/dev/null 2>&1; rc=$?; [ $rc -eq 64 ] && ok "d missing arg exit 64" || bad "d exit $rc"

echo "PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
