# Patched fork of claude-code-router

This directory is a snapshot of `https://github.com/musistudio/claude-code-router`
with two local patches applied. The patches live baked into the source —
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
