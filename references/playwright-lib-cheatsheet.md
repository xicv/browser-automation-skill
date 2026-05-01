# playwright-lib — cheatsheet

The browser-skill's playwright-lib adapter shells to a Node ESM driver
(`scripts/lib/node/playwright-driver.mjs`) that talks the real Playwright API
directly. This adapter is the **session-aware** path: it natively supports
`storageState` loading, `--secret-stdin`, and any future capability that needs
in-process Node access.

## When the router picks this adapter

The default router prefers `playwright-cli` for stateless navigation/inspection
verbs (cheaper cold start, no node dep on the hot path). `playwright-lib` wins
when:

- `BROWSER_SKILL_STORAGE_STATE` is set (typically because the verb script
  resolved `--site` / `--as` to a stored session) — `rule_session_required`
  picks playwright-lib.
- `--secret-stdin` is used with the `fill` verb — playwright-cli rejects this
  flag (would leak via argv).
- The verb is `login` — there is no playwright-cli `login` subcommand.

You can always force this adapter via `--tool=playwright-lib`.

## Capabilities declared

```json
{
  "verbs": {
    "open":     { "flags": ["--headed", "--viewport", "--user-agent", "--storage-state"] },
    "click":    { "flags": ["--ref", "--selector"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": ["--depth"] },
    "login":    { "flags": ["--storage-state"] }
  },
  "session_load": true
}
```

Note: `inspect` / `audit` / `extract` are intentionally NOT declared — those
are chrome-devtools-mcp / obscura territory. The verb-dispatch functions for
those exist but return `EXIT_TOOL_UNSUPPORTED_OP` (41) so the router never
picks playwright-lib for them.

## Doctor check

Verifies `node` is on PATH and the driver script is present at the expected
path. To install Node + Playwright + a browser:

```bash
brew install node                                          # macOS
npm i -g playwright @playwright/test                       # lib + test runner
playwright install chromium                                # browser binary
```

## Version pin

- `version_pin: "1.59.x"` — pinned to a major.minor stability target. The
  driver's lazy `import('playwright')` reads whatever version is installed;
  drift between pin and installed version surfaces in `tool_doctor_check`.

## Stub mode

Set `BROWSER_SKILL_LIB_STUB=1` to run the driver against
`tests/fixtures/playwright-lib/<argv-hash>.json` instead of launching a
browser. Used by the bats suite + CI so tests don't require Playwright
installed.

## Storage state (session loading)

The driver accepts `--storage-state PATH` to apply a Playwright `storageState`
JSON before navigation. Verb scripts forward `BROWSER_SKILL_STORAGE_STATE`
(set by `resolve_session_storage_state` in `verb_helpers.sh`) as that flag.
Origin enforcement happens in the Phase-2 `session_origin_check` lib before
the env var is exported, so the storageState's origins are guaranteed to
match the site URL when the driver receives it.

## Secrets

`tool_fill --ref eN --secret-stdin` reads the secret from process stdin
inside the driver — secrets never reach argv (anti-pattern AP-7). The
playwright-cli adapter rejects `--secret-stdin` for this reason; route to
playwright-lib explicitly via `--tool=playwright-lib` or rely on the router's
preference when `--site/--as` resolves a session.

## See also

- [Tool adapter extension model spec](../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md)
- [Token-efficient adapter output spec](../docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md)
- [playwright-cli cheatsheet](playwright-cli-cheatsheet.md) — the binary-shelled sibling adapter.
- [Tool versions](tool-versions.md)
