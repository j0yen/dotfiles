#!/usr/bin/env bash
# mergeone.sh refuses a PR whose branch commits carry an author other than j0yen (A1296): GitHub appends
# "Co-authored-by: <author>" to the squash for every such author even when --body is explicit (faaf15ee, dotfiles#394).
# Fake gh + wm-decide on PATH; nothing reaches GitHub.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; M="$here/.local/bin/mergeone.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok - $1"; }; bad() { fail=$((fail+1)); echo "NOT OK - $1"; }
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_CALLS"
case "$*" in
  "pr view 5 -R j0yen/dotfiles --json state,mergeable,headRefOid,isDraft,statusCheckRollup,files")
    echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefOid":"1111111111111111111111111111111111111111","isDraft":false,"statusCheckRollup":[],"files":[]}' ;;
  "api repos/j0yen/dotfiles/compare/"*) exit 1 ;;
  "api repos/j0yen/dotfiles/pulls/5/commits --paginate -q .[].commit.author.email")
    [ "${FAKE_AUTHORS_RC:-0}" = 0 ] || exit 1; printf '%s\n' $FAKE_AUTHORS ;;
  *"--json title -q .title") echo "t" ;;
  *"--json body -q .body") echo "b" ;;
  "pr merge "*) echo merged ;;
  *) echo "unexpected gh $*" >&2; exit 99 ;;
esac
SH
printf '#!/usr/bin/env bash\necho "wm-decide $*" >> "$FAKE_CALLS"\n' > "$tmp/bin/wm-decide"
chmod +x "$tmp/bin/gh" "$tmp/bin/wm-decide"
run() { : > "$tmp/calls"; out="$(PATH="$tmp/bin:$PATH" FAKE_CALLS="$tmp/calls" FAKE_AUTHORS="$1" FAKE_AUTHORS_RC="${2:-0}" bash "$M" dotfiles 5 d-20261110-080000-controller-abcd 2>&1)"; rc=$?; }
merged() { grep -q '^gh pr merge 5 ' "$tmp/calls"; }
gated() { grep -q '^wm-decide merge-gate ' "$tmp/calls"; }

run "jyen.tech@gmail.com jyen.tech@gmail.com"
[ $rc = 0 ] && merged && [[ "$out" == *"MERGED"* ]] && ok "j0yen-authored branch merges" || bad "j0yen branch: rc=$rc $out"
run "12345+j0yen@users.noreply.github.com"
[ $rc = 0 ] && merged && ok "j0yen noreply author merges" || bad "noreply: rc=$rc $out"
run "jyen.tech@gmail.com rb@redbaron"
[ $rc = 10 ] && ! merged && ! gated && [[ "$out" == *"ATTRIBUTION-AUTHOR rb@redbaron"* ]] && ok "rb@redbaron branch author: rc 10, no gate, no merge" || bad "foreign author: rc=$rc $out"
run "jyen.tech@gmail.com" 1
[ $rc = 10 ] && ! merged && [[ "$out" == *"ATTRIBUTION-AUTHOR-UNCHECKED"* ]] && ok "unreadable branch commits: rc 10, no merge" || bad "api fail: rc=$rc $out"
run ""
[ $rc = 10 ] && ! merged && [[ "$out" == *"ATTRIBUTION-AUTHOR-UNCHECKED"* ]] && ok "empty commit list: rc 10, no merge" || bad "empty: rc=$rc $out"

echo "$pass passed, $fail failed"; [ $fail = 0 ]
