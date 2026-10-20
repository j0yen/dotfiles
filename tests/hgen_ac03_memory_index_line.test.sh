#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC3: a MEMORY.md without the index line gets
# it exactly once at line 2 after two runs; every other line is byte-identical.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
hgen_setup
m="$HANDOFF_MEMORY_DIR/MEMORY.md"
printf '%s\n' '- [first](a.md) — one' '- [second](b.md) — two & three \ four' '' '- [last](c.md) — end' >"$m"
cp "$m" "$work/before.md"
"$HGEN" --out "$work/t.md"; "$HGEN" --out "$work/t.md"
assert_eq "$(grep -c 'handoff-generated-carbon.md' "$m")" "1" "index line present exactly once"
assert_eq "$(sed -n 2p "$m")" '- [GENERATED HANDOFF — read first](handoff-generated-carbon.md) · [redbaron](handoff-generated-redbaron.md) · [ryzen7](handoff-generated-ryzen7.md) — per-host, rewritten at every SessionEnd by handoff-gen.sh; the prose handoff keeps decisions and traps only' "index line is line 2, verbatim"
assert_eq "$(cmp <(sed 2d "$m") "$work/before.md" && echo same)" "same" "every other line byte-identical"
# no trailing newline on the last line must survive too
printf '%s\n%s' 'top' 'tail-no-newline' >"$m"; cp "$m" "$work/before2.md"
"$HGEN" --out "$work/t.md"
assert_eq "$(cmp <(sed 2d "$m") "$work/before2.md" && echo same)" "same" "unterminated last line preserved"
assert_eq "$(sed -n 1p "$m")" "top" "line 1 untouched"
exit $fail
