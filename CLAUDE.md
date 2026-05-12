# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A wrapper that lets Claude Code talk to an **OAuth-gated, OpenAI-compatible (or
Anthropic-compatible) Azure-OpenAI gateway**. It exists specifically to solve
the case where the gateway requires a short-lived OAuth bearer token that must
be rotated without disrupting in-flight sessions. If the upstream just needs a
static API key, use [`claude-code-router`](https://github.com/musistudio/claude-code-router)
directly — this project would be over-engineered for that.

The user-facing entry point is the `icode` launcher.

## Common commands

There is no test suite. Everything is driven through the Makefile.

```bash
make install               # per-user (or system, if uid 0) — dispatches on uid
make install-user          # explicit per-user install
sudo make install-system   # explicit system-wide install

make configure             # phase-2: CA fetch + initial token mint (per-user)
sudo make configure-system # phase-2 for system install

make refresh               # manually mint a token (per-user)
make status                # systemd timer + daemon health (per-user)

make uninstall             # per-user uninstall
sudo make uninstall-system # system uninstall (leaves /etc/icode + state intact)
```

`install` is intentionally split from `configure` so phase 1 can run before
the user has populated `~/.config/icode/config.json` with credentials.
`make configure` is safe to re-run after editing the config.

For development on the router, work inside `router/` with pnpm — see
`router/CLAUDE.md` and `router/package.json` for the monorepo build targets
(`pnpm build`, `pnpm dev:cli`, etc.). `make install-router` builds it and
`npm i -g`'s it from local sources.

## Architecture

```
icode --provider X ──► daemon (127.0.0.1:3456)
                          │   1. POST /__admin/prime {"provider":"X"}
                          │      daemon (running as code-router)
                          │      reads /etc/icode/config.json,
                          │      mints OAuth token, writes
                          │      tokens/X.txt, touches used/X
                          │   2. GET  /__admin/model?provider=X
                          │      returns plaintext "gpt-51-prod"
                          │
                          └─►  exec claude --model X,gpt-51-prod ...
                                       │
                                       │  (claude-code now talks to the
                                       │   same daemon for inference)
                                       ▼
                          ┌─────────────────────────────────────┐
                          │  CCR daemon                         │
                          │   openai providers (chain):          │
                          │     openai → strip-reasoning →       │
                          │     maxcompletiontokens →            │
                          │     inject-token                     │
                          │     (reads tokens/X.txt,             │
                          │      touches used/X per request)     │
                          │   anthropic providers (bypass):      │
                          │     patched Anthropic transformer    │
                          │     (same reads & touches)           │
                          └─────────────────────────────────────┘
                                       │
                                       ▼
                              corporate gateway → GPT-5.1 / Claude

   timer (every 30 min): refresh "warm set" = default ∪ used-in-2h.
                         GC token files for providers idle beyond 2h.
                         NO daemon restart, ever.
```

The daemon serves any number of providers concurrently. `icode` is a thin
Python client that only ever talks HTTP to `127.0.0.1:3456` — it never reads
the icode config or holds an OAuth client secret itself. The daemon (running
as user `code-router` in system mode, or as the invoking user in per-user
mode) is the only thing with credential access. Concurrent sessions on
different providers are independent — no global active-provider state.

### Two install modes that coexist

The same `make install` works for both; dispatch is by uid (see top of
`Makefile`). The two modes use different paths and a different runtime story,
but a single host can have both, and `bin/icode` auto-detects which one is
active per invocation:

|                       | per-user                                  | system                                          |
|-----------------------|-------------------------------------------|-------------------------------------------------|
| Trigger               | non-root `make install`                   | root `make install` (or `make install-system`)  |
| Node                  | already on PATH (user-installed, any way) | distro `nodejs`/`npm` (must be ≥20)             |
| Router CLI            | npm-global for the user                   | npm-global system-wide                          |
| Daemon                | spawned lazily by `icode` (`ccr start`)   | runs at boot under `code-router.service`        |
| Config                | `~/.config/icode/config.json` (0600)      | `/etc/icode/config.json` (root:code-router 0640)|
| Default file          | `~/.config/icode/default.toml`            | `/etc/icode/default.toml`                       |
| State                 | `~/.claude-code-router/`                  | `/var/lib/code-router/.claude-code-router/`     |
| Token store           | `~/.claude-code-router/tokens/<name>.txt`, `used/<name>` | same paths under `/var/lib/code-router/.claude-code-router/` |
| Token timer           | user-systemd `code-router.timer`          | system `code-router-refresh.timer`              |
| Plugins / CA          | `~/.claude-code-router/plugins/`, `~/.local/share/ca-certs/` | `/usr/local/share/code-router/{plugins,ca.pem}` |
| `icode --provider`    | HTTP to `127.0.0.1:3456/__admin/prime`    | same HTTP call, daemon already running          |

`bin/icode` decides mode by its script directory — `/usr/local/bin` → system,
anything else → per-user. This is deliberate so leftover state in `$HOME`
doesn't confuse which copy the user actually ran.

### Privilege boundary

The daemon is the only process that ever reads the icode config or holds
an OAuth client secret. `icode` is a thin Python client that only talks
HTTP to `127.0.0.1:3456`. This is enforced by:

- File perms: `/etc/icode/config.json` is `root:code-router 0640` in
  system mode. Only the daemon (running as `code-router`) can read it.
- Admin endpoint scope: `POST /__admin/prime` and `GET /__admin/model`
  reject any caller that isn't on a loopback address. The daemon listens
  on `127.0.0.1` only.
- No sudo, no setuid, no shared writable directories. If `/etc/icode/`
  perms get widened by mistake, the secret stays out of the user-space
  process tree because nothing in user-space ever needs to read it.

### Token rotation without daemon restart, per-provider

The whole reason the project exists, generalized to N providers:

- **openai providers** route through CCR's transformer chain.
  `plugins/inject-token.js` runs *per outbound request*, looks up
  `tokens/<provider.name>.txt` (5s in-process cache keyed by provider name),
  overrides the `Authorization` header, and touches `used/<provider.name>`
  so the timer keeps that provider warm. CCR config carries a
  `PLACEHOLDER_OVERRIDDEN_BY_INJECT_TOKEN` api_key for every provider.
- **anthropic providers** use CCR's "bypass mode" (single-element
  `["Anthropic"]` chain). The patched Anthropic transformer's `auth()`
  reads `${ANTHROPIC_TOKEN_DIR}/${provider.name}.txt` per request and
  touches the sibling `used/<provider.name>` marker. Gated on the env var;
  unset → behavior matches non-patched.

