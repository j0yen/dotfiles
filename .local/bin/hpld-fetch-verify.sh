#!/usr/bin/env bash
# hpld-fetch-verify.sh <owner/name> <pr> <sha40> [--out DIR] [--suite CMD]: carbon side of a remote suite run. Needs AIDE_VERIFIER_SUITE_HOST.
# ssh starts hpld-remote-verify.sh on the suite host, polls for its write-once log, scp's it into DIR (write-once, temp + mv), checks provenance.
# Exit: 0 log fetched and COMMIT = HEAD = sha, DIRTY=0, EXIT read (the EXIT inside is the suite's verdict); stdout LOG: <path> and EXIT: <n>
#       2 usage / host refused (unset, carbon, localhost, this host); 5 provenance mismatch or the PR head moved (refused); 6 UNVERIFIED (ssh 255, timeout, no log): NO verdict, never red.
# Env: AIDE_VERIFIER_SUITE_HOST HPLD_SSH (ssh) HPLD_SCP (scp) HPLD_REMOTE_BIN (.local/bin/hpld-remote-verify.sh, relative to the remote home)
#      HPLD_FETCH_TIMEOUT_S (5400) HPLD_FETCH_POLL_S (30) HPLD_HOSTNAME_CMD (hostname)
set -uo pipefail
die() { echo "hpld-fetch-verify: $2" >&2; exit "$1"; }
[ $# -ge 3 ] || die 2 "usage: hpld-fetch-verify.sh <owner/name> <pr> <sha40> [--out DIR] [--suite CMD]"
repo="$1"; pr="$2"; sha="$3"; shift 3
out="$PWD"; suite=""
while [ $# -gt 0 ]; do case "$1" in --out) out="${2:?}"; shift 2 ;; --suite) suite="${2:?}"; shift 2 ;; *) die 2 "unknown arg $1" ;; esac; done
host="${AIDE_VERIFIER_SUITE_HOST:-}"
[ -n "$host" ] || die 2 "AIDE_VERIFIER_SUITE_HOST is unset"
me="$(${HPLD_HOSTNAME_CMD:-hostname} 2>/dev/null)"
case "$host" in carbon|localhost|127.*|::1|"$me") die 2 "AIDE_VERIFIER_SUITE_HOST=$host is this host; carbon never runs a suite" ;; esac
[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "bad host name"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die 2 "bad repo/pr/sha"
SSH="${HPLD_SSH:-ssh}"; SCP="${HPLD_SCP:-scp}"; BIN="${HPLD_REMOTE_BIN:-.local/bin/hpld-remote-verify.sh}"
TMO="${HPLD_FETCH_TIMEOUT_S:-5400}"; POLL="${HPLD_FETCH_POLL_S:-30}"
mkdir -p "$out" || die 2 "cannot create $out"
args=(); [ -z "$suite" ] || args=(--suite "$suite")
start() { "$SSH" -o BatchMode=yes "$host" "$BIN" "$repo" "$pr" "$sha" "${args[@]+"${args[@]}"}" 2>&1; }
rc=0; o="$(start)" || rc=$?
if [ "$rc" = 255 ]; then rc=0; o="$(start)" || rc=$?; fi   # one retry; a second 255 is no verdict
log="$(printf '%s\n' "$o" | sed -n 's/^LOG=//p' | tail -n1)"
case "$rc" in
  0|3) ;;   # 3 = the first attempt already started it (write-once log path): poll for the same log
  4) die 5 "the PR head moved: the suite host's refs/pull/$pr/head is not $sha ($(printf '%s' "$o" | tail -n1 | cut -c1-200))" ;;
  *) die 6 "UNVERIFIED: ssh start rc=$rc: $(printf '%s' "$o" | tail -n1 | cut -c1-200)" ;;
esac
[ -n "$log" ] && [[ "$log" =~ ^/[A-Za-z0-9._/-]+\.log$ ]] || die 6 "UNVERIFIED: the suite host printed no usable LOG= path"
t0=$SECONDS
until "$SSH" -o BatchMode=yes "$host" test -f "$log" >/dev/null 2>&1; do
  [ $((SECONDS - t0)) -lt "$TMO" ] || die 6 "UNVERIFIED: no log $log on $host after ${TMO}s"
  sleep "$POLL"
done
dest="$out/$(basename "$log")"
[ ! -e "$dest" ] || die 6 "UNVERIFIED: $dest already exists (write-once)"
tmp="$(mktemp -p "$out" .hpld-fetch.XXXXXX)" || die 6 "UNVERIFIED: cannot create a temp file in $out"
trap 'rm -f -- "$tmp"' EXIT
"$SCP" -o BatchMode=yes -q "$host:$log" "$tmp" || die 6 "UNVERIFIED: scp failed"
hdr="$(head -n1 "$tmp")"
f() { printf '%s\n' "$hdr" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
[[ "$hdr" == "HPLD-VERIFY "* ]] && [ "$(f COMMIT)" = "$sha" ] && [ "$(f HEAD)" = "$sha" ] && [ "$(f DIRTY)" = 0 ] && [[ "$(f EXIT)" =~ ^[0-9]+$ ]] \
  || die 5 "provenance mismatch, log refused: header '$(printf '%s' "$hdr" | cut -c1-200)' (want COMMIT=HEAD=$sha DIRTY=0 EXIT=<n>)"
mv -n "$tmp" "$dest" && [ ! -e "$tmp" ] || die 6 "UNVERIFIED: could not place $dest"
echo "LOG: $dest"; echo "EXIT: $(f EXIT)"
