# scratch.sh: shared by every worker-route test script. Test scratch lives under an explicit scratch root (WR_TEST_TMP, else TMPDIR), never /tmp or /var/tmp
# (R3-5): a mktemp under the default /tmp is refused (exit 64 from the caller via `wr_scratch || exit 64`).
wr_scratch() {
  local base="${WR_TEST_TMP:-${TMPDIR:-}}"
  case "$base" in
    ""|/tmp|/tmp/*|/var/tmp|/var/tmp/*) echo "worker-route tests: set WR_TEST_TMP (or TMPDIR) to a scratch directory outside /tmp; got '${base:-unset}'" >&2; return 64;;
  esac
  [ -d "$base" ] || { echo "worker-route tests: scratch root '$base' is not a directory" >&2; return 64; }
  mktemp -d "$base/wr.XXXXXX"
}
