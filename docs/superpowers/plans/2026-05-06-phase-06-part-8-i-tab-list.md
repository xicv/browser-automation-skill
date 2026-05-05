# Phase 6 part 8-i — `tab-list` verb foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Multi-tab daemon-state foundation. Daemon gains `tabs[]` slot. `tab-list` verb returns the array of `{tab_id, url, title}` so the agent can name a tab in 8-ii (`tab-switch`) / 8-iii (`tab-close`).

**Branch:** `feature/phase-06-part-8-i-tab-list`
**Tag:** `v0.29.0-phase-06-part-8-i-tab-list`.

---

## Surface

```
bash scripts/browser-tab-list.sh
# → {verb:'tab-list', tool:'chrome-devtools-mcp', why:'mcp/list_pages',
#    status:'ok', tabs:[{tab_id:1, url:'https://...', title:'...'}, ...],
#    tab_count:N, attached_to_daemon:true}
```

No required flags. Daemon-required (without daemon → exit 41 with hint, mirrors `route` precedent). The daemon caches the list in its `tabs[]` slot so 8-ii/8-iii can mutate the same shape.

---

## Why split 8-i from 8-ii / 8-iii

`tab-list` is read-only enumeration. `tab-switch` adds first state-mutation on `tabs[]` (current-tab pointer + mutex flags `--by-index N` ⊕ `--by-url-pattern STR`). `tab-close` removes from `tabs[]` + asks the upstream MCP to close the page. Each carries new flags, new fixture variants, new error paths — landing them as one PR triples the diff.

8-i is the smallest reviewable PR with user-visible value: it sets the JSON shape (`tab_id`, `url`, `title`) every later verb reads/writes.

---

## File Structure

### New
- `scripts/browser-tab-list.sh` — verb script, no required flags.
- `tests/browser-tab-list.bats` — bash-side cases.
- `docs/superpowers/plans/2026-05-06-phase-06-part-8-i-tab-list.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_tab_list_default` slotted after `rule_route_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-list` capability + `tool_tab-list` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabListViaDaemon` (parallel to `runRouteViaDaemon`, no args). Daemon child gains `tabs` state slot (array). Dispatch case `'tab-list'` calls MCP `list_pages`, normalizes the result to `[{tab_id, url, title}]`, caches in `tabs`, returns the cache.
- `tests/stubs/mcp-server-stub.mjs` — `list_pages` handler returning a canned 2-tab array.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy (returns array), shape preserved across calls (idempotent), no-daemon exit-41.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 8-i subsection.

---

## Daemon state

`tabs` is the third daemon-side state slot (after `refMap` and `routeRules`). When 8-ii lands, a `currentTab` pointer joins (initially `tabs[0]?.tab_id`). When 8-iii lands, mutations splice out by `tab_id`. Both still simple closures inside `daemonChildMain`; a `DaemonState` object refactor is deferred until the slots interact (e.g. per-tab refMap in Phase 7+).

`tab_id` is the **bridge-assigned** index (1-based, stable for the lifetime of one `list_pages` call). Upstream MCP's actual page handle (CDP target id, page object handle) lives only inside the bridge's `tabs[]` cache — agents never see it. This avoids tying the agent's stable contract to a Chrome-internal id that may rotate.

---

## Wire shape (daemon dispatch)

```javascript
case 'tab-list': {
  const result = await mcpCall('list_pages', {});
  // Normalize: upstream may return {pages:[...]} or array directly.
  const raw = result?.pages ?? result?.tabs ?? [];
  tabs = raw.map((p, i) => ({
    tab_id: i + 1,
    url:    p.url   ?? '',
    title:  p.title ?? '',
  }));
  return {
    verb: 'tab-list',
    tool: 'chrome-devtools-mcp',
    why:  'mcp/list_pages',
    status: 'ok',
    tabs,
    tab_count: tabs.length,
    attached_to_daemon: true,
  };
}
```

---

## Test approach

`tests/browser-tab-list.bats` (5 cases) — bash-side: `--tool=ghost-tool` → usage error, `--tool=playwright-cli` → capability filter rejects (no `tab-list` in playwright-cli capabilities), `--dry-run` shape, router (`pick_tool tab-list` → cdt-mcp), no-other-flags happy (against stub).

`tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy: `tab-list` returns `tabs` array of length 2 with `tab_id`/`url`/`title` shape and `tab_count==2`; idempotent: two calls return identical shape (cache replaced, not appended); no-daemon: exit 41 with `requires running daemon` stderr.

Stub returns 2 canned pages so the e2e test can assert `tab_count==2`.

---

## Out of scope (defer to 8-ii / 8-iii)

- `tab-switch --by-index N` / `--by-url-pattern STR` (mutex). Updates `currentTab`.
- `tab-close --tab-id N` / `--by-url-pattern STR`. Removes from `tabs[]` + closes upstream page.
- Active-tab annotation in `tab-list` output (waits on `currentTab` from 8-ii).
- Real upstream binding (canonical MCP tool name; `list_pages` is the bridge's best-effort name — upstream may use `pages.list`, `targets.list`, etc.).

---

## Tag + push

```
git tag v0.29.0-phase-06-part-8-i-tab-list
git push -u origin feature/phase-06-part-8-i-tab-list
git push origin v0.29.0-phase-06-part-8-i-tab-list
gh pr create --title "feat(phase-6-part-8-i): tab-list verb foundation"
```
