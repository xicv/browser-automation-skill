# chrome-devtools-mcp — cheatsheet

The browser-skill's chrome-devtools-mcp adapter is the **inspection / audit /
extract** path. Upstream is the `chrome-devtools-mcp` MCP server
(`npx chrome-devtools-mcp@latest`) which exposes the rich set of CDP-backed
tools — console messages, network requests, lighthouse audits, performance
traces — that the playwright-* adapters do not.

## Status — Path A introduction (phase-05 part 1)

This adapter ships **opt-in** via `--tool=chrome-devtools-mcp`. Router
promotion (Path B — making it the default for capture-flag verbs and for
`audit` / `inspect` per parent spec Appendix B) is deferred to phase-05
part 1c after a soak window. The real stdio MCP-client bridge that wires the
adapter to `npx chrome-devtools-mcp@latest` is deferred to phase-05 part 1b.

Today, the adapter shells to `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}`
which is honored by the test stub (`tests/stubs/chrome-devtools-mcp`); on a
production box without the bin on PATH, `tool_doctor_check` reports it as
missing and verb-dispatch fails with the bin-not-found error.

## When the router picks this adapter

| Verb | Default? | Why |
|---|---|---|
| `open` | no — opt-in via `--tool=` | router default is playwright-cli |
| `click` | no — opt-in | playwright-cli |
| `fill` | no — opt-in | playwright-cli (or playwright-lib for `--secret-stdin`) |
| `snapshot` | no — opt-in | playwright-cli |
| `inspect` | **future default** (part 1c) | dedicated console + network MCP tools |
| `audit` | **future default** (part 1c) | only adapter with `lighthouse_audit` + `performance_*` |
| `extract` | **future default** (part 1c, with `--scrape` exception) | `evaluate_script` + `list_network_requests` |
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

## Doctor check

Verifies the bin is on PATH and reports its `--version` output. To install:

```bash
npm i -g chrome-devtools-mcp
# or run via npx (no global install):
#   CHROME_DEVTOOLS_MCP_BIN='npx chrome-devtools-mcp@latest' \
#     bash scripts/browser-<verb>.sh --tool=chrome-devtools-mcp ...
```

The `npx` path requires part-1b's stdio bridge to be useful; the bare-binary
path requires a wrapper that translates `<verb> [args...]` argv to the MCP
JSON-RPC tool calls (also part 1b).

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

The adapter has no `BROWSER_SKILL_LIB_STUB` knob — instead the test suite
overrides `CHROME_DEVTOOLS_MCP_BIN` to `tests/stubs/chrome-devtools-mcp`,
which performs an `sha256(argv joined by NUL)` lookup against
`tests/fixtures/chrome-devtools-mcp/<sha>.json`. Mirrors the
`tests/stubs/playwright-cli` pattern.

To regenerate fixture filenames after changing the adapter's argv translation:

```bash
printf '%s\0' inspect --capture-console | shasum -a 256 | awk '{print $1}'
```

## Limitations (current PR)

- **Real bridge missing.** Without phase-05 part 1b's MCP stdio bridge, the
  bin must be a CLI wrapper that handles `<verb> [args]` translation.
- **No router promotion.** Per anti-pattern AP-4, this PR ships dark only.
- **No verb scripts yet.** `scripts/browser-audit.sh` and
  `scripts/browser-extract.sh` don't exist; `tests/browser-inspect.bats` is
  still skipped. Verb-side wiring is phase-05 part 1d.
- **No session loading.** Chrome's `--user-data-dir` mechanism (different
  from playwright-lib's `storageState`) is phase-05 part 1e.

## See also

- Parent spec: [`docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`](../docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md) — Appendix B routing matrix.
- Add-a-tool-adapter recipe: [`references/recipes/add-a-tool-adapter.md`](recipes/add-a-tool-adapter.md).
- Anti-patterns: [`references/recipes/anti-patterns-tool-extension.md`](recipes/anti-patterns-tool-extension.md).
- Token-efficient output spec: [`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`](../docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md).
