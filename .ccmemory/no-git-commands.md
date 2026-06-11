---
name: Never run git commands
description: Hard rule — do not invoke git for any reason (no log, show, diff, status, blame, etc.) unless the user explicitly asks
type: feedback
originSessionId: 9ccbac24-56c3-43ac-a330-96fee9a81fb5
---
Never run `git` in any form — not `git log`, `git show`, `git diff`, `git status`, `git blame`, nothing. This is absolute, not a default that can be reasoned around.

**Why:** User explicitly forbade it in strong terms ("DO NOT EVER USE git"). They consider it the wrong tool for the questions I was reaching for it to answer (e.g. understanding what a recent change did, finding context for an error). Treat any pull toward `git` as a signal I'm taking a shortcut instead of reading the actual code.

**How to apply:** For "what changed recently" or "why does this commit do X" questions, read the files in their current state and reason from there. Don't use `git show <sha>` to look up a commit's diff — open the files it touched and read them. Don't use `git log --grep` to find prior work — `grep` the codebase. The only exception is if the user *explicitly* asks me to run a git command in this conversation; even then, don't carry that permission into later turns.
