---
name: browser-automation-skill
description: Drive and verify real-browser work from OpenAI Codex using the bundled browser-skill MCP server and local CLI. Use when Codex needs to open a page, capture an accessibility snapshot, click or fill elements, extract page data, list registered sites, debug a UI, run a daily browser job, or choose between MCP, cached CLI verbs, flow replay, and opt-in Webwright/GLM delegation.
---

# Browser Automation Skill for Codex

Use this skill when Codex needs a real browser rather than static HTTP fetching. Start with the bundled MCP tools for simple interactions, then switch to the local CLI surface when the task needs credentials, sessions, flows, cache, telemetry, or stronger safety controls.

## Context isolation

Browser output (snapshots, DOM, console/network captures, Lighthouse) is verbose and
fills the main context fast. When the host supports a subagent / isolated worker
(Claude Code ships a bundled `browser-worker` agent for exactly this), run the browser
task there and surface only a compact summary, so the verbose intermediate output never
reaches the main thread. With no subagent available (plain Codex), call the verbs
directly and keep returns terse — reference capture IDs/paths instead of pasting raw
snapshots or HAR.

## Preferred route order

1. **MCP tools for simple no-secret interactions.** They are compact and cross-client.
2. **Local CLI for stateful or sensitive work.** Secrets, stored sessions, destructive confirmations, capture history, flow replay, memory cache, and telemetry live under `~/.browser-skill/` and should be handled by the bash verbs.
3. **Cached/replayable automation for daily jobs.** Prefer `browser-do`, `flow run`, or `replay` when the operation is known.
4. **Delegation only for novel no-auth long-horizon tasks.** Check `browser-delegate.sh config get`; delegate only when allowed by policy and the task is non-destructive and credential-free.

## MCP tools

Use these tools first when available:

- `browser_open` — open a URL.
- `browser_snapshot` — capture an `eN`-indexed accessibility snapshot.
- `browser_click` — click by `eN` ref or CSS selector.
- `browser_fill` — fill by `eN` ref or CSS selector with non-secret text.
- `browser_extract` — extract text by selector or evaluate page JavaScript.
- `browser_list-sites` — list registered local site profiles.

Prefer `eN` refs from the latest `browser_snapshot` for immediate clicks/fills. Prefer stable selectors for repeated jobs that will be cached or moved into a flow. Do not reuse refs after a full navigation or major DOM change without taking a fresh snapshot.

## Local CLI examples

From a repository checkout, use the scripts directly:

```bash
bash scripts/browser-doctor.sh
bash scripts/browser-add-site.sh --name myapp --url 'https://app.example.com'
bash scripts/browser-use.sh --set myapp
bash scripts/browser-open.sh --url 'https://app.example.com'
bash scripts/browser-snapshot.sh
bash scripts/browser-inspect.sh --capture-console --capture-network --screenshot
bash scripts/browser-stats.sh report --days 7 --pareto
```

For credentialed work, capture or reuse a local session instead of sending secrets through MCP:

```bash
bash scripts/browser-login.sh --site myapp --as myapp--admin --interactive
bash scripts/browser-open.sh --site myapp --as myapp--admin --url 'https://app.example.com/dashboard'
```

## Verification discipline

After state-changing actions, verify the expected browser state. Do not treat a driver-level `ok` as proof that the business action succeeded.

```bash
BROWSER_STATS_EXPECT_TYPE=url \
BROWSER_STATS_EXPECT_MATCH=include \
BROWSER_STATS_EXPECT_VALUE='/dashboard' \
  bash scripts/browser-open.sh --url 'https://app.example.com/dashboard'
```

Use `browser-stats report --pareto` to find slow, expensive, or unreliable route × verb combinations and `browser-stats prune --dry-run` before disabling bad cached selectors.

## Safety constraints

- Never pass passwords, API keys, bearer tokens, cookies, TOTP seeds, or other secrets through MCP tool arguments.
- Use local credential/session workflows for secrets.
- Do not use delegated Webwright/GLM runs for credentialed, payment, deletion, production-admin, or account/security tasks.
- Treat `~/.browser-skill/` as personal local state; never copy it into the repository.
- Every CLI verb emits a final single-line JSON summary. Route on `.status` and inspect `.why`, `.problems`, or capture paths for recovery.
