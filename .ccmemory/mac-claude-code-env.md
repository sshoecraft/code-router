---
name: mac-claude-code-env
description: Mac Claude Code settings.json env block for hitting the cadev code-router daemon at 10.30.167.5:3456. ANTHROPIC_MODEL not reliable; use Router.aliase…
metadata:
  type: reference
tags: [icode, claude-code, mac, config, remote-access, aliases]
---

Mac Claude Code `settings.json` needs these env entries to talk to the cadev daemon:

```json
{ "name": "ANTHROPIC_BASE_URL",   "value": "http://10.30.167.5:3456" }
{ "name": "ANTHROPIC_AUTH_TOKEN", "value": "sk-ZtjiG7QyQJEsIbRh2mSM9DQfqVJvrcpp" }
```

**Don't bother with `ANTHROPIC_MODEL`** — confirmed it doesn't override Claude Code's bundled default-model selection on the Mac (the request still went out as `claude-opus-4-8` even after a full relaunch). Handle this server-side instead.

**Server-side aliasing (the real fix):** `Router.aliases` in `/var/lib/code-router/.claude-code-router/config.json` maps Claude Code's built-in model names to a configured provider. Patch 4 in `router/PATCHES.md` documents the validator change. Current entries:

```json
"Router": {
  "aliases": {
    "claude-opus-4-8":   "opus",
    "claude-sonnet-4-6": "opus",
    "claude-haiku-4-5":  "opus"
  }
}
```

**Why the alias map exists:** commit `b9bc94d` added strict model validation that 404s unknown names. Pre-`b9bc94d`, those names fell through to `Router.default` and silently worked from Mac Claude Code; post-`b9bc94d` they broke. `Router.aliases` restores the silent-fallthrough behavior for known Claude Code defaults without weakening typo detection for the `icode` path.

**How to apply:** When a new Claude Code release ships with a new default model name (e.g. `claude-opus-5-0`), add it to `Router.aliases` and `sudo systemctl restart code-router.service` — no rebuild needed since aliases live in config.
