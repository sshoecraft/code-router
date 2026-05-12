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
icode --provider X    ──►  daemon (127.0.0.1:3456)
                            │  1. POST /__admin/prime {"provider":"X"}
                            │     daemon (runs as code-router in system
                            │     mode, or as the invoking user) reads
                            │     /etc/icode/config.json, mints OAuth
                            │     token, writes tokens/X.txt
                            │  2. GET /__admin/model?provider=X
                            │     → "gpt-51-prod"
                            └──►  exec claude --model X,gpt-51-prod ...
                                        │
                                        │  (inference goes to the same
                                        │   daemon, which transforms +
                                        │   forwards to the gateway)
                                        ▼
                                  corporate gateway → GPT-5.1 / Claude

   icode --provider Y    ──►  same daemon, different provider, no shared state
                              with the X session

   timer (every 30 min): refresh warm set = default ∪ used-within-2h.
                         GC token files for providers idle beyond 2h.
                         NO daemon restart.
```

The single daemon serves any number of providers concurrently. Each
session picks its own provider via `--provider NAME` (or the configured
default); the router dispatches per-request based on the `model = "name,model"`
field. The `inject-token` plugin and the patched Anthropic transformer each
look up `tokens/<provider.name>.txt` per request (cached 5s in-process) and
set the `Authorization` header. Touching `used/<provider.name>` on each
call signals the timer that this provider is still active, so its token
keeps getting refreshed; unused providers fall out after a 2h idle TTL.

`icode` itself is a thin Python client: it only talks HTTP to the local
daemon (`/__admin/prime`, `/__admin/model`) and then execs `claude`. It
never reads the icode config or holds an OAuth client secret — the daemon
is the only thing with credential access. There is no sudo, no setuid, no
shared writable directory; the trust boundary is enforced by file perms
on `/etc/icode/config.json` (`root:code-router 0640`) and by the admin
endpoints rejecting non-loopback callers.

## Prerequisites

- Linux, or **Windows with WSL2** (the systemd user timer is Linux-only;
  WSL2 is supported and tested)
- `python3` (3.10+ recommended; only stdlib is used) and `openssl` on PATH
- **Node ≥20** on PATH for per-user installs (use nvm, fnm, asdf, NodeSource —
  whatever you already have). System installs use distro `nodejs`/`npm`
  (`check-prereqs-system` enforces ≥20). We don't bundle Node.
- A writable `npm` global prefix for per-user installs. If `npm i -g` would
  need root, configure a user-local prefix once: `npm config set prefix
  $HOME/.local` (and make sure `$HOME/.local/bin` is on `PATH`).
- `~/.config/icode/config.json` populated with a `providers` array
  (single source of truth for `name`, `type`, `client_id`,
  `client_secret`, `token_url`, `token_scope`, `base_url`, `model`,
  plus `deployment_name` + `api_version` for openai providers). Each
  entry must have a unique `name`. `type` is `"openai"` (default) or
  `"anthropic"`.
- `~/.config/icode/default.toml` (optional) naming the provider `icode`
  routes to when no `--provider` is given. Format: a single line
  `provider = "NAME"`. If absent, `icode` with no flag errors out
  rather than guessing.

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

Just `make install`. It dispatches based on who you are:

- **As root (or via `sudo`):** system-wide install. Distro `nodejs` +
  `npm`; ccr in `/usr/local`; dedicated `code-router` system user runs
  the daemon at boot; state under `/var/lib/code-router`; system-systemd
  timer rotates the token. Any user on the box can run `icode`. Right
  for shared servers and CI hosts.
- **As a normal user:** per-user install. Uses your existing Node (≥20);
  router daemon launched lazily by `icode`; state under
  `~/.claude-code-router`; user-systemd timer rotates tokens. Right
  for laptops, dev machines, single-user boxes.

The two modes coexist; `icode` auto-detects which is active per
invocation (per-user wins when one exists for the calling user;
otherwise hits the shared system daemon).

If you really want a per-user install for the root account (rare),
use `make install ALLOW_ROOT_USER_INSTALL=1`. To be explicit, the
underlying targets are `install-system` and `install-user`.

### Per-user install

```bash
git clone <this-repo> ~/src/code-router  # or scp
cd ~/src/code-router
make install                             # config-independent setup

# Create or edit ~/.config/icode/config.json with your provider entries
# (template at ./config.example.json). The file should be mode 0600.
# Optionally: cp ~/.config/icode/default.toml.example ~/.config/icode/default.toml
#             and edit `provider = "..."` to name your default.

make configure                           # CA fetch + initial token mint
```

The flow is split in two phases so the first phase doesn't require
credentials yet:

**Phase 1 (`make install` as a normal user):** does everything that
doesn't depend on your config —

1. Verify prereqs: Node ≥20 on PATH, writable npm global prefix
2. Build **the router** in `router/` (our fork — see `router/PATCHES.md`
   for change history) and install it user-global via `npm i -g`
3. Install `~/.local/bin/icode` (Python) and
   `~/.local/bin/code-router-refresh-token` (Python, used by the timer)
4. Install the `strip-reasoning` and `inject-token` transformer plugins
5. Install + enable `code-router.timer` (refresh every 30 min, on boot)

**Phase 2 (`make configure`, once `~/.config/icode/config.json` is
populated):**

6. Fetch the corporate CA chain from each gateway and store it at
   `~/.local/share/ca-certs/code-router-ca.pem`
7. Mint the initial token and write `~/.claude-code-router/config.json`

`make configure` is safe to re-run any time you add or edit a provider.

After install:

```bash
icode --provider azprod -p "say OK"   # route this session to azprod
icode --provider opus                  # interactive opus session, concurrently
icode                                  # uses default.toml (errors if absent)
icode --list                           # show configured providers
make status                            # timer + daemon health
```

### System install

```bash
git clone <this-repo> /opt/code-router  # or wherever you build from
cd /opt/code-router
sudo make install-system                # config-independent setup

