# wmb-classify.sh -- SOURCED library (no side effects on source, no `set -e`): the one wm-build subcommand classifier.
# SOURCE OF TRUTH: j0yen/dotfiles PR 94 (rb/guard26-wm-build-bound-shim), .local/bin/wm-build-bound-shim.sh at head
#   598678cd925ce89980fd3f67b859ea9f633039aa; `wmb_classify` below is that function copied BYTE-IDENTICAL. tests/wm-build-status-gate.test.sh pins the
#   sha and the sha256 of the function text; a #94 amendment lands as a red test (no-drift), never a silent SKIP.
# CONSUMERS: .claude/hooks/wm-build-status-gate.sh (PreToolUse Bash hook, every session). Follow-up (needs #94 merged): the shim sources this lib too.
# PREMISE: top-level `wm-build status` / `wm-build runs` parse the whole user journal (~12 G); one call froze ryzen7 10-24 2:38 PM
#   (rb hand PR 1e3f fixes it at the source). EXPIRES: 2026-10-31 (same as the shim). Approval 26 (Joe 10-24 4:02 PM "build the guard").
# BOUND SET = {status, runs}, the documented whole-journal set. Widening it is a lib + fixture edit; `log`, `live`, `run list` were NOT measured.
#
# wmb_classify <argv...>: prints "bound" or "pass" for the wm-build argv that follows the binary name.
wmb_classify() {
  local args=("$@") n=$# idx=0 w
  while [ "$idx" -lt "$n" ]; do
    w=${args[$idx]}
    case $w in
      --config|--prd-dir|--state-dir|--max-runs|--set) idx=$((idx + 2)) ;;
      --config=*|--prd-dir=*|--state-dir=*|--max-runs=*|--set=*) idx=$((idx + 1)) ;;
      -*)  # unknown option before any subcommand: fallback, bound iff some word is status/runs
        for w in "${args[@]}"; do
          case $w in status|runs) echo bound; return 0 ;; esac
        done
        echo pass; return 0 ;;
      status|runs) echo bound; return 0 ;;
      *) echo pass; return 0 ;;   # first non-option word = another subcommand
    esac
  done
  echo pass
}
