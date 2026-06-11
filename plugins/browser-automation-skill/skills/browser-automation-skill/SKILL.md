---
name: browser-automation-skill
description: Drive real browsers from OpenAI Codex using the bundled browser-skill MCP server and local browser automation CLI.
---

# Browser Automation Skill for Codex

Use this skill when Codex needs to inspect, navigate, or interact with a real browser through the bundled `browser-skill` MCP server.

## Preferred MCP flow

Use the MCP tools first when they are available:

- `browser_open`: open a URL.
- `browser_snapshot`: capture an eN-indexed accessibility snapshot.
- `browser_click`: click by eN ref or CSS selector.
- `browser_fill`: fill by eN ref or CSS selector with non-secret text.
- `browser_extract`: extract text by selector or evaluate page JavaScript.
- `browser_list-sites`: list registered local site profiles.

Prefer eN refs from `browser_snapshot` for clicks and fills. Fall back to CSS selectors only when refs are unavailable or stale.

## Safety constraints

Never pass passwords, API keys, tokens, or other secrets through MCP tool arguments. MCP calls are transcript-visible. For secrets, use the local credential and session workflows under `~/.browser-skill/` and the bash CLI paths documented in the repository.

Browser state, sessions, credentials, captures, flows, and telemetry are local. The canonical state directory is `~/.browser-skill/`.

Authenticated delegation is not implemented. `browser-delegate` may only be used
for no-auth tasks today; the future bridge must reuse a validated Playwright
`storageState` only and must never pass passwords, TOTP secrets, or credential
backend payloads to Webwright.

## Full CLI surface

The MCP surface is intentionally curated. For workflows outside the MCP tools, use a repository checkout and run the scripts directly from the repo root, for example:

```bash
bash scripts/browser-doctor.sh
bash scripts/browser-add-site.sh --name myapp --url 'https://app.example.com'
bash scripts/browser-use.sh --set myapp
bash scripts/browser-open.sh --url 'https://app.example.com'
bash scripts/browser-snapshot.sh
```

Every CLI verb prints zero or more streaming JSON lines, then a final single-line JSON summary. Route on `.status` and inspect `.problems`, `.why`, or adapter-specific fields for recovery.

Flows may set top-level `site:` plus `session:` in `.flow.yaml`; `flow run`
injects those as per-step `--site` / `--as` for storageState validation and
daemon routing unless a step overrides them.
