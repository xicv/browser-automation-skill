# chrome-devtools-mcp — cheatsheet

The browser-skill's chrome-devtools-mcp adapter is the **inspection / audit /
extract** path. Upstream is the `chrome-devtools-mcp` MCP server
(`npx chrome-devtools-mcp@latest`) which exposes the rich set of CDP-backed
tools — console messages, network requests, lighthouse audits, performance
traces — that the playwright-* adapters do not.

## Status — Path A introduction (phase-05 part 1) + bridge scaffold (part 1b)

This adapter ships **opt-in** via `--tool=chrome-devtools-mcp`. Router
promotion (Path B — making it the default for capture-flag verbs and for
`audit` / `inspect` per parent spec Appendix B) is deferred to phase-05
part 1d after a soak window.

Phase-05 part 1b shipped the **node bridge scaffold** at
`scripts/lib/node/chrome-devtools-bridge.mjs`. The adapter shells to that
bridge (mirrors `playwright-lib`'s shape: adapter → node bridge → upstream).

**Phase-05 part 1c shipped the real MCP stdio transport** for stateless
verbs. With `${CHROME_DEVTOOLS_MCP_BIN}` pointing at a real
`chrome-devtools-mcp` (e.g. `npx chrome-devtools-mcp@latest`), the bridge:
1. spawns the upstream MCP server with stdio piped,
2. sends the `initialize` handshake (protocol version `2024-11-05`),
3. translates the verb → MCP `tools/call`,
4. shapes the response into the skill's single-line summary JSON,
5. exits cleanly.

`uid → eN` translation happens at the adapter boundary (per token-efficient-
output spec §5) for snapshot output. The original `uid` is kept on each ref
for traceability.

| Verb | Real-mode behavior |
|---|---|
| `open` | `navigate_page {url}` — works (one-shot, or via daemon when running) |
| `snapshot` | `take_snapshot` — works; refs translated to `eN`. When daemon is running, refMap is cached server-side so subsequent `click` / `fill` resolve `eN → uid` |
| `eval` | `evaluate_script {script}` — works |
| `audit` | `lighthouse_audit` — works (60s timeout) |
| `click`, `fill` | works **via daemon** (phase-05 part 1c-ii) — `daemon-start` first, then `snapshot`, then `click eN` / `fill eN ...`. Without daemon → exit 41 with hint |
| `inspect` | works real-mode (phase-05 part 1e-ii). Multi-flag aggregation: `--capture-console` → `list_console_messages`; `--capture-network` → `list_network_requests`; `--screenshot` → `take_screenshot`; `--selector CSS` → `evaluate_script` with querySelectorAll. One-shot or daemon-routed |
| `extract` | works real-mode (phase-05 part 1e-ii). `--selector CSS` → evaluate_script with querySelectorAll → text join; `--eval JS` → raw evaluate_script. One-shot or daemon-routed |

### Daemon mode (phase-05 part 1c-ii)

`daemon-start` spawns a detached node child that holds ONE long-lived MCP
server child + the `eN ↔ uid` ref map + a TCP loopback IPC server. Verb
clients connect over loopback (Unix sun_path 104-char cap on macOS bats temp
paths — TCP loopback with ephemeral port sidesteps it). State written to
`${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json` (mode 0600, dir 0700).

```bash
node scripts/lib/node/chrome-devtools-bridge.mjs daemon-start
node scripts/lib/node/chrome-devtools-bridge.mjs open https://example.com
node scripts/lib/node/chrome-devtools-bridge.mjs snapshot
node scripts/lib/node/chrome-devtools-bridge.mjs click e1
node scripts/lib/node/chrome-devtools-bridge.mjs daemon-stop
```

`daemon-status` reports `daemon-running` / `daemon-not-running`. `daemon-stop`
when none is a no-op success. Idempotent `daemon-start` returns
`daemon-already-running`. Daemon stderr lands at
`${BROWSER_SKILL_HOME}/cdt-mcp-daemon.log` (mode 0600).

Stub mode (`BROWSER_SKILL_LIB_STUB=1`) still works exactly as part-1b — used by the bats suite + CI for adapter contract tests without spawning anything.

## When the router picks this adapter

After Phase 5 part 1d, four routing rules promote chrome-devtools-mcp to a default for verbs and flags where it's the only sensible adapter (per parent spec Appendix B):

| Verb / flag | Default? | Why |
|---|---|---|
| `open` (no flags) | no | router default is playwright-cli |
| `click` (no flags) | no | playwright-cli |
| `fill` (no flags) | no | playwright-cli (or playwright-lib for `--secret-stdin`) |
| `snapshot` (no flags) | no | playwright-cli |
| `--capture-console` / `--capture-network` (any verb) | **YES** (part 1d) | `rule_capture_flags` — only adapter with console + network MCP tools |
| `--lighthouse` / `--perf-trace` (any verb) | **YES** (part 1d) | `rule_audit_or_perf` — only adapter with `lighthouse_audit` + `performance_*` |
| `audit` (any flags) | **YES** (part 1d) | `rule_audit_or_perf` |
| `inspect` | **YES** (part 1d) | `rule_inspect_default` |
| `extract` | **YES** (part 1d) | `rule_extract_default`. With `--scrape <urls...>` → obscura (when Phase 8 lands) |
| `eval` | no — opt-in | playwright-cli/lib both support it |

`session_required` (storage-state loaded) still wins above all capture-flag rules; that path keeps routing through playwright-lib, so flag combos like `--site app --capture-console` route to playwright-lib (capture flags silently ignored). Limitation tracked for part 1f (Chrome `--user-data-dir` lets cdt-mcp do session loading too).

## Capabilities declared

```json
{
  "verbs": {
    "open":     { "flags": ["--headed", "--url"] },
    "click":    { "flags": ["--ref"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": ["--depth"] },
    "inspect":  { "flags": ["--capture-console", "--capture-network", "--screenshot"] },
    "audit":    { "flags": ["--lighthouse", "--perf-trace"] },
    "extract":  { "flags": ["--selector", "--eval"] },
    "eval":     { "flags": ["--expression"] }
  }
}
```

All eight verbs are declared so `--tool=chrome-devtools-mcp` makes the full
surface reachable today (the capability filter in `pick_tool` admits any
declared verb regardless of router precedence).

## Architecture

```
bash adapter            node bridge                upstream MCP server
┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────────┐
│ chrome-devtools-│───▶│ chrome-devtools-     │───▶│ chrome-devtools-mcp │
│ mcp.sh          │    │ bridge.mjs           │    │ (npx, JSON-RPC over │
│ (8 tool_* fns)  │    │ - stub mode          │    │  stdio) — part 1c   │
│                 │    │ - real mode (1c)     │    │                     │
└─────────────────┘    └──────────────────────┘    └─────────────────────┘
```

This mirrors the `playwright-lib → playwright-driver.mjs → real Playwright`
shape. The bridge is the translation boundary between skill verb argv and
the MCP `tools/call` JSON-RPC envelope (real mode) OR fixture lookup (stub
mode).

## Doctor check

Verifies `node` is on PATH and the bridge file is present (mirror
`playwright-lib::tool_doctor_check`). Reports node version and the
`mcp_server_bin` name. Includes a `note` field stating real-mode MCP
transport is deferred to part 1c.

To install (real-mode, once part 1c lands):

```bash
npm i -g chrome-devtools-mcp
# or run via npx (no global install):
#   CHROME_DEVTOOLS_MCP_BIN='npx chrome-devtools-mcp@latest' \
#     bash scripts/browser-<verb>.sh --tool=chrome-devtools-mcp ...
```

## Version pin

- `version_pin: "0.x"` — the upstream package is pre-1.0; capabilities are
  expected to drift. The pin will move once a stable major lands.

## Override

Force this adapter even when the router would pick another:

```bash
bash scripts/browser-<verb>.sh --tool=chrome-devtools-mcp ...
```

This is the **Path A entry point** — it works without router edits and is
how every new adapter is introduced (see
[references/recipes/add-a-tool-adapter.md](recipes/add-a-tool-adapter.md)).

## Stub mode

Set `BROWSER_SKILL_LIB_STUB=1` to make the bridge perform a fixture lookup
instead of spawning the upstream MCP server (which the bridge doesn't yet do
anyway — that's part 1c). The bridge hashes argv (`sha256` of args
joined+terminated by NUL — matches `printf '%s\0' "$@" | shasum -a 256`) and
echoes the corresponding `tests/fixtures/chrome-devtools-mcp/<sha>.json`.
Misses exit 41 with a JSON error line.

To regenerate fixture filenames after changing the adapter's argv translation:

```bash
printf '%s\0' inspect --capture-console | shasum -a 256 | awk '{print $1}'
```

The same digest in node (the bridge's path):

```bash
node -e "const{createHash}=require('crypto'); \
  console.log(createHash('sha256') \
    .update(['inspect','--capture-console'].map(a=>a+'\0').join('')) \
    .digest('hex'))"
```

## Environment variables

| Var | Meaning | Default |
|---|---|---|
| `BROWSER_SKILL_LIB_STUB` | When `=1`, bridge skips MCP transport and reads fixtures | unset |
| `BROWSER_SKILL_NODE_BIN` | Node binary the adapter invokes | `node` |
| `CHROME_DEVTOOLS_MCP_BIN` | Upstream MCP server binary the bridge spawns in real mode (part 1c) | `chrome-devtools-mcp` |
| `CHROME_DEVTOOLS_MCP_FIXTURES_DIR` | Override fixture directory in stub mode | `tests/fixtures/chrome-devtools-mcp` (relative to bridge file) |
| `STUB_LOG_FILE` | When set, bridge in stub mode appends each invocation's argv (one line per arg) here | unset |

## Limitations (current state)

- **No router promotion.** Per anti-pattern AP-4, this PR ships dark only.
  Promotion is part 1d.
- **No `inspect` / `extract` verbs yet.** `scripts/browser-audit.sh` and
  `scripts/browser-extract.sh` don't exist; `tests/browser-inspect.bats` is
  still skipped. Verb-side wiring (and daemon dispatch for these two) is
  phase-05 part 1e.
- **No session loading.** Chrome's `--user-data-dir` mechanism (different
  from playwright-lib's `storageState`) is phase-05 part 1f.

## See also

- Parent spec: [`docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`](../docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md) — Appendix B routing matrix.
- Add-a-tool-adapter recipe: [`references/recipes/add-a-tool-adapter.md`](recipes/add-a-tool-adapter.md).
- Anti-patterns: [`references/recipes/anti-patterns-tool-extension.md`](recipes/anti-patterns-tool-extension.md).
- Token-efficient output spec: [`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`](../docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md).
- Phase 5 part 1b plan: [`docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md`](../docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md).
