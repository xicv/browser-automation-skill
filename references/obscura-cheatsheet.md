# obscura — cheatsheet

The browser-skill's obscura adapter shells to the [`obscura`](https://github.com/h4ckf0r0day/obscura) binary (Apache-2.0 Rust headless browser, ~70 MB). Obscura is the default-routed adapter for `--scrape` and `--stealth` (since Phase 8 part 2-i); reachable as `--tool obscura` for explicit override.

## When the router picks this adapter

| Verb | Default? |
|---|---|
| `extract --scrape <urls...>` | **yes** (since 8-2-i) — `rule_scrape_flag` in `scripts/lib/router.sh` |
| `extract --stealth <url>` | **yes** (since 8-2-i) — `rule_stealth_flag` in `scripts/lib/router.sh` |
| any other verb | no — obscura is a one-shot fetch/scrape adapter |

`--tool obscura` still works as an explicit override. `--tool chrome-devtools-mcp --scrape` would fail the capability filter (cdt-mcp doesn't declare `--scrape`) and the router falls through to the next rule.

## Capabilities declared

```json
{
  "verbs": {
    "extract": { "flags": ["--scrape", "--stealth", "--eval", "--selector"] }
  }
}
```

Stateful verbs (`open`, `click`, `fill`, `snapshot`) are intentionally **not** declared. Obscura is a one-shot fetch/scrape engine; stateful navigation belongs to `playwright-cli` / `playwright-lib` / `chrome-devtools-mcp`.

## Doctor check

The adapter checks for the `obscura` binary on PATH. To install:

```bash
# Linux x86_64
curl -LO https://github.com/h4ckf0r0day/obscura/releases/latest/download/obscura-x86_64-linux.tar.gz
tar xzf obscura-x86_64-linux.tar.gz

# macOS Apple Silicon
curl -LO https://github.com/h4ckf0r0day/obscura/releases/latest/download/obscura-aarch64-macos.tar.gz
tar xzf obscura-aarch64-macos.tar.gz
```

No Chrome, no Node.js, no dependencies. Release archives include both `obscura` and `obscura-worker`; keep them in the same directory for the parallel `scrape` command.

## Version pin

- `version_pin: "0.x"` — pre-1.0 upstream; major.minor stability target tracks the latest release available at adapter-roll time.

## Override

To force this adapter even when the router would pick another (e.g. for verbs where obscura isn't the default):

```bash
bash scripts/browser-extract.sh --tool obscura ...
```

This was the **Path A entry point** in 8-1-i / 8-1-ii / 8-1-iii. After 8-2-i, `--scrape` and `--stealth` auto-route to obscura (Path B); the explicit `--tool obscura` is no longer needed for those flags but still works as an override.

## Modes

Obscura ships in two modes upstream. The adapter targets only mode 1.

| Mode | Surface | Handled by |
|---|---|---|
| **One-shot** | `obscura fetch <url>` + `obscura scrape <urls...>` | this adapter (8-1-ii / 8-1-iii) |
| **CDP server** | `obscura serve --port 9222` (Puppeteer/Playwright connect via `connectOverCDP`) | future `playwright-lib --cdp-endpoint` flag — NOT this adapter |

Reasoning: mode 2 overlaps with `playwright-lib`'s transport. Adding it as a separate adapter would split the contributor mental model. The unique-lane principle picks mode 1 only.

## Limitations

- **No stateful navigation** — no persistent page; each invocation is a fresh process. Use `playwright-cli` / `playwright-lib` / `chrome-devtools-mcp` for click/fill/snapshot flows.
- **No console-message or network-HAR capture** — use `chrome-devtools-mcp` (`--capture-console` / `--capture-network`).
- **No lighthouse audit** — use `chrome-devtools-mcp`.
- **No `--firefox` / `--webkit`** — Chromium-CDP only; multi-browser is `playwright-cli`'s lane.

## Stealth mode

Obscura's standout feature: build with `--features stealth`, run with `--stealth`. Includes:
- Per-session fingerprint randomization (GPU, screen, canvas, audio, battery)
- Realistic `navigator.userAgentData` (Chrome high-entropy values)
- `navigator.webdriver = undefined`
- 3,520-domain tracker block

Real-mode in this adapter via `extract --stealth <url> --eval EXPR` (since 8-1-iii). Single URL only; `--eval` required (without it `obscura fetch` dumps full HTML, too large for the streaming-event contract). Emits one `extract_stealth` event with `{event, url, eval}`. The `eval` field is always a string in this PR — typed parsing is deferred. Callers needing typed results should `JSON.stringify` inside their `--eval` expression and parse downstream.

```bash
# String eval (default):
bash scripts/browser-extract.sh --tool obscura --stealth \
  --eval "document.title" https://example.com

# Typed eval (caller-encoded JSON):
bash scripts/browser-extract.sh --tool obscura --stealth \
  --eval "JSON.stringify({title: document.title, h1: document.querySelector('h1').textContent})" \
  https://example.com
```

`--scrape` and `--stealth` are mutually exclusive (verb script enforces this).

## See also

- [Tool adapter extension model spec](../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md)
- [Routing heuristics](routing-heuristics.md)
- [Tool versions](tool-versions.md)
- [Adapter candidates](adapter-candidates.md) — other tools considered + declined
