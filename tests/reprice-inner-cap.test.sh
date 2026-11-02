#!/usr/bin/env bash
# A191: reprice-inner-cap.sh is tracked in dotfiles; report mode validates a candidate, --apply refuses below the floor / without --by / with < 3 rows.
# Every host call (sqlite3, wm-build, wm-build-limits-guard) is a fake on PATH; HOME is a temp dir.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); S=$HERE/.local/bin/reprice-inner-cap.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T; mkdir -p "$T/bin" "$T/.config/wm-build" "$T/.local/state/wm-build" "$T/.cargo/bin"
touch "$T/.local/state/wm-build/state.db"
printf '{"ts":"t","kind":"cargo-gate-reloaded","inner":9.5}\n' | sed 's/"kind":"cargo-gate-reloaded"/"cargo-gate-reloaded"/' > "$T/.local/state/wm-build/journal.jsonl"
CFG=$T/.config/wm-build/config.toml
cat > "$CFG" <<'C'
[daemon]
admit_min_avail_x_peak = 0.5  # old
[cargo_jobs.mem_caps_gb]
inner = 13.5
C
cat > "$T/bin/sqlite3" <<'F'
#!/usr/bin/env bash
q=$*
case "$q" in
  *"count(*), coalesce(round(max(priced"*) echo "${FAKE_ROWS:-12} ${FAKE_PMAX:-6.2} 14.0";;
  *"order by rowid desc"*) echo "r1 6.2 14.0";;
  *"order by id desc"*) echo "5 8388608";;
esac
F
cat > "$T/bin/wm-build" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = config ] && [ "${2:-}" = --config ]; then
  inner=$(grep -oE '^inner = [0-9.]+' "$3" | grep -oE '[0-9.]+$'); x=$(grep -oE '^admit_min_avail_x_peak = [0-9.]+' "$3" | grep -oE '[0-9.]+$')
  printf '"mem_caps_gb": {\n "inner": %s\n}\n"admit_min_avail_x_peak": {\n "value": %s\n}\n' "$inner" "$x"; exit 0
fi
[ "${1:-}" = status ] && exit 0
printf '"mem_caps_gb": {\n "inner": 0\n}\n"admit_min_avail_x_peak": {\n "value": 1.0\n}\n'
F
printf '#!/usr/bin/env bash\necho guard-ok\n' > "$T/bin/wm-build-limits-guard"
chmod +x "$T/bin/"*; export PATH=$T/bin:$PATH
fail=0; ok(){ echo "ok - $1"; }; bad(){ echo "not ok - $1"; fail=1; }
out=$(bash "$S" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "report mode exits 0" || bad "report rc=$rc"
grep -q 'proposed_inner_cap_gb=8.5' <<<"$out" && ok "proposal = priced max 6.2 + 2, ceil 0.5 = 8.5" || bad "proposal: $out"
grep -q 'VALIDATE_RC=0' <<<"$out" && ok "candidate validates via fake wm-build" || bad "validate: $out"
grep -q 'FLOOR_OK' <<<"$out" && ok "proposal passes the floor" || bad "floor"
grep -q 'inner = 13.5' "$CFG" && ok "report mode leaves config untouched" || bad "config changed by report"
out=$(bash "$S" --apply 7.0 2>&1); rc=$?
[ $rc -eq 2 ] && ok "--apply without --by exits 2" || bad "no --by rc=$rc"
out=$(bash "$S" --apply 7.0 --by "t q" 2>&1); rc=$?
[ $rc -eq 6 ] && grep -q REFUSE <<<"$out" && ok "cap below floor (7.0 < 6.2+2) refused rc 6" || bad "floor refuse rc=$rc $out"
grep -q 'inner = 13.5' "$CFG" && ok "refusal leaves config untouched" || bad "config changed by refusal"
out=$(FAKE_ROWS=2 bash "$S" --apply 9.5 --by "t q" 2>&1); rc=$?
[ $rc -eq 3 ] && ok "fewer than 3 priced rows refused rc 3" || bad "rows refuse rc=$rc"
out=$(bash "$S" --apply 9.5 --by "t q" 2>&1); rc=$?
grep -q '^inner = 9.5 ' "$CFG" && grep -q '^admit_min_avail_x_peak = 1.0 ' "$CFG" && ok "apply rewrites inner and couples admit_min_avail_x_peak" || bad "apply: rc=$rc $(cat "$CFG")"
ls "$CFG".bak-reprice-* >/dev/null 2>&1 && ok "backup written" || bad "no backup"
exit $fail