# Create or edit /etc/icode/config.json with your provider entries
# (template at ./config.example.json). The file should be owned
# root:code-router and mode 0640.
# Optionally: sudo cp /etc/icode/default.toml.example /etc/icode/default.toml
#             and edit `provider = "..."` to name the daemon's default.

sudo make configure-system              # CA fetch, mint token, restart daemon
```

After this, any user on the box can run `icode`. The daemon runs at
boot under `code-router.service` and tokens for the warm set (the
configured default plus anything used within the last 2h) are refreshed
by `code-router-refresh.timer` (every 30 min, on boot, with catch-up).

Provider switching in system mode does NOT require sudo and does NOT
restart the daemon: each `icode --provider NAME` invocation routes that
session's requests to NAME; concurrent sessions on other providers are
unaffected. `icode` is a thin Python client — it makes a single localhost
HTTP call to the daemon (`POST /__admin/prime`), and the daemon (running
as `code-router`, the only process with `/etc/icode/config.json` read
access) does the mint. The trust boundary is: anyone with shell access on
the box can ask the daemon to mint a token for any configured provider,
but no user-space process ever sees the OAuth client secret. List
configured providers any time with `icode --list`.

## Uninstall

```bash
make uninstall                # per-user install
sudo make uninstall-system    # system install (leaves /etc/icode + state intact;
                              # prints how to remove those manually)
```

Per-user uninstall removes the user systemd units, `icode`,
`code-router-refresh-token`, the plugins, and the cached CA. Leaves the
router (`ccr`) in place; instructions for removing it are printed.

## Files installed

| Path                                              | Purpose                                    |
|---------------------------------------------------|--------------------------------------------|
| `~/.local/bin/icode`                              | Thin Python launcher (HTTP to local daemon + exec claude) |
| `~/.local/bin/code-router-refresh-token`          | Timer-driven warm-set refresh + GC (Python) |
| `~/.claude-code-router/config.json`               | CCR config (mode 0600)                     |
| `~/.claude-code-router/tokens/<name>.txt`         | Per-provider OAuth bearer tokens (warm set) |
| `~/.claude-code-router/used/<name>`               | Zero-byte marker; mtime = last use         |
| `~/.claude-code-router/plugins/{strip-reasoning,inject-token}.js` | Custom transformers       |
| `~/.local/share/ca-certs/code-router-ca.pem`      | Corporate CA chain                         |
| `~/.config/icode/default.toml`                    | Optional: names the default provider       |
| `~/.config/systemd/user/code-router.{service,timer}` | Token refresh schedule                  |

## Operational notes

- **Concurrent multi-provider routing.** The single daemon (port 3456)
  serves every configured provider simultaneously. `icode --provider X`
  primes X's token via `POST /__admin/prime`, fetches X's model via
  `GET /__admin/model`, then execs `claude --model X,<model>`. The router
  parses `"X,model"` per request and dispatches to provider X. Concurrent
  sessions on other providers are unaffected — no global active-provider
  state, no daemon restart on switch.
- **Default provider.** With no `--provider` flag, `icode` reads
  `~/.config/icode/default.toml` (`provider = "NAME"`) and routes to
  that. If the file doesn't exist, `icode` errors out instead of
  guessing. Set the default by editing the file directly.
- **Warm set / 2h idle TTL.** The timer refreshes tokens for the *warm
  set* = the default provider plus any provider whose `used/<name>`
  marker has been touched within the last 2 hours (the plugins touch it
  on each request). Providers idle longer than 2h get their token files
  GC'd; the next `icode --provider X` re-mints fresh. So unused
  configured providers don't generate ongoing token-mint traffic and
  there's no manual opt-in.
- **Token TTL** is 3600s; timer refreshes every 30min with `Persistent=true`
  so missed runs catch up after a sleep/reboot.
- **List configured providers.** `icode --list`.
- **Model picker.** Claude Code's `/model NAME,MODEL` works inside a
  session: as long as NAME is in the warm set (so a token file exists),
  CCR will route to it. Use `icode --provider NAME` first to prime if
  NAME is cold.
- **Logging is off by default.** Flip `"LOG": true` in the config (or in
  the generator) to enable `~/.claude-code-router/logs/*.log` for
  request/response capture.
- **Don't run `ccr restart` from an arbitrary shell.** The daemon it
  spawns inherits the caller's env, and the corporate CA bundle has to
  be in `NODE_EXTRA_CA_CERTS` for TLS to the gateway to work. `icode`
  itself sets the right env before spawning the daemon; just let it do
  its thing. If you must restart manually: `code-router-refresh-token`
  (per-user, has env baked in) or `systemctl restart code-router.service`
  (system mode).

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

## The router (`router/`)

`router/` is our fork. It started as `@musistudio/claude-code-router` but
we've diverged too far to re-sync — it's first-party code now. Notable
patches (see `router/PATCHES.md` for details):

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
   `ANTHROPIC_TOKEN_DIR` (preferred) or `ANTHROPIC_TOKEN_FILE` (legacy
   single-file). In DIR mode, the transformer looks up
   `<dir>/<provider.name>.txt` per request and touches a sibling
   `used/<provider.name>` marker, so a single daemon serves multiple
   anthropic-typed providers concurrently with rotating tokens. Also
   strips/clamps body fields the corporate gateway's older API rejects
   (`context_management`, `thinking`, `output_config.effort: "xhigh"`).

See `router/PATCHES.md` for the full diagnosis of all three patches.
