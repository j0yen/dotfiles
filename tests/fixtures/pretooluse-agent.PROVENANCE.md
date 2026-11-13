# Real PreToolUse Agent payloads (A1300 AC2)
Captured 2026-11-12 8:56 PM PST on carbon by ctl through the supported launcher fable-launch.sh (account-lane, account jyen.pm, model claude-haiku-5-5, effort low), client Claude Code 2.1.293, with an isolated --settings file (tee hook on PreToolUse matcher Agent, scratch dir ~/.cache/ctl-w4/payload-capture/work, --setting-sources local) that wrote the hook stdin verbatim and denied the spawn (no subagent ran). No live hook edit.
- cap-plan.json (--permission-mode plan) sha256 86012436ca00dd1e3c03d225377f88e061fc72fb38defa6835dffc2f96e32851
- cap-default.json (--permission-mode default) sha256 1abc0d29b14da9c6d89d6a6cabe9fa0ea66ccaab17593a9f5695734ac5f31f85
Unmodified client output; fields: session_id, transcript_path, cwd, prompt_id, permission_mode, effort{level}, hook_event_name, tool_name, tool_input{description,prompt,subagent_type,model}, tool_use_id. No secrets present.

## Effort precedence source
Claude Code docs https://code.claude.com/docs/en/sub-agents, read 2026-11-12 ~9:35 PM PST by rb (WebFetch), client 2.1.293 on carbon and RB. Quotes:
- frontmatter `effort`: "Effort level when this subagent is active. Overrides the session effort level, but not the CLAUDE_CODE_EFFORT_LEVEL environment variable."
- "When you ask Claude to run a non-fork subagent at a specific effort level, it can also pass an effort parameter for that invocation. The parameter overrides the effort field and stays in effect when the subagent is resumed. The CLAUDE_CODE_EFFORT_LEVEL environment variable takes precedence over both. The per-invocation parameter requires Claude Code v2.1.292 or later."
- "On the main conversation's model, the subagent runs at the level you pick in the session, such as with /effort, or set with --effort. On another model, that level doesn't apply."
- location priority: managed 1, --agents CLI 2, .claude/agents/ 3, ~/.claude/agents/ 4, plugin 5; "When multiple subagents share the same name, Claude Code uses the one from the higher-priority location."
Guard order implemented: tool_input.effort > project agent file > user agent file > top-level effort.level.
Not covered by the guard (recorded gaps): CLAUDE_CODE_EFFORT_LEVEL env (top precedence per docs; not in the hook payload), managed and --agents CLI definitions, plugin agents, nested .claude/agents closest-to-cwd lookup, files whose frontmatter `name` differs from the filename, forks.

## Inheritance premise (ASSUMPTION, not captured)
The guard treats top-level effort.level as the subagent's effort when no parameter or definition effort exists. Docs say that holds only when the subagent runs on the main conversation's model; on another model the session level does not apply and the docs name no default. Falsifier: run a session at effort low, spawn general-purpose with no effort parameter (and once with a model different from the session's), and capture the subagent's own PreToolUse Bash hook payload; its effort.level (or absence) confirms or refutes the premise. Not yet run.
