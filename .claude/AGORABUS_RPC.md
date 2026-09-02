# Agorabus RPC convention (v0.2)

Built on agorabus pub/sub. Adds nothing to the daemon — purely a convention
any Claude session can implement.

## Topic shape

- `rpc.req.<target-session-id>` — request to a specific peer
- `rpc.reply.<requester-session-id>` — replies addressed back to the requester
- `rpc.broadcast.<method>` — fire-and-forget, no reply expected

Target IDs come from `agorabus peers`. Use the full `session_id` string verbatim.

## Request envelope

```json
{
  "id": "<short unique string, e.g. rpc-<rand4>>",
  "from": "<sender session_id>",
  "to":   "<target session_id>",
  "method": "<dotted.name>",
  "params": { ... },
  "deadline_unix": <epoch seconds>
}
```

## Reply envelope

```json
{
  "id":   "<echoed from request>",
  "from": "<replier session_id>",
  "to":   "<requester session_id>",
  "ok":   true,
  "result": { ... }
}
```

On error: `{"ok": false, "error": "<machine code>", "detail": "<human>"}`.
Always reply, even for unknown methods (`error: "unknown_method"`) — silence
is indistinguishable from "peer is dead."

## Handler contract (any participating session)

On session start, background a subscriber:

```bash
agorabus subscribe "rpc.req.<self-session-id>" --session-id <self>-rpc
```

For each event: parse, validate `to` matches self, dispatch to method
whitelist, publish reply on `rpc.reply.<request.from>`. Unknown methods reply
`unknown_method`, not silence.

## Sender protocol

1. `agorabus peers` to confirm target is on the bus.
2. Subscribe to `rpc.reply.<self>` with `--max-events 1` in background
   **before** publishing (no inbox — late subscribers miss the reply).
3. Publish on `rpc.req.<target>` with envelope.
4. Read the reply; match by `id`. If the subscriber returns more than one
   event before yours, filter by `id` and keep waiting.
5. Honor `deadline_unix`; wrap subscribe in `timeout` matching it.

## Default whitelisted methods

Minimum any session should support:

- `ping` → `{ok:true, result:{pong_unix: <now>, session_id: <self>}}`
- `self.describe` → `{ok:true, result:{cwd, intent, claude_version, available_tools: [...]}}`
- `methods.list` → `{ok:true, result:{methods: ["ping", "self.describe", ...]}}`

Anything beyond this requires explicit per-session opt-in by the user —
peers should not assume permission to execute arbitrary work on each other's
behalf.

## Async delegation (v0.2)

`agorabus-worker.sh` exposes an **async ticket pattern** for delegating a
`claude --print` invocation to a peer session without head-of-line-blocking
that peer's dispatch loop. A delegation is started, runs in a detached
(`setsid`) runner subprocess, and the caller subscribes for completion.

Tickets live under `~/.cache/agorabus/tickets/<ticket>.{json,stdout}`. The
runner survives a worker restart; on boot the worker reaps tickets whose
recorded pid is dead, marking them `failed:"worker_restart"`.

### Methods

| Method | Params | Result (on `ok:true`) |
| --- | --- | --- |
| `delegate.start` | `prompt` (req), `cwd` (default `$HOME`), `ttl_secs` (alias `timeout_secs`, default 300) | `{ticket_id, started_unix}` — returns immediately, before the delegated work finishes |
| `delegate.poll` | `ticket_id` (alias `ticket`) | `{ticket_id, status, started_unix, finished_unix?, exit_code?, duration_ms?, bytes_written}` — no stdout (fetch via `delegate.result`) |
| `delegate.result` | `ticket_id` | `{ticket_id, status, stdout, exit_code?, duration_ms?, started_unix, finished_unix?}` |
| `delegate.cancel` | `ticket_id` | `{ticket_id, status:"cancelled"}` — SIGTERMs the runner's process group, marks the ticket cancelled, publishes a final `delegate.result.<ticket>` event |
| `delegate.cleanup` | `ticket_id` (optional) | `{ticket_id, cleaned:true}` — removes that ticket's files; always prunes terminal-state tickets older than 24h |
| `delegate.run` | `prompt`, `cwd`, `ttl_secs` | `{stdout, exit_code, duration_ms, cwd}` — **back-compat wrapper**: composes `start` + internal poll-until-terminal. Same envelope as v0.1; the *caller* still blocks on a single reply, but the worker's runner is detached. Prefer the explicit `start`/`poll`/`result` path for new callers to avoid the caller-side wait. |

