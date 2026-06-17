---
name: use-sudo-make-install
description: Always use `sudo make install` for code-router installs on this server — never bare `make install` or manual file copies.
metadata:
  type: feedback
---

Always use `sudo make install` for code-router installs on this server.

**Why:** This is a system-level install (daemon runs under `code-router` user, binaries in `/usr/local/bin`, config in `/etc/icode`). Running bare `make install` as a normal user triggers the per-user install path, which creates conflicting cruft in `~/.local/bin`, `~/.claude-code-router`, and user-systemd units. Manual `sudo install` of individual files misses router rebuilds, plugin updates, and systemd unit refreshes.

**How to apply:** When asked to install code-router changes, run `sudo make install`. The Makefile dispatches to `install-system` when run as root. Never use bare `make install` or manually copy files.
