# playwright-cli — cheatsheet

The browser-skill's playwright-cli adapter shells to the `playwright` binary (Microsoft's Playwright CLI). This adapter is the **default** for navigation and inspection verbs; it is the cheap, multi-browser, low-task-token-cost path.

## When the router picks this adapter

| Verb | Default? |
|---|---|
| `open` | yes |
| `click` (and `dblclick`) | yes |
| `fill` (and `type`) | yes |
| `snapshot` | yes |
| `inspect` (without `--capture-*`) | yes |
| `audit` | no — routed to chrome-devtools-mcp |
| `extract --scrape` | no — routed to obscura |

## Capabilities declared

```json
{
  "verbs": {
    "open":     { "flags": ["--headed", "--viewport", "--user-agent"] },
    "click":    { "flags": ["--ref", "--selector"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": [] },
    "inspect":  { "flags": ["--selector"] }
  }
}
```

## Doctor check

The adapter checks for the `playwright` binary on PATH. To install:

```bash
npm i -g playwright @playwright/test
playwright install chromium
```

## Version pin

- `version_pin: "1.49.x"` — major.minor stability target. Fixture argv-hashes assume the surface CLI shape of 1.49.

## Override

To force this adapter even when the router would pick another:

```bash
bash scripts/browser-<verb>.sh --tool=playwright-cli ...
```

This is the **Path A entry point** for any new verb that isn't yet in the router's precedence table — it works without router edits.

## Limitations

- No console-message or network-HAR capture (use `--tool=chrome-devtools-mcp` or omit `--tool` and pass `--capture-console` / `--capture-network`).
- No lighthouse audit (chrome-devtools-mcp).
- No stealth / anti-fingerprinting (obscura).

## See also

- [Tool adapter extension model spec](../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md)
- [Routing heuristics](routing-heuristics.md)
- [Tool versions](tool-versions.md)