`status` is one of `pending | running | done | failed | timeout | cancelled`.

Error codes: `missing_prompt`, `bad_cwd`, `spawn_failed` (on `start`);
`missing_ticket`, `unknown_ticket` (on `poll`/`result`/`cancel`).

### Streaming topics

The runner publishes two event streams keyed by ticket (these are plain
pub/sub topics, not RPC req/reply — subscribe to them directly):

- `delegate.progress.<ticket>` — `{ticket, status, pid, ts_unix, from, sid}`.
  Emitted at start, then every 30s while `running`, then once at terminal
  status. Short delegations may only produce the start + terminal events.
- `delegate.result.<ticket>` — the final ticket state envelope, published
  once when the delegation reaches a terminal status (`done`/`failed`/
  `timeout`/`cancelled`). This is the event a caller should block on to be
  notified of completion.

Convention: **stdout travels in a file, not on the bus.** The bus carries
only state envelopes (small, bounded); the delegated process's stdout is
written to `~/.cache/agorabus/tickets/<ticket>.stdout` and fetched via the
`delegate.result` RPC. agorabus documents no message-size cap, so large
outputs must not ride the subscription buffer. This is the canonical
streaming convention for chord — incremental stdout tailing (live `stream.chunk`)
is explicitly deferred.

### Caller pattern (async)

1. Subscribe to `delegate.result.<ticket>` in background **before** sending
   `start` (no inbox — late subscribers miss the event). Optionally also
   subscribe to `delegate.progress.<ticket>` to print progress to stderr.
2. Send `delegate.start` RPC; record the returned `ticket_id`.
3. Block on the `delegate.result.<ticket>` event (or `delegate.poll` in a
   loop with backoff).
4. Fetch full output with a `delegate.result` RPC; exit with the delegated
   process's `exit_code`.
5. Optionally `delegate.cleanup` the ticket when done.

Note: the ticket pattern in `delegate.start`'s reply is the worker-minted
`ticket_id`; subscribe to topics keyed on that exact value.

## Discovery

Use `agorabus peers` for liveness; `methods.list` to probe capabilities. No
central registry.

## Open questions

- **Auth.** Anyone on the local socket can send anything. Fine for a
  single-user laptop; would need signing if the bus ever crossed trust
  boundaries.
- **Long-running calls.** The original RPC shape assumes sub-deadline
  replies. v0.2's async delegation (`delegate.start`/`poll`/`result` +
  `delegate.progress.<ticket>`/`delegate.result.<ticket>` topics) covers
  the long-running case for `claude --print` delegations. A fully generic
  `stream.start` / `stream.chunk` / `stream.end` extension (incremental
  payload streaming for arbitrary methods) is still open.
- **Method namespacing.** `ping` is generic; project-specific methods should
  probably namespace like `autobuilder.slice.status`.

## Changelog

- 2026-05-28 (v0.2): documented the async delegation surface from
  PRD-chord-async-delegate — `delegate.start`/`poll`/`result`/`cancel`/
  `cleanup` methods on `agorabus-worker.sh`, the
  `delegate.progress.<ticket>` and `delegate.result.<ticket>` topics, the
  stdout-in-a-file streaming convention, and the async caller pattern.
  `delegate.run` retained as a back-compat wrapper. Doc-only; the worker
  implementation lives in `proposals/agorabus-worker.draft.sh` pending a
  user-reviewed live install (the file is on the Claude SessionStart path).
- 2026-05-23 (v0.1): initial draft. Convention only; no daemon changes,
  no handler implementations shipped. Future work: a tiny handler skeleton
  any session can spawn at SessionStart (probably `agorabus-rpc-handler.sh`
  alongside the other scratch tools), and a `claude-self` integration so the
  default methods are always available.
