# Phase 6 part 8-iii — `tab-close` verb (last tab-* verb)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close a tab. Splices the matching entry out of `tabs[]` and asks the upstream MCP to close the page. Invalidates `currentTab` if the closed tab matches.

**Branch:** `feature/phase-06-part-8-iii-tab-close`
**Tag:** `v0.31.0-phase-06-part-8-iii-tab-close`.

---

## Surface

```
bash scripts/browser-tab-close.sh --tab-id 2
bash scripts/browser-tab-close.sh --by-url-pattern "tracking"
```

Daemon-required. Mutex on the two flags (exactly one must be supplied). Symmetric with `tab-switch` shape but `--tab-id` (matches the canonical id) instead of `--by-index` (positional).

Output shape:
```json
{
  "verb": "tab-close",
  "tool": "chrome-devtools-mcp",
  "why": "mcp/close_page",
  "status": "ok",
  "closed_tab": { "tab_id": 2, "url": "https://example.org/news", "title": "News" },
  "current_tab_id": null,
  "tab_count": 1,
  "attached_to_daemon": true
}
```

---

## Why `--tab-id` (not `--by-index`)

By the time agents reach `tab-close`, they've called `tab-list` and have the canonical `tab_id`. Passing the id directly is unambiguous; using a 1-based positional index for a destructive operation is footgun-territory (the array shrinks on every prior close — index drift). `--tab-id 2` always closes "the tab whose id was 2" regardless of how many other tabs got closed before it.

`--by-url-pattern STR` keeps the same substring-contains semantics as `tab-switch`.

---

## Daemon-side semantics

1. Auto-refresh `tabs[]` if empty (mirrors tab-switch's friendliness).
2. Resolve selector → tab object. If not found → error event.
3. Call upstream MCP `close_page` (best-effort name) with the tab handle.
4. Splice the entry from `tabs[]`.
5. **Reassign `tab_id` on remaining tabs**? No — `tab_id` stays fixed for the lifetime of the daemon. Splicing leaves a "hole" (e.g. closing id=2 from `[id:1, id:2, id:3]` yields `[id:1, id:3]`). Reasoning:
   - Agents holding a `tab_id` reference (from a prior `tab-list`) shouldn't see it silently rebound to a different page.
   - `tab-list` re-call replaces wholesale anyway, so consumers get fresh ids on demand.
   - This means `tabs[N-1].tab_id` is NOT necessarily `N` after closes — that's the price of stable ids.
6. If `currentTab === closed.tab_id` → set `currentTab = null`. Agents see `current_tab_id: null` in subsequent `tab-list` outputs.

---

## File Structure

### New
- `scripts/browser-tab-close.sh` — verb script, mutex flags.
- `tests/browser-tab-close.bats` — bash-side cases.
- `docs/superpowers/plans/2026-05-06-phase-06-part-8-iii-tab-close.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_tab_close_default` slotted after `rule_tab_switch_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-close` capability + `tool_tab-close` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabCloseViaDaemon`. Dispatch case `'tab-close'` resolves selector → tab object, calls MCP `close_page`, splices `tabs[]`, nulls `currentTab` on match, returns `{closed_tab, current_tab_id, tab_count}`.
- `tests/stubs/mcp-server-stub.mjs` — `close_page` handler (19th tool).
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — by-tab-id happy + splice observed; by-url-pattern happy; closing currentTab nulls it; closing non-current preserves it; no-daemon exit-41.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 8-iii subsection.

---

## Test approach

`tests/browser-tab-close.bats` (7 cases) — bash-side:
- Missing both flags → usage error.
- Both flags supplied → mutex error.
- `--tab-id 0` → usage error (1-based).
- `--by-url-pattern ""` → usage error.
- Ghost-tool, capability filter, dry-run, router routing.

`tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — daemon-side:
- `--tab-id 2` happy: `closed_tab.tab_id == 2`, `tab_count == 1`, `close_page` MCP call observed, subsequent `tab-list` shows the tab gone.
- `--by-url-pattern news` happy: resolves to tab 2, splices.
- Close current tab → `current_tab_id` becomes `null` post-close.
- Close non-current tab → `current_tab_id` preserved.
- No-match pattern → error event.
- Out-of-range tab-id → error event.
- No-daemon → exit 41.

---

## Out of scope (defer to future Phase 6 cleanup or Phase 7+)

- `tab-open --url URL` (creating tabs). Out of Phase 6 scope.
- Auto-pick a fallback `currentTab` when the active tab is closed (e.g. switch to first remaining). Could surprise agents — better to make them explicit.
- `--tab-id` validation that the id was ever issued (currently we treat unknown ids as "out of range" against current tabs[]).

---

## Tag + push

```
git tag v0.31.0-phase-06-part-8-iii-tab-close
git push -u origin feature/phase-06-part-8-iii-tab-close
git push origin v0.31.0-phase-06-part-8-iii-tab-close
gh pr create --title "feat(phase-6-part-8-iii): tab-close verb (last tab-* verb)"
```
