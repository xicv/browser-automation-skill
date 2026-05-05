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
| `login`         | Capture a Playwright storageState into a session | `… login --site prod --as prod--admin --interactive` |
| `login` (file)  | Same — but consume a hand-edited storageState file | `… login --site prod --as prod--admin --storage-state-file PATH` |
| `login` (auto)  | Programmatic headless login using stored credential (AP-7 stdin-only) | `… login --site prod --as prod--admin --auto` |
| `list-sessions` | List captured sessions (optionally filter by site) | `… list-sessions --site prod` |
| `show-session`  | Show session metadata (NEVER cookie/token values) | `… show-session --as prod--admin` |
| `remove-session`| Typed-name confirmed delete of a captured session | `… remove-session --as prod--admin --yes-i-know` |
| `creds add`     | Register credential (smart per-OS backend; AP-7 stdin-only; first plaintext use needs `--yes-i-know-plaintext`; `--auth-flow STR` declares form shape — single-step / multi-step / username-only / custom) | `printf 'pw' \| … creds-add --site prod --as prod--admin --password-stdin --auth-flow single-step-username-password` |
| `creds list`    | List credentials (optional `--site` filter; metadata only) | `… creds-list --site prod` |
| `creds show`    | Show credential metadata (NEVER secret value) | `… creds-show --as prod--admin` |
| `creds show` (reveal) | After typed-phrase confirmation, include secret + masked preview | `printf 'prod--admin\n' \| … creds-show --as prod--admin --reveal` |
| `creds remove`  | Typed-name confirmed delete of a credential | `… creds-remove --as prod--admin --yes-i-know` |
| `creds migrate` | Move credential to a different backend (fail-safe ordering) | `… creds-migrate --as prod--admin --to keychain --yes-i-know` |
| `creds totp`    | Generate current 6-digit TOTP code from stored shared secret (RFC 6238) | `… creds-totp --as prod--admin` |
| `creds rotate-totp` | Re-enroll TOTP shared secret (service forced new QR) | `printf '%s' NEW_BASE32 \| … creds-rotate-totp --as prod--admin --totp-secret-stdin --yes-i-know` |
| `open`          | Open a URL in the picked browser adapter | `… open --url https://app.example.com` |
| `open` w/ session | Apply a stored storageState before navigating | `… open --site prod --as prod--admin --url …` |
| `snapshot`      | Capture an `eN`-indexed accessibility snapshot | `… snapshot` |
| `click`         | Click an element by `--ref eN` or `--selector CSS` | `… click --ref e3` |
| `fill`          | Fill an input — `--text VALUE` or `--secret-stdin` | `… fill --ref e3 --text "search query"` |
| `inspect`       | Page inspection — `--capture-console`, `--capture-network`, `--screenshot`, or `--selector CSS` (multi-flag aggregation; cdt-mcp real-mode end-to-end) | `… inspect --capture-console --capture-network` |
| `audit`         | Lighthouse / perf-trace audit (cdt-mcp real-mode end-to-end) | `… audit --lighthouse` |
| `extract`       | Selector or JS extraction — `--selector CSS` or `--eval JS` (cdt-mcp real-mode end-to-end) | `… extract --selector ".title"` |

`${CLAUDE_SKILL_DIR}` is the absolute path that Claude Code injects when it
invokes the skill — it points at the symlink under `~/.claude/skills/`. Use it
in command examples so they work whether the user installed at `--user` or
`--project` scope.

## Tools

The skill routes verbs to one of these underlying tools (precedence is decided
by [router.sh](scripts/lib/router.sh); see [routing heuristics](references/routing-heuristics.md)
for the rules):

<!-- BEGIN AUTOGEN: tools-table — generated by scripts/regenerate-docs.sh -->
| Tool | Strengths | Cheatsheet |
|---|---|---|
| chrome-devtools-mcp | declares 16 verbs | [references/chrome-devtools-mcp-cheatsheet.md](references/chrome-devtools-mcp-cheatsheet.md) |
| playwright-cli | declares 4 verbs | [references/playwright-cli-cheatsheet.md](references/playwright-cli-cheatsheet.md) |
| playwright-lib | declares 5 verbs | [references/playwright-lib-cheatsheet.md](references/playwright-lib-cheatsheet.md) |
<!-- END AUTOGEN: tools-table -->

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
