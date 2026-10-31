# precheck replay fixtures, 2026-10-30

Twelve launch-time fixtures for `tests/precheck-replay.test.sh` (shift-left pre-action review, AC 1). Built from ryzen7 journals, leg logs,
`gh api` reads and the decision rows; RedBaron was not touched (the `oom` fixture uses its page only). Not read by the replay: `expected`,
`why_legit`, `note`, this file.

- `launch_ts` is the `Started` line of the unit that ran (the systemd-run moment), not the later start-gate or leg start. `launch_ts_source` names it.
- `cmd` is verbatim only where `cmd_exact` is true (`oom`). Transient unit files and seat transcripts are gone or off limits, so the other
  commands are rebuilt from the journal description, the unit environment the page and rows state, and the script args in the leg log; `...` marks what is not recoverable.
- `row` is the decision row at or before `launch_ts`. Rows written after the unit started are excluded, so `362`, `362f` and `legit-2` carry
  `row: null` (excluded: d-20261030-033550-r7-e85a, d-20261030-121539-r7-4c1e, d-20261030-145737-r7-c613).
  Earlier rows that name the head or slug are listed under the fact `recent_decision_rows_naming_head_or_slug`.
- Fact keys are stable across fixtures (`prior_leg_log`, `pr_state`, `git_show_stat`, ...) so a read list can project them; list values are one entry per log, PR or commit.
  `unknown` values state why in `source`.
- `cheap-controls.txt`: `<command><TAB><class>`; a newline inside a command is the two characters `\n` (heredoc controls). The class for a redrive is `relaunch`.
- Lint: `tests/precheck-hindsight-lint.sh <fixture>`; regenerate nothing by hand, the fixtures came from a one-off generator run on ryzen7.
