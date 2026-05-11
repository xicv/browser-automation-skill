# Agent-workflow recipes

End-to-end command sequences for common browser-automation tasks. Each
recipe assumes a **fresh `~/.browser-skill/`** (run `./install.sh` first if
needed) and walks through the full toolchain: site → session → action →
observation → cache build-up.

These are distinct from the **pattern recipes** in the parent directory
(`../privacy-canary.md`, `../path-security.md`, etc.), which codify
discipline ("when adding X, do Y, never Z"). Workflow recipes show
sequenced commands + expected output for actual user-facing tasks.

## Index

| Recipe | When to read it |
|---|---|
| [`login-then-scrape.md`](login-then-scrape.md) | First end-to-end task: register site, capture session, scrape pages. The "hello world" of the skill. |
| [`incremental-pattern-discovery.md`](incremental-pattern-discovery.md) | Build up the memory cache from a real session. Demonstrates PR #115/#125/#127 loop end-to-end. |
| [`flow-record-and-replay.md`](flow-record-and-replay.md) | Capture a manual interaction via `flow record`, replay it, diff against a baseline. |
| [`cache-driven-bulk-operation.md`](cache-driven-bulk-operation.md) | Process 50+ items with zero LLM tokens via the memory cache. The "ROI proof" workflow. |

## Convention

Each recipe:
- States the **goal** + **outcome** up front (one sentence each).
- Lists **prerequisites** (assumes clean `~/.browser-skill/`).
- Walks **numbered steps** with `bash` commands + abbreviated expected output.
- Ends with **verification** + **next-step** pointers.

Commands are runnable verbatim from any directory with `${CLAUDE_SKILL_DIR}`
set (or substituting the repo path if running standalone).

## When you're ready to ship

After working through 1-2 recipes end-to-end, the toolchain's full surface
is in muscle memory. Subsequent agent sessions can read SKILL.md + the
verb tables instead of stepping through workflows.
