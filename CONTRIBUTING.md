# Contributing to browser-automation-skill

Two-minute orientation. Deeper reading paths below.

## Where things live

| Need to… | Go to |
|---|---|
| Understand the whole skill | `docs/ARCHITECTURE.md` |
| Add a new adapter (e.g. Stagehand, midscene, custom CDP) | `references/recipes/add-a-tool-adapter.md` |
| Add a new verb | `docs/ARCHITECTURE.md` §6 + copy `scripts/browser-snapshot.sh` as template |
| Expose a verb via MCP | `docs/ARCHITECTURE.md` §9 + `references/browser-mcp-cheatsheet.md` |
| Add a schema migration | `docs/superpowers/specs/2026-05-11-phase-10-schema-migration-design.md` + `scripts/lib/migrators/<schema>/v<from>_to_<to>.sh` |
| Add telemetry to a verb | `references/browser-stats-cheatsheet.md` |
| Run the test suite | `bats tests/` (full); `bats tests/<file>.bats` (focused); `tests/lint.sh` (3-tier static + dynamic + drift) |

## Before you push

1. `bats tests/` — full suite must stay green.
2. `tests/lint.sh` — three tiers (static / dynamic / drift) must all pass.
3. `shellcheck -S warning -x` on every script you touched.
4. Read the relevant **anti-patterns recipe** in `references/recipes/`
   for the area you changed. Each codifies a past mistake — your PR
   shouldn't repeat it.

## Core invariants (don't break these — `[breaking]` change required)

See `docs/ARCHITECTURE.md` §16. Quick list:

- Verb output ends with a single-line JSON summary (verb, tool, why, status, duration_ms).
- Adapter ABI: 11 functions, JSON-returning, no file-scope network calls.
- State dir mode 0700; per-file mode 0600.
- Secrets via `--secret-stdin` only (AP-7). Never argv. Never MCP tool args.
- Telemetry local-only; no remote sinks.
- Schema migrations explicit; doctor never auto-migrates.

## Asking for help

- For design questions: file an issue referencing the relevant spec under
  `docs/superpowers/specs/`.
- For "is this an anti-pattern?" questions: check
  `references/recipes/anti-patterns-tool-extension.md` first.
- For "where do I put this?": `docs/ARCHITECTURE.md` §15 has the new-contributor reading order.
