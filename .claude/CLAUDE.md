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

- OpenClaw shares this machine and appears on `agorabus` as `openclaw-main` while its gateway is active.
- At the start of substantial work, inspect `agorabus peers`, `agorabus intent list`, and—when work may overlap—the last 20 lines of `journalctl --user -u openclaw-agorabus.service --no-pager`.
- Publish a concise `agent.activity` event when substantial work starts or finishes. Include only `agent`, `status`, `summary`, and `paths`; use `claude-activity` as the one-shot publisher session id.
- Never publish raw prompts, transcripts, secrets, personal messages, or full tool output. Coordination events do not belong in Recall, Summa, or Claude memory unless the user separately asks to preserve something.
