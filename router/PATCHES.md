# Router (router/) — change history

This directory is our own fork. It started life as a snapshot of
`https://github.com/musistudio/claude-code-router`, but we've made enough
local changes that it should be treated as first-party code: refactor
freely, no "upstream-divergence cost" to weigh. This file documents the
notable patches that motivated the divergence, for archaeology purposes.
The changes are baked into the source — no `.patch` files to apply.

## Patch 1 — `packages/cli/src/utils/index.ts` :: `restartService()`

**Upstream behavior**

```js
process.kill(pid);                // SIGTERM
spawn("node", [cliPath, "start"], { detached: true, stdio: "ignore" });
console.log("✅ Service started successfully in the background.");
```

The new spawn races the old process for the listen socket on port 3456.
The old process hasn't released it yet, so the new one hits `EADDRINUSE`
and crashes — but `stdio: "ignore"` swallows the error and the function
prints success regardless. Net effect: `ccr restart` reports success but
leaves the daemon dead, until the next `ccr code` invocation re-spawns
via a different code path.

**Patched behavior**

1. Capture the old PID before sending SIGTERM.
2. Poll `isProcessRunning(oldPid)` for up to 5s; SIGKILL if it lingers.
3. Spawn the new daemon.
4. Poll `isServiceRunning()` for up to 10s. On success, print and return.
   On timeout, throw — the caller (and our systemd refresh script) sees
   the failure instead of a silently dead daemon.

## Patch 2 — `packages/cli/src/utils/codeCommand.ts` :: `executeCodeCommand()`

**Upstream behavior**

```js
const argsObj = minimist(args)
const argsArr = []
for (const [k, v] of Object.entries(argsObj)) {
  if (k !== '_' && argsObj[k]) {                           // <-- skips `_`
    argsArr.push(`${prefix}${k} ${JSON.stringify(v)}`);    // <-- packed token
  }
}
spawn(claudePath, argsArr, { shell: true });               // <-- shell re-tokenizes
```

Two bugs in one block:

1. The loop **skips minimist's `_` bucket**, which is where positional
   arguments live. Calls like `ccr code -p PROMPT` silently drop `PROMPT`,
   then claude errors: *"Input must be provided ... when using --print"*.
2. Each emitted element packs `flag value` into one token, then `spawn`
   uses `shell: true`, which re-tokenizes via `/bin/sh -c`. Any value
   containing shell metachars (`$`, backticks, parens, semicolons) gets
   re-interpreted by the shell. Multi-line markdown prompts blow up
   spectacularly.

**Patched behavior**

- Emit one token per argv element (`--flag` and `value` as separate items)
- Append `argsObj._` after the flags so positionals are preserved
- Drop `shell: true` — pass argv directly to spawn, no shell re-tokenize

## Patch 3 — `packages/core/src/transformer/anthropic.transformer.ts` :: `auth()`

**Upstream behavior**

```ts
async auth(request, provider) {
  const headers = {};
  if (this.useBearer) {
    headers["authorization"] = `Bearer ${provider.apiKey}`;
    headers["x-api-key"] = undefined;
  } else {
    headers["x-api-key"] = provider.apiKey;
    headers["authorization"] = undefined;
  }
  return { body: request, config: { headers } };
}
```

Two problems for code-router's use case (corporate Anthropic-native gateway,
single-element `["Anthropic"]` chain → CCR bypass mode → only `auth()` runs):

1. **Static `provider.apiKey`.** OAuth tokens rotate every hour; the
   inject-token plugin solves this for the openai chain, but bypass mode
   skips the chain entirely, so anthropic providers would have to restart
   the daemon on every refresh — exactly what this project exists to avoid.
2. **Unfiltered request body.** Recent Claude Code releases send fields
   the gateway's older Anthropic API rejects (`context_management`,
   `thinking`, `output_config.effort: "xhigh"`). Bypass mode means no
   transformer chain runs, so there's no other place to clean them up.

**Patched behavior**

In `auth()`, before building headers and returning:

1. **Resolve the active token path.** Preferred: when
   `process.env.ANTHROPIC_TOKEN_DIR` is set, use
   `${ANTHROPIC_TOKEN_DIR}/${provider.name}.txt` — this lets the single
   daemon serve multiple Anthropic-typed providers concurrently, each with
   its own rotating bearer token, keyed off the provider name CCR resolved
   from the inbound `model = "name,model"` field. Legacy fallback: when
   only `process.env.ANTHROPIC_TOKEN_FILE` is set, use that single file
   (matches the old single-active-provider behavior). With neither set,
   patch 3 is inert and behavior matches upstream.
2. Read the live bearer token from the resolved path (falling back to
   `provider.apiKey` on read error). Pairs with `code-router-refresh-token`,
   which atomically rewrites the token files for the warm set every ~30 min.
3. In DIR mode, also touch `${ANTHROPIC_TOKEN_DIR}/../used/${provider.name}`
   on each request. The refresh script reads these mtimes to decide which
   providers are still "warm" and worth re-minting (2h idle TTL); providers
   that fall out of the window are GC'd, so unused configured providers
   don't keep consuming token-mint traffic.
4. Strip `request.context_management` and `request.thinking` (gateway has
   no compatible shape for either).
5. Clamp `request.reasoning_effort`, `request.reasoning.effort`, and
   `request.output_config.effort` from any unsupported value (e.g.
   `"xhigh"`) down to `"high"` — preserves user intent rather than
   dropping the field.

The patch is gated on `ANTHROPIC_TOKEN_DIR` or `ANTHROPIC_TOKEN_FILE`. If
neither env var is set, behavior matches what the transformer would do
without the patch — so this code is safe to reuse for non-code-router
setups that don't want the OAuth-rotation machinery.

## Patch 4 — `packages/core/src/server.ts` :: `resolveModelOrError()` alias map

**Why**

Commit `b9bc94d` made `resolveModelOrError` 404 any model whose first
comma-segment isn't a configured provider. That catches typos from `icode`,
but it also rejects the model names Claude Code's official client sends by
default (`claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`) when no
`ANTHROPIC_MODEL` override is set. Pre-`b9bc94d`, those names fell through
to `Router.default` via the scenario router and silently worked.

**Patched behavior**

`resolveModelOrError` now consults `Router.aliases` (a flat
`{ requested → replacement }` map from `config.json`) immediately after
defaulting from `Router.default`. If `requested` is a key in `aliases`, it's
substituted before the comma-split / provider lookup runs. Unknown names
that aren't in `aliases` still 404 — the typo-detection property the
validator was added for is preserved.

Example config:

```json
"Router": {
  "default": "opus,mt-genai-claude-opus-4-5-20251101-preview",
  "aliases": {
    "claude-opus-4-8":   "opus",
    "claude-sonnet-4-6": "opus",
    "claude-haiku-4-5":  "opus"
  }
}
```

Right-hand side accepts anything `resolveModelOrError` accepts after the
substitution — `"provider"` (uses provider's first `models[]` entry) or
`"provider,explicit-model"`. No alias chaining (single substitution).

