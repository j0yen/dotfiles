#!/usr/bin/env bash
# analysis-spec-age.test.sh: hermetic test of .local/bin/analysis-spec-age.sh (1071 M6). HOME and the vault are mktemp dirs; the clock is SPEC_AGE_NOW.
# FIRST assertion replays the real 1071 page (tests/fixtures/1071/1071-page.md): its ~/.local/bin/aide-hold.sh is absent in the throwaway HOME -> SPEC, aged from the page date.
# Run: bash tests/analysis-spec-age.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
SA=$repo/.local/bin/analysis-spec-age.sh
BASE=$(mktemp -d "${TMPDIR:-/tmp}/spec-age-test.XXXXXX") || exit 2
trap 'rm -rf -- "${BASE:?}"' EXIT
fail=0
ok() { if [ "$2" = 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
D0=$(date -u -d 2026-10-31 +%s)           # the 1071 page date
mk() { H=$BASE/$1; V=$H/vault; mkdir -p "$V" "$H/.local/bin"; OUTJ=$H/spec-age.json; }
run() { env -i HOME="$H" PATH=/usr/bin:/bin TZ=UTC SPEC_AGE_VAULT="$V" SPEC_AGE_OUT="$OUTJ" SPEC_AGE_NOW="$1" bash "$SA"; }
jq_() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$OUTJ" "$1"; }
page() { # NAME DATE then the mechanism lines on stdin
  { printf -- '---\ntitle: "t"\ndate: %s\n---\n\n# Question\nq\n\n# Mechanisms\n\n' "$2"; cat; printf '\n# Fair record\n\n9. not a mechanism — ⚙ ~/.local/bin/zz.sh — owner rb — state SPEC.\n'; } > "$V/$1-five-whys-rhyme.md"
}

bash -n "$SA" && ok "bash -n" 0 || ok "bash -n" 1
[ -x "$SA" ] && ok "analysis-spec-age.sh is executable" 0 || ok "analysis-spec-age.sh is executable" 1

# 1. FIRST: the real 1071 page. Items 3, 4, 6 name a ~ path absent in the throwaway HOME and are owned by aide; items 1, 2, 5 name only wm-build/other-host paths.
mk real; cp "$here/fixtures/1071/1071-page.md" "$V/2026-10-31-1071-five-whys-rhyme.md"
run $((D0 + 8*86400)) >/dev/null 2>&1; rc=$?
ok "1071 page: exits 0 (rc=$rc)" "$rc"
[ "$(jq_ "d['spec_older_7d']['aide']")" = 3 ] && ok "1071 page, 8 days old: aide-hold.sh (M4) and analysis-spec-age.sh (M6) absent -> SPEC, aide = 3" 0 || { ok "1071 page, 8 days old: aide = 3" 1; cat "$OUTJ"; }
[ "$(jq_ "d['unchecked']")" = 3 ] && ok "1071 page: the three wm-build-path mechanisms are unchecked" 0 || ok "1071 page: three unchecked" 1
[ "$(jq_ "len(d['live_path_missing'])")" = 0 ] && ok "1071 page: nothing written LIVE, nothing missing" 0 || ok "1071 page: nothing missing" 1
run $((D0 + 3*86400)) >/dev/null 2>&1
[ "$(jq_ "d['spec_older_7d']['aide']")" = 0 ] && ok "1071 page, 3 days old: aide = 0" 0 || ok "1071 page, 3 days old: aide = 0" 1
touch "$H/.local/bin/aide-hold.sh"; mkdir -p "$H/wintermute/fleet-dash"; touch "$H/wintermute/fleet-dash/collect.sh" "$H/.local/bin/analysis-spec-age.sh"
run $((D0 + 8*86400)) >/dev/null 2>&1
[ "$(jq_ "d['spec_older_7d']['aide']")" = 0 ] && ok "1071 page with the three local paths present: derived LIVE, aide = 0" 0 || ok "1071 page with local paths present: aide = 0" 1

# 2. the five fixture cases
mk cases
page a 2026-10-31 <<'EOF'
1. spec absent old — fix — ⚙ `~/.local/bin/absent-old.sh` + `collect.sh` — owner rb — state SPEC.
EOF
page b 2026-11-05 <<'EOF'
1. spec absent young — fix — ⚙ ~/.local/bin/absent-young.sh — owner r7 — state SPEC.
EOF
page c 2026-10-31 <<'EOF'
1. spec but the path exists — fix — ⚙ ~/.local/bin/present.sh:12-40 — owner aide — state SPEC.
EOF
page d 2026-10-31 <<'EOF'
1. written live, path absent — fix — ⚙ $HOME/.claude/hooks/gone.sh — owner aide — state LIVE.
2. written merged, path present — fix — ⚙ ~/.local/bin/present.sh — owner aide — state MERGED.
EOF
page e 2026-10-31 <<'EOF'
1. PR form — fix — ⚙ j0yen/dotfiles#99 and wm-build `src/x.rs` — owner rb — state SPEC.
2. other state — fix — ⚙ ~/.local/bin/absent-other.sh — owner rb — state DISABLED.
EOF
: > "$H/.local/bin/present.sh"
run $(( $(date -u -d 2026-11-08 +%s) )) >/dev/null 2>&1   # a: 8 days, b: 3 days
[ "$(jq_ "d['spec_older_7d']['rb']")" = 1 ] && ok "SPEC with an absent local path, 8 days old -> rb = 1" 0 || { ok "SPEC absent 8 days -> rb = 1" 1; cat "$OUTJ"; }
[ "$(jq_ "d['spec_older_7d']['r7']")" = 0 ] && ok "SPEC with an absent local path, 3 days old -> r7 = 0" 0 || ok "SPEC 3 days old -> r7 = 0" 1
[ "$(jq_ "d['spec_older_7d']['aide']")" = 0 ] && ok "written SPEC whose local path exists (:line suffix stripped) -> LIVE, aide = 0" 0 || ok "written SPEC whose path exists -> aide = 0" 1
[ "$(jq_ "d['live_path_missing']")" = "[['d-five-whys-rhyme.md', '\$HOME/.claude/hooks/gone.sh']]" ] && ok "written LIVE with an absent path -> live_path_missing 1 (merged+present is not listed)" 0 || { ok "written LIVE with an absent path -> missing 1" 1; cat "$OUTJ"; }
[ "$(jq_ "d['unchecked']")" = 1 ] && ok "PR / wm-build form -> unchecked 1 (DISABLED state ignored; the item below # Fair record ignored)" 0 || { ok "PR form -> unchecked 1" 1; cat "$OUTJ"; }
[ "$(jq_ "d['ts']")" = "$(date -u -d 2026-11-08 +%s)" ] && ok "ts is the injected clock" 0 || ok "ts is the injected clock" 1
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); s=json.load(open(sys.argv[2])); sys.exit(0 if set(d)==set(s) and set(d["spec_older_7d"])>=set(s["spec_older_7d"]) else 1)' "$OUTJ" "$here/fixtures/shared/spec-age.json" \
  && ok "output keys match the shared spec-age.json contract" 0 || ok "output keys match the shared spec-age.json contract" 1

# 3. units + usage
run2() { env -i HOME="$H" PATH=/usr/bin:/bin bash "$SA" --x >/dev/null 2>&1; }
run2; [ $? -eq 64 ] && ok "unknown argument -> 64" 0 || ok "unknown argument -> 64" 1
u=$repo/.config/systemd/user
grep -qx 'OnCalendar=daily' "$u/analysis-spec-age.timer" && grep -qx 'Persistent=true' "$u/analysis-spec-age.timer" && ok "analysis-spec-age.timer: daily, persistent" 0 || ok "analysis-spec-age.timer: daily, persistent" 1
grep -qx 'Type=oneshot' "$u/analysis-spec-age.service" && grep -q 'ExecStart=.*\.local/bin/analysis-spec-age\.sh"$' "$u/analysis-spec-age.service" && grep -qx 'ConditionHost=carbon' "$u/analysis-spec-age.service" && ok "analysis-spec-age.service: oneshot, carbon only" 0 || ok "analysis-spec-age.service" 1

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fail"; fi
exit "$fail"
