# Primary interface: ADHD output shape (Joe, 2026-09-11)

Every response uses the i-have-adhd shape — next action first, numbered steps (≤5), one concrete closing action, no preamble/recap/closer. "Explain" widens the body but keeps the shape and headers; never a wall of text. The plugin `i-have-adhd@i-have-adhd` and the marker `~/.claude/.i-have-adhd-always` must be present on every node.

# Token discipline (2026-09-11 post-burn; ledger ~/.cache/token-ledger/)

- Context cap: compact or hand off near ~100K context; no marathon sessions (09-10 runaway: 1,119 req × ~500K cache-read = 2/3 of all weighted burn).
- Tool output >2KB goes to a file; read back a summary/tail only. Raw logs never accumulate in a Fable/Opus context.
- One job = one session. Pin one model per session (mid-session model switch = full cache rewrite).
- Every Agent spawn passes an explicit `model:`; opus/fable/fork spawns are hook-blocked (override: `touch ~/.claude/.allow-expensive-spawn`).
- Status lines: TOKENS (yesterday weighted, from ledger) + forecast, next to COST. Weighted = in + 1.25·cache_write + 0.1·cache_read + 5·out.
- Daily budget cap REMOVED 2026-09-12 (Joe); ledger still reports weighted totals for visibility.

# Model routing — cheapest capable model always

Ladder: Haiku < Sonnet < Opus/Fable. Route every delegated task to the cheapest tier that can do it; escalate only on an `ESCALATE:` return or failed attempt.

| Task shape | Agent | Model |
|---|---|---|
| Find/read/describe (files, configs, model structure, status) | scout | haiku |
| Run a specified command/MCP call, return raw result | runner | haiku |
| Parse logs/ledgers/test output, classify failures | triage | haiku |
| Implement/integrate/fix code from a spec | coder | sonnet |
| Verify a claim, finding, or build actually landed | verifier | sonnet |

- Main loop (Fable/Opus) does ONLY: planning, PRD drafting, synthesis, user conversation.
- Never spawn a subagent on opus/fable unless the user explicitly asks.
- When using built-in Explore/general-purpose agents anyway, pass `model: haiku` for retrieval tasks.
- Batch independent spawns in one message; a Haiku agent that returns ESCALATE gets ONE re-dispatch to Sonnet, not a loop.

## Cross-agent awareness

- At the start of substantial work, inspect `agorabus peers` and `agorabus intent list` for other sessions whose work may overlap.
- Publish a concise `agent.activity` event when substantial work starts or finishes. Include only `agent`, `status`, `summary`, and `paths`; use `claude-activity` as the one-shot publisher session id.
- Never publish raw prompts, transcripts, secrets, personal messages, or full tool output. Coordination events do not belong in Recall, Summa, or Claude memory unless the user separately asks to preserve something.
