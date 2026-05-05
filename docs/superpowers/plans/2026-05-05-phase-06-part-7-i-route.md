# Phase 6 part 7-i — `route` verb foundation (block + allow)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Network-route rule registration. Daemon-side stores `{pattern, action}` rules; runtime application of rules to actual network requests is upstream MCP's responsibility.

**Branch:** `feature/phase-06-part-7-route`
**Tag:** `v0.28.0-phase-06-part-7-i-route`.

---

## Surface

```
bash scripts/browser-route.sh --pattern "https://*.tracking.com/*" --action block
bash scripts/browser-route.sh --pattern "https://api.example.com/users/*" --action allow
```

Daemon-required. Without daemon → exit 41 with hint.

`--action fulfill` deferred to part 7-ii.

---

## Why split 7-i from 7-ii

`fulfill` action needs `--status N` + `--body BODY` (or `--body-stdin` per AP-7). Body management adds:
- Stdin-mux for arbitrary content (binary-safe).
- Multi-line body concerns.
- Body persistence in routeRules state.

Substantial enough to deserve its own sub-PR. 7-i ships the foundation (rule storage + simple actions); 7-ii extends with synthetic responses.

---

## File Structure

### New
- `scripts/browser-route.sh` — verb script.
- `tests/browser-route.bats` — 8 cases.
- `docs/superpowers/plans/2026-05-05-phase-06-part-7-i-route.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_route_default` slotted after `rule_upload_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `route` capability + `tool_route` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runRouteViaDaemon` (parallel to `runStatefulViaDaemon`); daemon child gains `routeRules` state slot; dispatch case `'route'` validates action, appends rule, best-effort calls MCP `route_url`.
- `tests/stubs/mcp-server-stub.mjs` — `route_url` handler.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — block happy, 2-call accumulation, invalid action, no-daemon.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 7-i subsection.

---

## Daemon state

`routeRules` is the second daemon-side state slot (after `refMap`). When tab-* lands (part 8), per-tab refMaps will join; could trigger a `DaemonState` object refactor. For now, both refMap + routeRules are simple closures in `daemonChildMain`.

---

## Test approach

`tests/browser-route.bats` (8 cases) — bash-side validation: missing flags, fulfill-rejected (with part 7-ii hint), invalid action, ghost-tool, capability filter, dry-run, router routing.

`tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon-side: block happy (rule registered + MCP ack), accumulation (rule_count grows across calls), invalid-action returns error event, no-daemon exit-41.

---

## Tag + push

```
git tag v0.28.0-phase-06-part-7-i-route
git push -u origin feature/phase-06-part-7-route
git push origin v0.28.0-phase-06-part-7-i-route
gh pr create --title "feat(phase-6-part-7-i): route verb foundation (block + allow)"
```
