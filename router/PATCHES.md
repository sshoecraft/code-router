# Patched fork of claude-code-router

This directory is a snapshot of `https://github.com/musistudio/claude-code-router`
with three local patches applied. The patches live baked into the source —
there is no `.patch` file to apply and no upstream clone at install time.

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

1. If `process.env.ANTHROPIC_TOKEN_FILE` is set, read the live bearer token
   from that file (defaulting back to `provider.apiKey` on read error).
   Pairs with `code-router-refresh-token`, which atomically rewrites the
   token file every 30 min.
2. Strip `request.context_management` and `request.thinking` (gateway has
   no compatible shape for either).
3. Clamp `request.reasoning_effort`, `request.reasoning.effort`, and
   `request.output_config.effort` from any unsupported value (e.g.
   `"xhigh"`) down to `"high"` — preserves user intent rather than
   dropping the field.

The patch is gated entirely on `ANTHROPIC_TOKEN_FILE`: if the env var is
unset, behavior matches upstream. So this patch is safe even if the
vendored router is reused for non-code-router setups.

## Why vendor instead of patch-on-install

- Zero install-time network dependency on github.com.
- Reproducible build: every install of this project ships the same source.
- No upstream-drift risk between when the patch was authored and when an
  install runs.
- Trivial to diff against upstream when re-syncing.

## Re-syncing with upstream

```bash
git clone https://github.com/musistudio/claude-code-router.git /tmp/ccr-upstream
diff -ru /tmp/ccr-upstream/packages/cli/src/utils/index.ts \
         router/packages/cli/src/utils/index.ts
```

If upstream merges the fix, drop the local change and pull the new
sources straight in.
