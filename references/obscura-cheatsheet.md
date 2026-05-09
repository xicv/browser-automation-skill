# obscura — cheatsheet

The browser-skill's obscura adapter shells to the [`obscura`](https://github.com/h4ckf0r0day/obscura) binary (Apache-2.0 Rust headless browser, ~70 MB). Obscura is **not** a default-routed adapter in 8-1-i — it ships via Path A "ship-without-promotion" per [adapter-extension-model spec §4.4](../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md). Reach it with `--tool=obscura`. Promotion to default for `--scrape` / `--stealth` lands in a follow-up PR (Phase 8 part 2-i).

## When the router picks this adapter

| Verb | Default? |
|---|---|
| `extract --scrape <urls...>` | **planned 8-2-i** — not yet routed automatically |
| `extract --stealth` | **planned 8-2-i** — not yet routed automatically |
| any other verb | no — obscura is a one-shot fetch/scrape adapter |

In 8-1-i: reachable only via `--tool=obscura` (and `tool_extract` is itself a stub returning 41 — real backend in 8-1-ii and 8-1-iii).

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

To force this adapter even when the router would pick another:

```bash
bash scripts/browser-extract.sh --tool=obscura ...
```

This is the **Path A entry point** — it works without router edits. In 8-1-i this is the *only* entry point.

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

Surfaces in this adapter via `extract --stealth` once 8-1-iii lands.

## See also

- [Tool adapter extension model spec](../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md)
- [Routing heuristics](routing-heuristics.md)
- [Tool versions](tool-versions.md)
- [Adapter candidates](adapter-candidates.md) — other tools considered + declined
