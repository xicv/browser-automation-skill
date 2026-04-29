---
name: browser-automation-skill
description: Drive a real browser from Claude Code via four routed tools (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura). Credentials and sessions stay strictly local in $HOME/.browser-skill/ (mode 0700 dir, 0600 files) and never appear on argv, in git, or in the Claude transcript.
when_to_use: The user mentions a browser task — register a site, capture a session, verify a page, fill a form, capture console errors, run a lighthouse audit, scrape multiple URLs, debug a UI bug iteratively, or run a recorded flow.
argument-hint: [verb] [--site NAME] [--session NAME] [--tool NAME] [--dry-run]
allowed-tools: Bash(bash *) Bash(jq *) Bash(chmod *) Bash(mkdir *) Bash(stat *) Bash(rm *) Bash(mv *) Bash(cat *)
---

# browser-automation-skill (Phase 2 — site & session core)

Phase 2 ships site CRUD + the session schema + a stub-adapter `login`.
Real browser launches arrive in Phase 3.

## Verbs

| Verb | What it does | Example |
|---|---|---|
| `doctor`        | Health check: deps, state dir mode, disk encryption, no network | `bash "${CLAUDE_SKILL_DIR}/scripts/browser-doctor.sh"` |
| `add-site`      | Register a site profile | `… add-site --name prod --url https://app.example.com` |
| `list-sites`    | List registered sites | `… list-sites` |
| `show-site`     | Show one site's profile JSON | `… show-site --name prod` |
| `remove-site`   | Typed-name confirmed delete | `… remove-site --name prod --yes-i-know` |
| `use`           | Get / set / clear current site | `… use --set prod` |
| `login`         | Capture a Playwright storageState into a session | `… login --site prod --as prod--admin --storage-state-file PATH` |

`${CLAUDE_SKILL_DIR}` is the absolute path that Claude Code injects when it
invokes the skill — it points at the symlink under `~/.claude/skills/`. Use it
in command examples so they work whether the user installed at `--user` or
`--project` scope.

## Before running anything

If `doctor` reports `~/.browser-skill` missing, run `./install.sh` (or
`./install.sh --with-hooks` for the credential-leak blocker).

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a
single-line JSON summary. Parse with jq; route on `.status` (`ok`,
`partial`, `error`, `empty`, `aborted`).

```
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}
```

## Storage layout

```
~/.browser-skill/                       # mode 0700
├── version                              # schema marker
├── current                              # current site name (mode 0600, [personal])
├── sites/    <name>.json + .meta.json   # mode 0600 ([shareable])
├── sessions/ <name>.json + .meta.json   # mode 0600 ([PERSONAL — gitignored])
├── credentials/                         # Phase 5
└── captures/                            # Phase 7
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for
the full design and `docs/superpowers/plans/` for phase plans.
