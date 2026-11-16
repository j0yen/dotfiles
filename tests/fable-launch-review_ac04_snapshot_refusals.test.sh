#!/usr/bin/env bash
# fable-launch-review AC 4: a review request whose manifest fails R3 (or carries no pre-drawn id, R11) is refused 64 with a denied row; nothing starts.
# Run alone: bash tests/fable-launch-review_ac04_snapshot_refusals.test.sh
. "$(dirname "$0")/fable-launch-review_lib.sh"
flr_begin
: >"$T/empty.sha256"; cp "$FX/happy.sha256" "$T/unread.sha256"; chmod 000 "$T/unread.sha256"
# refuse NAME SNAPSHOT CHECK LINE [cwd]: launch a review request with a fresh pre-drawn id and assert the refusal.
refuse(){
  local n="$1" m="$2" c="$3" ln="$4" cwd="${5:-$T}" real
  flr_req "$n" A4 "$m"; (cd "$cwd" && flr_run "$n" "$n" --session-id "$(uuid)" -p x)
  real="$(cd "$cwd" && readlink -f -- "$m" 2>/dev/null)" || real="$m"; [ -n "$real" ] || real="$m"
  ck "$n: exit 64, nothing started, one denied row, no launch row" '[ "$(cat $T/rc.$n)" = 64 ] && flr_spy_empty $n && [ "$(flr_count $n denied)" = 1 ] && [ "$(flr_count $n launch)" = 0 ]'
  ck "$n: denied row names the manifest and the check $c${ln:+ (line $ln)}" 'w="$(flr_get $n .reasons)"; case "$w" in *"$real"*": $c"*) :;; *) false;; esac && { [ -z "$ln" ] || case "$w" in *"line $ln"|*"line $ln "*) :;; *) false;; esac; }'
  ck "$n: denied row carries role review and the resolved scope" '[ "$(flr_get $n "[.role,.scope]|join(\"|\")")" = "review|$real" ]'
  ck "$n: stderr names the check" 'grep -qF "$c" "$T/err.$n"'
}
refuse absent "$T/no-such.sha256" line-rule 0
refuse absentdir "$T/no-dir/no-such.sha256" line-rule 0
[ -r "$T/unread.sha256" ] && echo "NOTE running as a user who can read mode 000 files; the unreadable case reads as a passing manifest"
refuse unreadable "$T/unread.sha256" line-rule 0
refuse empty "$T/empty.sha256" line-rule 0
refuse crlf "$FX/crlf.sha256" line-rule 1
refuse blank "$FX/blank.sha256" line-rule 2
refuse nonl "$FX/nonl.sha256" line-rule 0
printf '%s  PRD-rs-alpha.md\tx\n' "$(cut -c1-64 "$FX/single.sha256")" >"$T/tab.sha256"; refuse tab "$T/tab.sha256" line-rule 1
printf '%s  PRD rs.md\n' "$(cut -c1-64 "$FX/single.sha256")" >"$T/space.sha256"; refuse space "$T/space.sha256" line-rule 1
refuse noprd "$FX/noprd.sha256" no-prd ""
refuse dupprd "$FX/dupprd.sha256" prd-repeat ""
ck "dupprd: the prd-repeat reason names the basename" 'flr_get dupprd .reasons | grep -qF "prd-repeat PRD-rs-alpha.md"'
refuse stale "$FX/stale.sha256" sha256sum ""
refuse missing "$FX/nonutf8.sha256" sha256sum ""
refuse cwdonly review-scope/cwdonly.sha256 sha256sum "" "$FX/.."
ck "cwdonly: the same manifest verifies from the caller's cwd (it resolves only from there)" '(cd "$FX/.." && sha256sum --check --quiet --strict review-scope/cwdonly.sha256)'
ck "line-rule and prd-repeat denied rows carry an empty scope_id" '[ -z "$(flr_get crlf .scope_id)$(flr_get dupprd .scope_id)$(flr_get absent .scope_id)" ]'
ck "no-prd and sha256sum denied rows carry the canonical scope_id" '[ "$(flr_get noprd .scope_id | wc -c)" = 65 ] && [ "$(flr_get stale .scope_id | wc -c)" = 65 ]'
flr_req nosid A4 "$FX/happy.sha256"; flr_run nosid nosid -p x
ck "fresh review launch with no --session-id: 64, nothing started" '[ "$FLR_RC" = 64 ] && flr_spy_empty nosid && [ "$(flr_count nosid launch)" = 0 ]'
ck "fresh review launch with no --session-id: the R11 denied row" '[ "$(flr_count nosid denied)" = 1 ] && flr_get nosid .reasons | grep -qF "review launch needs a pre-drawn --session-id so the guard can see it" && [ "$(flr_get nosid .role)" = review ]'
flr_end
