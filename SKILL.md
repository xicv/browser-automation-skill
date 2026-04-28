---
name: browser-automation-skill
description: Drive a real browser from Claude Code via four routed tools (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura). Credentials and sessions stay strictly local in $HOME/.browser-skill/ (mode 0600) and never appear on argv, in git, or in the Claude transcript.
when_to_use: The user mentions a browser task — verify a page, fill a form, capture console errors, run a lighthouse audit, scrape multiple URLs, debug a UI bug iteratively, or run a recorded flow.
argument-hint: [verb] [--site NAME] [--session NAME] [--tool NAME] [--dry-run]
allowed-tools: Bash(bash *) Bash(jq *) Bash(chmod *) Bash(mkdir *) Bash(stat *) Bash(rm *) Bash(mv *) Bash(cat *)
---

# browser-automation-skill (Phase 1 — foundation)

Phase 1 ships only the foundation: install + doctor + state dir + pre-commit hook.
Verbs that drive a browser arrive in Phase 2 onward.

## Verbs

| Verb | What it does | Example |
|---|---|---|
| `doctor` | Health check: deps, state dir mode, disk encryption, no network | `bash "${CLAUDE_SKILL_DIR}/scripts/browser-doctor.sh"` |

## Before running anything

If `doctor` reports `~/.browser-skill` missing, run `./install.sh` (or `./install.sh --with-hooks` for the credential-leak blocker).

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a single-line JSON summary. Parse with jq; route on `.status` (`ok`, `partial`, `error`, `empty`, `aborted`).

```
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the full design and `docs/superpowers/plans/` for phase plans.
