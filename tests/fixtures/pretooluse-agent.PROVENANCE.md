# Real PreToolUse Agent payloads (A1300 AC2)
Captured 2026-11-12 8:56 PM PST on carbon by ctl through the supported launcher fable-launch.sh (account-lane, account jyen.pm, model claude-haiku-5-5, effort low), client Claude Code 2.1.293, with an isolated --settings file (tee hook on PreToolUse matcher Agent, scratch dir ~/.cache/ctl-w4/payload-capture/work, --setting-sources local) that wrote the hook stdin verbatim and denied the spawn (no subagent ran). No live hook edit.
- cap-plan.json (--permission-mode plan) sha256 86012436ca00dd1e3c03d225377f88e061fc72fb38defa6835dffc2f96e32851
- cap-default.json (--permission-mode default) sha256 1abc0d29b14da9c6d89d6a6cabe9fa0ea66ccaab17593a9f5695734ac5f31f85
Unmodified client output; fields: session_id, transcript_path, cwd, prompt_id, permission_mode, effort{level}, hook_event_name, tool_name, tool_input{description,prompt,subagent_type,model}, tool_use_id. No secrets present.
