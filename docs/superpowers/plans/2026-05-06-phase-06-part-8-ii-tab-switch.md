# Phase 6 part 8-ii — `tab-switch` verb (first state-mutation on `tabs[]`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Switch the daemon's active tab. Adds `currentTab` pointer (tab_id) to daemon state. Two mutually-exclusive selectors: `--by-index N` (1-based) or `--by-url-pattern STR` (substring-contains).

**Branch:** `feature/phase-06-part-8-ii-tab-switch`
**Tag:** `v0.30.0-phase-06-part-8-ii-tab-switch`.

---

## Surface

```
bash scripts/browser-tab-switch.sh --by-index 2
bash scripts/browser-tab-switch.sh --by-url-pattern "example.com"
```

Daemon-required. Mutex on the two flags (exactly one must be supplied).

Output shape:
```json
{
  "verb": "tab-switch",
  "tool": "chrome-devtools-mcp",
  "why": "mcp/select_page",
  "status": "ok",
  "current_tab": { "tab_id": 2, "url": "https://example.org/news", "title": "News" },
  "attached_to_daemon": true
}
```

---

## Design decisions

### URL match = substring-contains

`--by-url-pattern` matches when `tab.url.includes(pattern)`. Not glob, not regex. Reasoning:
- Most agent flows want "find the tab that has `example.com` in it" — substring is the obvious fit.
- Regex/glob can land later as a separate flag (`--by-url-regex`) without breaking this contract.
- First match wins; if multiple tabs match, the lowest `tab_id` is selected (deterministic).
- Empty pattern → usage error (would match every tab).

### `currentTab` shape = number (the tab_id)

The pointer is the `tab_id` integer, not a copy of the full tab object. Reasoning:
- Single source of truth: tab metadata lives in `tabs[]` only.
- 8-iii (tab-close) splices `tabs[]` — pointer naturally invalidates if it referred to the closed tab.
- `current_tab` field in the output reply IS resolved (full `{tab_id, url, title}`) — agents see the friendly shape; daemon stores the lean form.

### Auto-refresh `tabs[]` if empty

If a `tab-switch` call arrives with `tabs.length === 0`, the daemon dispatches `list_pages` first (transparently, without an extra round-trip to the agent). Reasoning:
- Removes the "you must call tab-list before tab-switch" footgun.
- Agents naturally call `tab-switch` after a navigation that opened a new tab; they shouldn't have to remember to refresh.
- If `list_pages` still returns zero pages → return error event with the empty-tabs message.

### Index is 1-based

Matches `tab_id` semantics from 8-i. `--by-index 1` means "first tab". `--by-index 0` → usage error ("expected 1-based").

---

## Why split 8-ii from 8-iii

8-iii (tab-close) splices `tabs[]` and asks the upstream MCP to close a page. That's a different upstream call (`close_page`), a different error path (closing the active tab → currentTab fallback), and adds the splice mutation pattern. Each verb is self-contained, but landing them as one PR doubles the diff and the test surface.

---

## File Structure

### New
- `scripts/browser-tab-switch.sh` — verb script, mutex flags.
- `tests/browser-tab-switch.bats` — bash-side cases.
- `docs/superpowers/plans/2026-05-06-phase-06-part-8-ii-tab-switch.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_tab_switch_default` slotted after `rule_tab_list_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-switch` capability + `tool_tab-switch` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabSwitchViaDaemon`. Daemon child gains `currentTab` slot (number | null). Dispatch case `'tab-switch'` resolves selector → `tab_id`, calls MCP `select_page`, updates `currentTab`, returns full tab object.
- `tests/stubs/mcp-server-stub.mjs` — `select_page` handler (18th tool).
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — by-index happy, by-url-pattern happy, both flags mutex, by-index out-of-range, no-daemon exit-41.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 8-ii subsection.

---

## Test approach

`tests/browser-tab-switch.bats` (6 cases) — bash-side:
- Missing both flags → usage error.
- Both flags supplied → mutex error.
- `--by-index 0` → usage error (1-based).
- Ghost-tool, capability filter, dry-run, router routing.

`tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — daemon-side:
- by-index 2 → `current_tab.tab_id == 2` + MCP `select_page` called.
- by-url-pattern matching → resolves to first tab with substring; `current_tab.tab_id` set.
- by-url-pattern no match → error event mentioning the pattern.
- by-index out-of-range (e.g. `--by-index 99` against 2-tab stub) → error event.
- no-daemon → exit 41 + hint.

---

## Out of scope (defer to 8-iii)

- `tab-close --tab-id N` / `--by-url-pattern STR`. Splice + upstream `close_page`.
- Active-tab annotation in `tab-list` output (waits on `currentTab` first being introduced — that's THIS PR; the annotation in `tab-list` lands in 8-iii as a one-line fold-in to keep the surface complete).
- Regex / glob URL matching (`--by-url-regex`, `--by-url-glob`).
- Tab-creation (`tab-open --url`). Out of Phase 6 scope; tracked for Phase 7+.

---

## Tag + push

```
git tag v0.30.0-phase-06-part-8-ii-tab-switch
git push -u origin feature/phase-06-part-8-ii-tab-switch
git push origin v0.30.0-phase-06-part-8-ii-tab-switch
gh pr create --title "feat(phase-6-part-8-ii): tab-switch verb (first tabs[] state mutation)"
```
