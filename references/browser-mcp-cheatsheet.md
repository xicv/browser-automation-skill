# browser-mcp — cheatsheet

`scripts/browser-mcp.sh serve` starts an MCP (Model Context Protocol) server
that exposes our verbs as MCP tools. Spawn it from any MCP-capable client
(Claude Code, Continue, Cline, agent-browser, midscene, Stagehand,
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

## Tools exposed (Stage 1)

| Tool | Wraps | Required inputs | Optional |
|---|---|---|---|
| `browser_open`     | `scripts/browser-open.sh`     | `url`        | `site`, `tool` |
| `browser_snapshot` | `scripts/browser-snapshot.sh` | _none_       | `site`, `tool`, `capture` |

Each `tools/call` response carries `content: [{type: "text", text: "<summary JSON>"}]`
where `<summary JSON>` is the verb's last stdout line (per the token-efficient
output spec §3.1). `_meta.exitCode` and `_meta.stderr` are surfaced for
diagnostics.

Stage 2 (followup): `browser_click`, `browser_fill`, `browser_extract`.

## Smoke test

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | bash scripts/browser-mcp.sh serve
```

Expected output (two NDJSON lines): an `initialize` reply with
`protocolVersion: "2024-11-05"` + a `tools/list` reply enumerating
`browser_open` and `browser_snapshot`.

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

After Claude Code restart, the `browser_open` / `browser_snapshot` tools
appear in the tool list. They run against the same `~/.browser-skill/` state
(sites, sessions, captures, memory) as the bash entry points — one cache,
two surfaces.

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

## Limitations (Stage 1)

- Two verbs only (`browser_open`, `browser_snapshot`). The other 40 verbs are
  reachable only via direct bash.
- No streaming progress events — Stage 1 is request/response only. MCP
  supports `notifications/progress`; wiring it is a Stage 3 task.
- No tool-side authorization. Anything that can spawn the server can call any
  verb. The skill's existing per-verb typed-phrase confirmations (e.g.
  `--yes-i-know` on destructive ops) still apply at the bash boundary.

## Environment

| Var | Meaning | Default |
|---|---|---|
| `BROWSER_SKILL_NODE_BIN` | Node binary used by `browser-mcp.sh serve` | `node` |
