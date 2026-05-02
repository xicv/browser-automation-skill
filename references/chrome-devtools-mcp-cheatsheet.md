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
`scripts/lib/node/chrome-devtools-bridge.mjs`. The adapter now shells to that
bridge (mirrors `playwright-lib`'s shape: adapter → node bridge → upstream).
Stub mode (`BROWSER_SKILL_LIB_STUB=1`) is the test path. Real-mode MCP stdio
transport (initialize handshake + `tools/call` + `uid → eN` translation per
token-efficient-output spec §5) is deferred to phase-05 part 1c.

## When the router picks this adapter

| Verb | Default? | Why |
|---|---|---|
| `open` | no — opt-in via `--tool=` | router default is playwright-cli |
| `click` | no — opt-in | playwright-cli |
| `fill` | no — opt-in | playwright-cli (or playwright-lib for `--secret-stdin`) |
| `snapshot` | no — opt-in | playwright-cli |
| `inspect` | **future default** (part 1d) | dedicated console + network MCP tools |
| `audit` | **future default** (part 1d) | only adapter with `lighthouse_audit` + `performance_*` |
| `extract` | **future default** (part 1d, with `--scrape` exception) | `evaluate_script` + `list_network_requests` |
| `eval` | no — opt-in | playwright-cli/lib both support it |

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

- **Real MCP transport deferred to part 1c.** Bridge throws on real-mode
  invocation; only stub mode works today.
- **No router promotion.** Per anti-pattern AP-4, this PR ships dark only.
  Promotion is part 1d.
- **No verb scripts yet.** `scripts/browser-audit.sh` and
  `scripts/browser-extract.sh` don't exist; `tests/browser-inspect.bats` is
  still skipped. Verb-side wiring is phase-05 part 1e.
- **No session loading.** Chrome's `--user-data-dir` mechanism (different
  from playwright-lib's `storageState`) is phase-05 part 1f.

## See also

- Parent spec: [`docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`](../docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md) — Appendix B routing matrix.
- Add-a-tool-adapter recipe: [`references/recipes/add-a-tool-adapter.md`](recipes/add-a-tool-adapter.md).
- Anti-patterns: [`references/recipes/anti-patterns-tool-extension.md`](recipes/anti-patterns-tool-extension.md).
- Token-efficient output spec: [`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`](../docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md).
- Phase 5 part 1b plan: [`docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md`](../docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md).
