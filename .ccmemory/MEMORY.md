## feedback
- [Never run git commands](no-git-commands.md) — Hard rule — do not invoke git for any reason (no log, show, diff, status, blame, etc.) unless the user explicitly asks
- [use-sudo-make-install](use-sudo-make-install.md) — Always use `sudo make install` for code-router installs on this server — never bare `make install` or manual file copies.

## project
- [router is our fork, not vendored](router-is-our-fork.md) — The router/ subdirectory is first-party code, not a vendored upstream snapshot — too divergent to re-sync.

## reference
- [mac-claude-code-env](mac-claude-code-env.md) — Mac Claude Code settings.json env block for hitting the cadev code-router daemon at 10.30.167.5:3456. ANTHROPIC_MODEL not reliable; use Router.aliase…