Either path: token files for the *warm set* (default + anything touched
within the last 2h) are atomically rewritten by the timer via tempfile
+rename → next request picks up the new token. Concurrent sessions on
different providers are independent; no restart kills any of them.

The warm-set definition is the key trick. The two plugins touch
`used/<name>` on every request; `code-router-refresh-token` (no args) scans
that directory + the default file, refreshes tokens for everything inside
the 2h window, and GCs everything outside. Adding a provider to the config
and using it once is enough to bring it into rotation; ignoring it for 2h
takes it out. No manual opt-in / opt-out.

Two places mint tokens, sharing the same OAuth client_credentials flow:

- `bin/code-router-refresh-token` (Python, stdlib-only). Runs from the
  systemd refresh-timer for the periodic warm-set sweep + GC.
- The daemon's admin endpoint `POST /__admin/prime`, called by `icode` at
  session launch. Implemented in TypeScript inside the router
  (`router/packages/core/src/admin/index.ts`), reuses the same env-driven
  path resolution.

The two paths write to the same `tokens/` directory; either is sufficient
on its own. They coexist because the timer keeps existing providers warm
across reboots/lid-closes, while the admin endpoint handles cold starts
("first time using provider X today").

### The router (`router/`)

`router/` is our own fork. It started as `@musistudio/claude-code-router`,
but we've diverged too far to re-sync — treat it as first-party code, not
a vendored snapshot. Refactor freely; there's no upstream cost to weigh.

