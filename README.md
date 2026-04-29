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
- `python3` (any 3.x; only stdlib is used) and `openssl` on PATH
- `~/.config/icode/config.json` populated with a `providers` array
  (single source of truth for `name`, `type`, `client_id`,
  `client_secret`, `token_url`, `token_scope`, `base_url`, `model`,
  plus `deployment_name` + `api_version` for openai providers). Each
  entry must have a unique `name`. The first entry is the default
  active provider. `type` is `"openai"` (default) or `"anthropic"`.

  Example:

  ```json
  {
    "providers": [
      {
        "name":            "azprod",
        "type":            "openai",
        "client_id":       "...",
        "client_secret":   "...",
        "token_url":       "https://okta.example.com/oauth2/aus.../v1/token",
        "token_scope":     "...",
        "base_url":        "https://gateway.example.com",
        "deployment_name": "gpt-51-prod",
        "api_version":     "2024-06-01",
        "model":           "gpt-51-prod"
      },
      {
        "name":          "opus",
        "type":          "anthropic",
        "client_id":     "...",
        "client_secret": "...",
        "token_url":     "https://okta.example.com/oauth2/aus.../v1/token",
        "token_scope":   "...",
        "base_url":      "https://gateway.example.com/anthropic",
        "model":         "claude-opus-4-5-..."
      }
    ]
  }
  ```

  File should be mode `0600` (it holds OAuth client secrets).
- `systemd` user instance, *recommended* (default on Linux desktops; WSL2
  needs `systemd=true` in `/etc/wsl.conf`, enabled by default in recent
  Windows 11 / WSL releases). On headless servers you may also need
  `sudo loginctl enable-linger $(whoami)` so the user systemd instance
  runs without an interactive session. If the user systemd bus isn't
  reachable at install time, the timer simply isn't enabled and you'll
  need to run `make refresh` manually before each session (or any time
  the OAuth token expires, ~1h).

## Install

There are two install modes — pick one (or run both, they coexist):

- **Per-user install** (`make install`, no sudo). nvm/Node 22 user-local;
  CCR daemon launched lazily by `ccr code`; state under
  `~/.claude-code-router`; user-systemd timer rotates the token. Right
  for laptops, dev machines, single-user boxes.
- **System install** (`sudo make install-system`). Distro `nodejs` +
  `npm`; ccr in `/usr/local`; dedicated `code-router` system user runs
  the daemon at boot; state under `/var/lib/code-router`; system-systemd
  timer rotates the token. Any user on the box can run `icode`. Right
  for shared servers and CI hosts.

icode auto-detects which is active per invocation (per-user wins when
present; otherwise hits the shared system daemon).

### Per-user install

```bash
git clone <this-repo> ~/src/code-router  # or scp
cd ~/src/code-router
make install                                       # config-independent setup

# Now create your provider config (or edit if it already exists):
mkdir -p ~/.config/icode
cp config.example.json ~/.config/icode/config.json
chmod 600 ~/.config/icode/config.json
$EDITOR ~/.config/icode/config.json                # fill in the REPLACE_ME values

make configure                                     # CA fetch + initial token mint
```

`make install` is split in two phases so the first phase doesn't
require credentials yet:

**Phase 1 (`make install`):** does everything that doesn't depend on
your config —

1. Install **nvm** + **Node 22 LTS** if missing (user-local, no root)
2. Build the **vendored claude-code-router** in `router/` (patched fork --
   see `router/PATCHES.md`) and install it user-global via `npm i -g`
3. Install `~/.local/bin/icode` and `~/.local/bin/code-router-refresh-token`
   (same dir Claude Code uses; on PATH by default on modern Linux)
4. Install the `strip-reasoning` and `inject-token` custom CCR transformers
5. Install + enable `code-router.timer` (refresh every 30 min, on boot)

**Phase 2 (`make configure`, once `~/.config/icode/config.json` is
populated):**

6. Fetch the corporate CA chain from each gateway and store it at
   `~/.local/share/ca-certs/code-router-ca.pem`
7. Mint the initial token and write `~/.claude-code-router/config.json`

`make configure` is safe to re-run any time you add or edit a provider.

After install:

```bash
icode -p "say OK"          # one-shot
icode                      # interactive
make status                # timer + daemon health
```

### System install

```bash
git clone <this-repo> /opt/code-router  # or wherever you build from
cd /opt/code-router
sudo make install-system                # config-independent setup

# Now create the shared provider config:
sudo cp config.example.json /etc/icode/config.json
sudo chown root:code-router /etc/icode/config.json
sudo chmod 0640 /etc/icode/config.json
sudo $EDITOR /etc/icode/config.json     # fill in the REPLACE_ME values

sudo make configure-system              # CA fetch, mint token, restart daemon
```

After this, any user on the box can run `icode`. The daemon runs at
boot under `code-router.service` and the token is refreshed by
`code-router-refresh.timer` (every 30 min, on boot, with catch-up).

Provider switching in system mode requires sudo:
```bash
sudo /usr/local/bin/code-router-refresh-token --provider NAME
sudo systemctl restart code-router.service
```
…or just `icode --provider NAME` will prompt for sudo and do both.

## Uninstall

```bash
make uninstall                # per-user install
sudo make uninstall-system    # system install (leaves /etc/icode + state intact;
                              # prints how to remove those manually)
```

Per-user uninstall removes the user systemd units, `icode`,
`code-router-refresh-token`, the plugins, and the cached CA. Leaves
nvm/Node 22/CCR in place (instructions to remove them are printed).

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
- **Switching providers.** Add multiple entries to the `providers` array
  in `~/.config/icode/config.json` (each needs a unique `name`). The
  first is the default.
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

The target host needs `~/.config/icode/config.json` populated first
(or override the path with `ICODE_CFG=/some/other/config.json make install`).

## Why not just point Claude Code straight at the gateway?

Claude Code speaks the Anthropic Messages API. The gateway speaks OpenAI
Chat Completions. CCR translates between them. The custom
`strip-reasoning` transformer + the built-in `maxcompletiontokens`
transformer paper over two GPT-5-specific quirks some gateways reject.

## Why a vendored router?

`router/` is a patched copy of `@musistudio/claude-code-router` with three
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
3. **Anthropic transformer auth + body cleanup** -- gated on
   `ANTHROPIC_TOKEN_FILE`, the transformer reads the live OAuth bearer
   token from disk per request (so anthropic providers get token
   rotation without a daemon restart) and strips/clamps body fields the
   corporate gateway's older API rejects (`context_management`,
   `thinking`, `output_config.effort: "xhigh"`).

See `router/PATCHES.md` for the full diagnosis of all three patches.
