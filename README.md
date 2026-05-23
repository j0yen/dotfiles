# dotfiles

Machine config for this laptop. Tracks `~/.claude/` settings + hook scripts;
intentionally narrow scope (the things that, if lost, would meaningfully
break my agent setup).

## Layout

```
.
├── .claude/
│   ├── settings.json            # Claude Code global settings (hooks, permissions, theme)
│   └── scripts/
│       ├── ctrace-session-start.sh    # eBPF session tracer (start)
│       ├── ctrace-session-end.sh      # eBPF session tracer (stop)
│       ├── summarize-ctrace-session.sh
│       └── recall-session-start.sh    # SessionStart hook — emit relevant memories
├── install.sh                   # symlink installer with backups
└── README.md
```

`~/.claude/settings.local.json` is intentionally **not** tracked
(machine-local permission allowlist); it's listed in `.gitignore` and
skipped by `install.sh`.

## Install on a fresh machine

```sh
git clone git@github.com:j0yen/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh --dry-run     # preview
./install.sh               # symlink into ~/
```

`install.sh` is idempotent. If the target file already exists and is *not*
a symlink to the right place, it is renamed to `<name>.bak.<UTC timestamp>`
before the symlink is created.

## Why not chezmoi / yadm / stow?

Three tracked files. The complexity budget for a personal dotfiles repo
should be near zero — one shell script is fewer moving parts than any of
the alternatives.

## Related

- `~/wintermute/recall/hooks/session-start.sh` is the *canonical* source for
  the SessionStart hook script. The copy here in `.claude/scripts/` is the
  installed runtime artifact, kept in sync by hand.
