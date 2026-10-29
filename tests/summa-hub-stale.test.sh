#!/usr/bin/env bash
# summa-hub-stale.sh against a fixture vault + memory dir + CLAUDE.md under mktemp.
# Never touches the real vault.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="$here/.claude/scripts/summa-hub-stale.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/summa-hub-stale.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$1" = 0 ]; then echo "ok - $2"; else echo "NOT OK - $2"; fail=1; fi; }

mkfix() {
  rm -rf "$T/v" "$T/m" "$T/CLAUDE.md"
  mkdir -p "$T/v/wiki/entities" "$T/v/wiki/playbooks" "$T/m"
  printf 'rules\n' >"$T/CLAUDE.md"
  printf 'a\n' >"$T/m/alpha-1.md"; printf 'b\n' >"$T/m/alpha-2.md"; printf 'c\n' >"$T/m/beta.md"
  touch -d '2026-01-01 00:00:00' "$T/CLAUDE.md" "$T/m/alpha-1.md" "$T/m/alpha-2.md" "$T/m/beta.md"
}
page() { # file title tags-line updated sources-block
  printf -- '---\nsumma: entity\ntitle: %s\ntags: %s\nupdated: %s\n%s---\nbody\n' "$2" "$3" "$4" "$5" >"$1"
}
run() { SUMMA_VAULT="$T/v" SUMMA_MEMORY="$T/m" SUMMA_CLAUDE_MD="$T/CLAUDE.md" bash "$S" 2>&1; }

# (a) two hubs, both fresh (inline tag list in both orders, inline + block sources)
mkfix
page "$T/v/wiki/entities/One.md" One '[fleet, hub]' '2026-06-01T00:00:00Z' $'sources:\n  - CLAUDE.md\n  - memory/beta.md\n'
page "$T/v/wiki/playbooks/Two.md" Two '[hub, fleet]' '2026-06-01' $'sources: [memory/alpha-1.md, "memory/beta.md"]\n'
out="$(run)"; echo "$out" | tail -1 | grep -qx 'summa-hub-stale: stale=0 of 2'; chk $? "(a) two fresh hubs -> stale=0 of 2"

# (a2) block-list tags are accepted
printf -- '---\ntitle: Three\ntags:\n  - fleet\n  - hub\nupdated: 2026-06-01\nsources:\n  - CLAUDE.md\n---\nbody\n' >"$T/v/wiki/entities/Three.md"
out="$(run)"; echo "$out" | tail -1 | grep -qx 'summa-hub-stale: stale=0 of 3'; chk $? "(a2) block-list tags counted as a hub"
rm "$T/v/wiki/entities/Three.md"

# (b) touch one cited file to now -> exactly that page, newest names that file
touch "$T/m/alpha-1.md"
out="$(run)"
echo "$out" | tail -1 | grep -qx 'summa-hub-stale: stale=1 of 2' && echo "$out" | grep -q '^Two updated=.* newest='"$T"'/m/alpha-1.md@'; chk $? "(b) touched source -> Two stale, newest=alpha-1.md"
echo "$out" | grep -q '^One '; [ $? -ne 0 ]; chk $? "(b) One is not listed"

# (c) empty sources
mkfix
page "$T/v/wiki/entities/Empty.md" Empty '[hub]' '2026-06-01' $'sources: []\n'
page "$T/v/wiki/entities/None.md" None '[hub]' '2026-06-01' ''
out="$(run)"
echo "$out" | grep -q '^Empty updated=.* newest=none reason=no-sources$' && echo "$out" | grep -q '^None updated=.* newest=none reason=no-sources$' && echo "$out" | tail -1 | grep -qx 'summa-hub-stale: stale=2 of 2'; chk $? "(c) empty / missing sources -> reason=no-sources"

# (d) non-matching glob
mkfix
page "$T/v/wiki/entities/Lost.md" Lost '[hub]' '2026-06-01' $'sources:\n  - memory/gone-*.md\n'
out="$(run)"; echo "$out" | grep -q '^Lost updated=.* newest=none reason=no-match$'; chk $? "(d) non-matching glob -> reason=no-match"

# (d2) unresolvable entry shapes are reported as such, not folded into no-match
mkfix
page "$T/v/wiki/entities/Odd.md" Odd '[hub]' '2026-06-01' $'sources:\n  - CLAUDE.md\n  - /etc/hostname\n'
page "$T/v/wiki/entities/Up.md" Up '[hub]' '2026-06-01' $'sources:\n  - memory/../CLAUDE.md\n'
out="$(run)"
echo "$out" | grep -q '^Odd updated=.* newest=none reason=unresolvable entry=/etc/hostname$' && echo "$out" | grep -q '^Up updated=.* newest=none reason=unresolvable entry=memory/../CLAUDE.md$'; chk $? "(d2) unresolvable entries -> reason=unresolvable entry=<entry>"

# (e) glob picks the newest of two matching files
mkfix
page "$T/v/wiki/entities/Glob.md" Glob '[hub]' '2026-06-01' $'sources:\n  - memory/alpha-*.md\n'
touch -d '2026-09-01 00:00:00' "$T/m/alpha-2.md"
out="$(run)"; exp_ts="$(date -d "@$(stat -c %Y "$T/m/alpha-2.md")" +%Y-%m-%dT%H:%M:%S%z)"
echo "$out" | grep -q '^Glob updated=.* newest='"$T"'/m/alpha-2.md@'"$exp_ts"'$'; chk $? "(e) glob resolves to the newest of 2 matches"

# (f) non-hub entity ignored: m counts hubs only
mkfix
page "$T/v/wiki/entities/Hub1.md" Hub1 '[hub]' '2026-06-01' $'sources:\n  - CLAUDE.md\n'
page "$T/v/wiki/entities/Plain.md" Plain '[fleet]' '2026-06-01' ''
printf -- '---\ntitle: Stub\n---\n\n## Mentions\n- hub in prose only\n' >"$T/v/wiki/entities/Stub.md"
out="$(run)"; echo "$out" | tail -1 | grep -qx 'summa-hub-stale: stale=0 of 1'; chk $? "(f) non-hub pages ignored (m=1)"

# (g) summary line is exactly one, last, exact format; exit 0; unparseable updated = stale; vault missing = exit 2
mkfix
page "$T/v/wiki/entities/Bad.md" Bad '[hub]' 'someday' $'sources:\n  - CLAUDE.md\n'
out="$(run)"; rc=$?
[ "$(echo "$out" | grep -c '^summa-hub-stale: ')" = 1 ] && echo "$out" | tail -1 | grep -qxE 'summa-hub-stale: stale=[0-9]+ of [0-9]+' && [ "$rc" = 0 ] && echo "$out" | grep -q '^Bad updated=none .*reason=no-updated$'; chk $? "(g) one exact summary line, exit 0, unparseable updated = stale"
SUMMA_VAULT="$T/nope" bash "$S" >/dev/null 2>&1; [ $? = 2 ]; chk $? "(g) missing vault -> exit 2"

exit $fail
