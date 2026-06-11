---
name: router is our fork, not vendored
description: The router/ subdirectory is first-party code, not a vendored upstream snapshot — too divergent to re-sync.
type: project
originSessionId: fdb921d6-6e90-4d1d-bcb1-62610ac3cf62
---
The `router/` subdirectory in code-router is our own fork of what used to
be `@musistudio/claude-code-router`. The divergence is permanent — there
is no plan to re-sync with upstream, and at this point we've made so many
changes that re-syncing would not be feasible.

**Why:** The user said "we're too far into it, we're never going back to
the vendor itself. So stop saying that." Calling it "vendored" implies
it's an external dependency we're tracking, which sets the wrong mental
model — both for the user when reading docs, and for code review when
deciding how aggressively to change router internals.

**How to apply:** When writing or editing docs (README, CLAUDE.md,
PATCHES.md) or discussing router changes:

- Refer to it as "our router," "the router fork," "the router (router/)"
  or just "router/". Do not say "vendored router" or "patched fork of
  upstream."
- Frame patches as design decisions in our codebase, not as deltas
  against upstream. PATCHES.md exists for historical context, not as a
  re-sync checklist.
- Do not include "how to re-sync with upstream" instructions or diff
  recipes in docs.
- Be willing to refactor router internals freely — there is no upstream
  divergence cost to weigh against.
