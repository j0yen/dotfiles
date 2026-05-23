# dotfiles

**Private holding repo for the `claude-self` cluster** —
`~/.claude/CLAUDE_SELF.md`, its default template, the SessionStart hook
that surfaces it into every session, and the `claude-self` CLI that
lints / edits / restores the live file.

Everything else that was previously here (`settings.json`, ctrace/recall/scratch-tools
hook scripts, the four other scratch CLIs) lives in [`~/wintermute/dotfiles/`](https://github.com/j0yen/wintermute/tree/master/dotfiles).
Two repos because wintermute is public and these files carry
machine-personal content (voice, values, corrections — see PRD-claude-self).

## Layout

```
.
├── .claude/
│   ├── CLAUDE_SELF.md           # live self-preferences (symlinked into ~/.claude/)
│   ├── CLAUDE_SELF.default.md   # default template (default-restore source)
│   └── scripts/
│       └── claude-self-start.sh # SessionStart hook — surfaces CLAUDE_SELF.md
├── .local/
│   └── bin/
│       └── claude-self          # CLI: show / edit / lint / log / diff / default-restore
├── install.sh                   # symlink installer with backups
└── README.md
```

## Wiring (active as of 2026-05-22)

All four files are symlinked into `~/` via `install.sh`:

| Source | Target |
| --- | --- |
| `.claude/CLAUDE_SELF.md` | `~/.claude/CLAUDE_SELF.md` |
| `.claude/CLAUDE_SELF.default.md` | `~/.claude/CLAUDE_SELF.default.md` |
| `.claude/scripts/claude-self-start.sh` | `~/.claude/scripts/claude-self-start.sh` |
| `.local/bin/claude-self` | `~/.local/bin/claude-self` |

The hook is registered as the 5th SessionStart entry in
`~/wintermute/dotfiles/.claude/settings.json` (commit `6fa3ba0`). It
runs `claude-self lint --quiet` against the live file; on lint failure
it emits a `LINT FAILED` marker but still ships the content so a
malformed file isn't silently invisible.

## Install on a fresh machine

```sh
git clone git@github.com:j0yen/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh --dry-run     # preview
./install.sh               # symlink into ~/
```

Then ensure `~/wintermute/dotfiles/install.sh` has also been run so
`settings.json` is in place with the SessionStart hook registered.
