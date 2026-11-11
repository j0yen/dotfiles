# account-lanes fixtures

- `observed-quota.jsonl`: OBSERVED. Four quota failures read (read-only) from saved local Claude CLI session transcripts under `~/.claude/projects`. Only
  minimal fields are kept (source path + saved timestamp, `type`, `isApiErrorMessage`, `error`, `model`, `stop_reason`, the message text). In these
  transcripts the CLI's quota failure is a synthetic assistant message: `isApiErrorMessage:true`, `error:"rate_limit"` (the SAME error category a
  transient rate limit may carry, so the category alone must not be trusted), `model:"<synthetic>"`, text exactly
  `You've hit your session|weekly limit · resets <time> (America/Los_Angeles)`. 165 candidate records, 24 distinct texts, only these two wordings.
- `observed-result-success.json`: OBSERVED shape of a real stream-json terminal `result` event (a successful run of this task's own stream). The shape of a
  terminal result event for a QUOTA failure was not found in saved evidence and is UNOBSERVED.
- Not observed anywhere: `Claude AI usage limit reached|<epoch>`, "5-hour limit", "Opus limit", org monthly limits, a stream-json quota failure, a
  plain `claude -p` stdout/stderr quota failure. Those stay `unknown` (fail closed). The classifier was not widened from speculation.
- All other fixture texts in the tests are labelled SYNTHETIC in the test files.

## native-fable-limit-observed.{json,err} (OBSERVED, not synthetic)
Saved native output of a real `ctl-fable-escalate.sh` bridge run (event 1794340620-alarm-b09a: `--output-format json --tools "" --no-session-persistence`, launcher account=jyen.pm model=claude-fable-5-1 effort=high, rc 1): a terminal `result` with `is_error=true`, `terminal_reason=api_error`, `api_error_status=429`, `api_error=model_requires_usage_credits`, empty `modelUsage`, `num_turns=1`, and the exact text "You've reached your Fable limit. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.". The `.err` is the launcher stderr of that run (it classified unknown before the observed-contract support). SID discrepancy: the lane supervisor's private key for this run was b1297666-09be-48ec-b752-2a10faaf4364 while the native result carries session_id 7cf6c47b-eea4-4fce-a0ce-a50834a43921 (no-session-persistence: the CLI never received the supervisor key); the two are NOT correlated and neither session's UNKNOWN is cleared. Every mutated variant used by tests/account-lanes-observed-contract.test.sh is labelled SYNTHETIC in the test.

## native-nonfable-429-observed.json (OBSERVED, sanitized)
Sanitized terminal envelope of a real Sonnet 5.5 headless `--output-format json` run (ctl retained `~/.cache/ctl-w4/r546d.txt` line 16; native non-zero exit, empty stderr reported by the owner): `type=result`, `subtype=success`, `is_error=true`, `terminal_reason=api_error`, `api_error_status=429`, `result="You've hit your weekly limit · resets Nov 12, 10am (America/Los_Angeles)"`, `total_cost_usd=0`. It carries NO `session_id` (none was supplied or invented), no `api_error`, no `modelUsage`. NOT independently captured here: the launching argv, the exit code value, the account, the stderr bytes, and any stream-json form. Every mutation in tests/account-lanes-nonfable-envelope.test.sh is SYNTHETIC.
