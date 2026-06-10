# browser-mcp — cheatsheet

`scripts/browser-mcp.sh serve` starts an MCP (Model Context Protocol) server
that exposes our verbs as MCP tools. Spawn it from any MCP-capable client
(Claude Code, OpenAI Codex, Continue, Cline, agent-browser, midscene, Stagehand,
browser-use, etc.) to drive our cache + telemetry + secrets vault without
re-implementing them.

Phase 14 origin: midscene research showed midscene publishes its own MCP
server so upper-layer agents can call it via natural language. We mirror that
pattern so anything that speaks MCP can reuse our entire skill — turning us
into the shared middleware browser agents delegate to.

## Wire format

- Transport: stdio (NDJSON — one JSON object per line)
- Protocol: MCP 2024-11-05 (matches our existing chrome-devtools-bridge client)
- Envelope: JSON-RPC 2.0

## Tools exposed

| Tool | Wraps | Required inputs | Optional |
|---|---|---|---|
| `browser_open`     | `scripts/browser-open.sh`     | `url`              | `site`, `tool` |
| `browser_snapshot` | `scripts/browser-snapshot.sh` | _none_             | `site`, `tool`, `capture` |
| `browser_click`    | `scripts/browser-click.sh`    | one of `ref` / `selector` | `site`, `tool` |
| `browser_fill`     | `scripts/browser-fill.sh`     | `text` + one of `ref` / `selector` | `site`, `tool` |
| `browser_extract`  | `scripts/browser-extract.sh`  | one of `selector` / `eval` | `site`, `tool` |
| `browser_list-sites` | `scripts/browser-list-sites.sh` | _none_ | `format` |

Each `tools/call` response carries `content: [{type: "text", text: "<summary JSON>"}]`
where `<summary JSON>` is the verb's last stdout line (per the token-efficient
output spec §3.1). `_meta.exitCode` and `_meta.stderr` are surfaced for
diagnostics.

### Secrets discipline (AP-7)

`browser_fill` deliberately has NO `secret` field. MCP has no stdin channel
and putting secrets in tool arguments lands them in the request transcript.
For real secret values, call `scripts/browser-fill.sh --secret-stdin`
directly (the secret is piped via stdin and never reaches argv). Phase 14
unit-tests this contract: `tests/browser-mcp.bats` asserts the schema does
not expose any "secret" property and rejects unknown props via
`additionalProperties: false`.

### Env-var passthrough (whitelist)

The MCP server does NOT inherit the client's full env. Only these prefixes
+ POSIX essentials pass through to spawned bash verbs (see
`scripts/lib/node/mcp-server.mjs::ENV_WHITELIST_PREFIXES`):

| Prefix | Purpose |
|---|---|
| `BROWSER_SKILL_*`     | skill internals (`BROWSER_SKILL_HOME`, trace ID, etc.) |
| `BROWSER_STATS_*`     | post-condition contract + model-name injection |
| `CLAUDE_*`            | `CLAUDE_MODEL`, `CLAUDE_USAGE_*`, `CLAUDE_SESSION_ID` |
| `MIDSCENE_MODEL_*`    | local-VLM endpoint config (one envvar block reaches BOTH our skill AND midscene) |
| `PLAYWRIGHT_*`        | adapter knobs + test injection |
| `CHROME_DEVTOOLS_*`   | cdt-mcp adapter knobs |
| `OBSCURA_*`           | obscura adapter knobs |
| `STUB_*` / `FIXTURES_*` | test-only seams |
| `MCP_*`               | reserved for future MCP overrides |

Everything else (e.g. arbitrary `OPENAI_API_KEY` or unknown secrets in the
client process) is filtered out. This is the AP-7-aligned default — opt-in
later via expanding the whitelist, not via removing it.

## Smoke test

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | bash scripts/browser-mcp.sh serve
```

Expected output (two NDJSON lines): an `initialize` reply with
`protocolVersion: "2024-11-05"` + a `tools/list` reply enumerating
`browser_open`, `browser_snapshot`, `browser_click`, `browser_fill`,
`browser_extract`, and `browser_list-sites`.

## Wiring from Claude Code

Add to `~/.claude/config.json` (or per-project):

```json
{
  "mcpServers": {
    "browser-skill": {
      "command": "bash",
      "args": ["/abs/path/to/scripts/browser-mcp.sh", "serve"]
    }
  }
}
```

After Claude Code restart, the six `browser_*` tools appear in the tool list.
They run against the same `~/.browser-skill/` state (sites, sessions, captures,
memory) as the bash entry points — one cache, two surfaces.

## Wiring from OpenAI Codex

MCP-only install:

```bash
codex mcp add browser-skill -- npx -y browser-automation-skill@latest serve
codex mcp list
```

Full plugin install from GitHub:

```bash
codex plugin marketplace add xicv/browser-automation-skill
codex plugin add browser-automation-skill@browser-automation-skill
```

Codex stores MCP and plugin enablement in `~/.codex/config.toml`; the Codex CLI
and app/IDE share that configuration.

Verify with `codex plugin list` and `/mcp`. The bundled skill may appear in
`/skills` as `browser-automation-skill` or as the plugin-qualified
`browser-automation-skill:browser-automation-skill`; plugin skills do not have
to exist as standalone entries under `~/.codex/skills`.

## Why this exists

- **Cache reuse**: `browser-do` archetype cache + Phase 13 fingerprint rescue
  apply automatically when called via MCP — the bash verb is the same entry
  point either way.
- **Telemetry parity**: every MCP `tools/call` results in one `stats.jsonl`
  event (same as a direct bash call), so `browser-stats report` shows MCP
  and direct calls in one table.
- **Secrets stay local**: the MCP server spawns the same `scripts/browser-*.sh`
  verbs, which honour AP-7 (no secrets in argv). MCP clients NEVER see
  credentials.

## Limitations (Stage 1 + 2)

- 6 verbs exposed (open + snapshot + click + fill + extract + list-sites). The other ~38
  verbs (site / session / credential management, flow runner, capture mgmt,
  stats, baseline, schema migration) are reachable only via direct bash.
  Stage 3 candidates: `browser_wait`, `browser_press`, `browser_select`,
  `browser_assert`.
- No streaming progress events — request/response only. MCP supports
  `notifications/progress`; wiring it is a Stage 3 task.
- No tool-side authorization. Anything that can spawn the server can call any
  verb. The skill's existing per-verb typed-phrase confirmations (e.g.
  `--yes-i-know` on destructive ops) still apply at the bash boundary.
- `browser_extract` does NOT expose `--scrape` (multi-URL batch mode) — too
  many args and the output shape changes. Use `scripts/browser-extract.sh`
  directly for that.

## Environment

| Var | Meaning | Default |
|---|---|---|
| `BROWSER_SKILL_NODE_BIN` | Node binary used by `browser-mcp.sh serve` | `node` |
