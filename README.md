# code-router

Run **Claude Code** (Anthropic's CLI) against an **OAuth-gated,
OpenAI-compatible Azure-OpenAI gateway**, with token refresh handled
automatically by a systemd user timer. Provides the `icode` launcher.

If you just want to point Claude Code at a static-API-key endpoint like
OpenRouter, Groq, or Together, you don't need this project -- use
[`claude-code-router`](https://github.com/musistudio/claude-code-router)
directly. This repo exists specifically to handle the case where the
gateway requires a short-lived OAuth bearer token that has to be rotated
without disrupting in-flight sessions.

Architecture:

```
                                            +-------------------------+
   icode  ───►  CCR daemon  ─── per req ──► Azure-OpenAI gateway ───► GPT-5.1
                ▲      │
                │      │  transformer chain:
                │      │    openai (route)
                │      │    strip-reasoning   (drop responses-API field)
                │      │    maxcompletiontokens  (rename for GPT-5.1)
                │      │    inject-token      (read ~/.claude-code-router/token.txt
                │      │                       per req, set Authorization: Bearer)
                │      │
   code-router.timer (every 30 min, systemd user)
                │
                └── mints fresh OAuth token, atomically writes token.txt
                    (NO daemon restart -- in-flight sessions are not disrupted)
```

The daemon stays up across token rotations. The `inject-token` plugin
reads `token.txt` per outbound request (cached 5s in-process) and overrides
the `Authorization` header. Concurrent `icode` sessions all share the same
daemon; nothing kills them.

## Prerequisites

- Linux, or **Windows with WSL2** (shell scripts and systemd user timer
  are Linux-only; running under WSL2 is supported and tested)
- `jq`, `yq` (the Go variant from <https://github.com/mikefarah/yq>,
  needed for TOML parsing), `curl`, `openssl` on PATH
- `~/.config/icode/config.toml` populated with one or more `[[providers]]`
  entries (single source of truth for `name`, `client_id`,
  `client_secret`, `token_url`, `token_scope`, `base_url`,
  `deployment_name`, `api_version`, `model`). Each entry must have a
  unique `name`. The first entry is the default active provider.

  Example:

  ```toml
  [[providers]]
  name             = "azprod"
  client_id        = "..."
  client_secret    = "..."
  token_url        = "https://okta.example.com/oauth2/aus.../v1/token"
  token_scope      = "..."
  base_url         = "https://gateway.example.com"
  deployment_name  = "gpt-51-prod"
  api_version      = "2024-08-01-preview"
  model            = "gpt-5.1"

  [[providers]]
  name             = "azuat"
  # ... same shape, different values
  ```

  File should be mode `0600` (it holds OAuth client secrets).
- `systemd` user instance (default on Linux desktops/servers; WSL2 needs
  `systemd=true` in `/etc/wsl.conf` — enabled by default in recent
  Windows 11 / WSL releases)

## Install

```bash
git clone <this-repo> ~/src/code-router  # or scp
cd ~/src/code-router
make install
```

The Makefile will:

1. Install **nvm** + **Node 22 LTS** if missing (user-local, no root)
2. Build the **vendored claude-code-router** in `router/` (patched fork --
   see `router/RESTART-FIX.md`) and install it user-global via `npm i -g`
3. Fetch the corporate CA chain from the gateway and store it at
   `~/.local/share/ca-certs/code-router-ca.pem`
4. Install `~/.local/bin/icode` and `~/.local/bin/code-router-refresh-token`
   (same dir Claude Code uses; on PATH by default on modern Linux)
5. Install the `strip-reasoning` custom CCR transformer
6. Install + enable `code-router.timer` (refresh every 30 min, on boot)
7. Mint the initial token and write `~/.claude-code-router/config.json`

After install:

```bash
icode -p "say OK"          # one-shot
icode                      # interactive
make status                # timer + daemon health
```

## Uninstall

```bash
make uninstall
```

Removes the systemd units, `icode`, `code-router-refresh-token`, the
plugin, and the cached CA. Leaves nvm/Node 22/CCR in place (instructions
to remove them are printed).

## Files installed

| Path                                              | Purpose                                    |
|---------------------------------------------------|--------------------------------------------|
| `~/.local/bin/icode`                              | Claude Code launcher (sources nvm + execs ccr) |
| `~/.local/bin/code-router-refresh-token`          | Token mint + config write + daemon restart |
| `~/.claude-code-router/config.json`               | CCR config (mode 0600, contains live token)|
| `~/.claude-code-router/plugins/strip-reasoning.js`| Custom transformer                         |
| `~/.local/share/ca-certs/code-router-ca.pem`      | Corporate CA chain                         |
| `~/.config/systemd/user/code-router.{service,timer}` | Token refresh schedule                  |

## Operational notes

- **Concurrent sessions** share the single CCR daemon (port 3456). No race
  on `icode` startup.
- **Token TTL** is 3600s; timer refreshes every 30min with `Persistent=true`
  so missed runs catch up after a sleep/reboot.
- **Restart blip:** during the ~1 second daemon restart, an in-flight
  request may fail. Claude Code retries.
- **Switching providers.** List multiple `[[providers]]` blocks in
  `~/.config/icode/config.toml` (each needs a unique `name`). The first
  is the default.
  Switch with either:
  - `icode --provider NAME ...` -- consumed by icode, not forwarded
  - `code-router-refresh-token --provider NAME` -- then run `icode`
  Switching re-mints the OAuth token for the chosen provider, writes it
  to `token.txt`, and rewrites `Router.default` in the CCR config. The
  choice persists across timer-driven token refreshes (the timer runs
  no-args and preserves the active selection).
  List available names: `code-router-refresh-token --list`.
- **Model picker is cosmetic.** Claude Code's `/model` command shows
  Anthropic model names; all configured providers are listed in
  `Providers[]` so `/model NAME,MODEL` works for visibility, but only
  the *active* provider has a fresh token in `token.txt`. To genuinely
  switch, use `--provider`.
- **Logging is off by default.** Flip `"LOG": true` in the config (or in
  the generator) to enable `~/.claude-code-router/logs/*.log` for
  request/response capture.
- **Don't run `ccr restart` from an arbitrary shell.** The daemon it
  spawns inherits the caller's env, and the corporate CA bundle has to
  be in `NODE_EXTRA_CA_CERTS` for TLS to the upstream gateway to work.
  Use `~/.local/bin/code-router-refresh-token` (or just let the timer fire) --
  it sets the env before calling `ccr restart`.

## Porting to another node

```bash
scp -r ~/src/code-router target-host:~/src/
ssh target-host
cd ~/src/code-router
make install
```

The target host needs `~/.config/icode/config.toml` populated first
(or override the path with `ICODE_CFG=/some/other/config.toml make install`).

## Why not just point Claude Code straight at the gateway?

Claude Code speaks the Anthropic Messages API. The gateway speaks OpenAI
Chat Completions. CCR translates between them. The custom
`strip-reasoning` transformer + the built-in `maxcompletiontokens`
transformer paper over two GPT-5-specific quirks some gateways reject.

## Why a vendored router?

`router/` is a patched copy of `@musistudio/claude-code-router` with two
local fixes:

1. **`restartService` race + silent failure** -- upstream sends SIGTERM
   and immediately spawns a new daemon, racing the old one for port
   3456. EADDRINUSE is swallowed by `stdio: "ignore"` and "success" is
   printed regardless. Without the fix, every timer-driven token
   refresh would leave the daemon dead.
2. **`executeCodeCommand` arg mangling** -- upstream skips minimist's
   positional `_` bucket (drops `-p PROMPT` payloads) and uses
   `shell: true` with packed tokens, so any prompt containing shell
   metacharacters (`$`, backticks, semicolons) gets re-interpreted by
   `/bin/sh`. Multi-line markdown prompts blow up.

See `router/RESTART-FIX.md` for the full diagnosis of both.
