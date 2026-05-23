# dotfiles

**Holding pen for the `claude-self` cluster** — drafts that the
autobuilder pipeline owns and that have not yet been wired into
`~/.claude/`. Kept private (this repo) until autobuilder ships v0.2 and
binds them.

Everything else that was previously here (settings.json, hook scripts,
scratch CLIs) has moved to [`~/wintermute/dotfiles/`](https://github.com/j0yen/wintermute/tree/master/dotfiles).

## Layout

```
.
├── .claude/
│   ├── CLAUDE_SELF.md           # draft self-preferences (PRD-claude-self)
│   ├── CLAUDE_SELF.default.md   # draft template (default-restore source)
│   └── scripts/
│       └── claude-self-start.sh # SessionStart hook draft, NOT yet wired
├── .local/
│   └── bin/
│       └── claude-self          # CLI to manage CLAUDE_SELF.md (symlinked into ~/.local/bin/)
├── install.sh                   # symlink installer; skip_pattern excludes the entire claude-self cluster
└── README.md
```

## Why nothing here is symlinked yet

`install.sh`'s `skip_pattern` excludes every file in this repo. Running
`./install.sh` is currently a no-op by design — autobuilder is supposed
to land `PRD-claude-self.md` (in `~/projects/autobuilder/`) before the
drafts get bound to live SessionStart behavior. The `claude-self` CLI
itself is the one exception: it's already symlinked into `~/.local/bin/`
manually (it can lint and edit the live file even when there isn't one
yet).

When autobuilder is ready, the cutover is:

1. Remove the claude-self entries from `install.sh`'s `skip_pattern`.
2. Run `./install.sh` — `CLAUDE_SELF.md`, `CLAUDE_SELF.default.md`, and
   `claude-self-start.sh` get symlinked into `~/.claude/`.
3. Add `claude-self-start.sh` to the SessionStart hooks list in
   `~/wintermute/dotfiles/.claude/settings.json`.
4. Pop stack item #2 ("wire claude-self when autobuilder is ready").