Notable patches (see `router/PATCHES.md` for the full history):

1. `restartService()` — fixes a race where SIGTERM + immediate respawn races
   the old process for port 3456 and leaves the daemon silently dead.
2. `executeCodeCommand()` — fixes positional-arg drop (loses `-p PROMPT`)
   and shell-metachar mangling (multi-line markdown prompts blow up).
3. Anthropic transformer `auth()` — per-request token lookup from
   `${ANTHROPIC_TOKEN_DIR}/${provider.name}.txt` (or legacy
   `ANTHROPIC_TOKEN_FILE`), strips/clamps body fields the corporate
   gateway rejects (`context_management`, `thinking`, `output_config.effort: "xhigh"`).

The router is a pnpm monorepo (cli/server/shared/ui/core). It has its own
`router/CLAUDE.md` documenting the routing/transformer architecture.

### Provider config schema

Single source of truth: `~/.config/icode/config.json` (or `/etc/icode/config.json`).
Each provider entry needs `name`, `type` (`"openai"` default, or `"anthropic"`),
`client_id`, `client_secret`, `token_url`, `token_scope`, `base_url`, `model`,
plus `deployment_name` + `api_version` for openai providers. Template at
`config.example.json`.

The default provider — used by `icode` with no `--provider` flag — is named in
a sibling `default.toml`: one line, `provider = "NAME"`. If the file doesn't
exist and the user doesn't pass `--provider`, `icode` errors out rather than
guessing. Set the default by editing the file directly (no CLI command).
Template at `default.toml.example`.

Daemon admin endpoints (used by `icode`):
- `POST /__admin/prime` body `{"provider": "NAME"}` — mint NAME's token,
  write `tokens/NAME.txt`, touch `used/NAME`.
- `GET /__admin/model?provider=NAME` — plaintext model string.
- `GET /__admin/providers` — list configured providers (used by `--list`).

`code-router-refresh-token` (Python, used by the systemd refresh timer):
- `--provider NAME`: same as the admin endpoint, available for ad-hoc
  CLI use or testing.
- `--print-model NAME` / `--list`: legacy CLI variants.
- no args (timer): refresh tokens for the warm set, GC the rest.

## Things that have bitten people

- **Don't run `ccr restart` from an arbitrary shell.** The daemon it spawns
  inherits the caller's env, and `NODE_EXTRA_CA_CERTS` must be set for TLS to
  the corporate gateway. Use `bin/code-router-refresh-token` (or let the timer
  fire) — it sets env before calling `ccr restart`. The systemd units also
  set `NODE_EXTRA_CA_CERTS` and `ANTHROPIC_TOKEN_DIR`.
- **`/model NAME,MODEL` works only if NAME is in the warm set.** All
  configured providers appear in `Providers[]`, but only warm ones have a
  token on disk. Use `icode --provider NAME` first to prime a cold provider,
  then `/model` within that session can switch to other warm providers.
- **No sudoers drop-in or setuid binary.** `icode` is a Python client that
  only talks HTTP to `127.0.0.1:3456`. The privilege boundary is enforced
  by the file perms on `/etc/icode/config.json` (only the daemon can read
  it) and by the admin endpoints rejecting non-loopback callers. If you
  see a `/etc/sudoers.d/code-router` on a host, it's from an old install
  and can be removed.
- **Debian 12 stock nodejs is 18 and too old** for the router (uses
  Node 20+ globals like `File`). `check-prereqs-system` enforces ≥20.
- **Logging is off by default.** Flip `"LOG": true` in
  `~/.claude-code-router/config.json` for request/response capture under
  `~/.claude-code-router/logs/`.
