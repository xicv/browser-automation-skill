# Phase 6 part 1 — `press` verb (keyboard input via cdt-mcp)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Phase 6 opens with the smallest pure stateless verb. `press` issues a keyboard event (Enter / Tab / Escape / ArrowDown / Cmd+S / etc.) via chrome-devtools-mcp's `press_key` MCP tool. No ref needed — acts on the focused element or page. Foundation for the rest of the bulk-verbs phase.

**Branch:** `feature/phase-06-part-1-press`
**Tag:** `v0.22.0-phase-06-part-1-press`.

---

## File Structure

### New
- `scripts/browser-press.sh` — verb script.
- `tests/browser-press.bats` — 6 cases.
- `docs/superpowers/plans/2026-05-05-phase-06-part-1-press.md` — this plan.

### Modified
- `scripts/lib/router.sh` — new `rule_press_default` → chrome-devtools-mcp.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `press` capability + `tool_press` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — daemon dispatch + one-shot `press` → MCP `press_key`; shapeResponse press case.
- `tests/stubs/mcp-server-stub.mjs` — `press_key` handler.
- `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot press.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed press.
- `SKILL.md` — auto-regenerated tools table.
- `references/chrome-devtools-mcp-cheatsheet.md` — auto-regenerated cap table.
- `CHANGELOG.md` — Phase 6 part 1 subsection.

### Untouched
- `playwright-cli` / `playwright-lib` adapters — could declare press via `keyboard.press` in follow-up.
- All other verb scripts.
- Credentials / session / site libs.

---

## Why press first in Phase 6

Of the bulk verbs in parent spec Appendix A:
- `press` — pure stateless keyboard, no ref, single MCP tool. **Smallest.**
- `select` — needs ref + value/label/index. State-dependent (refMap).
- `hover` / `drag` — pointer events, refMap-dependent.
- `wait` — element visibility polling; needs selector + state.
- `route` — request interception; net-new MCP capability surface.
- `tab-*` — multi-tab state; daemon needs new state slots.

Press establishes the Phase 6 sub-part pattern (capability declaration + dispatch + verb script + router rule + tests) on the simplest verb. Subsequent sub-parts replicate.

---

## Test approach

`tests/browser-press.bats` (6 cases):
1. `--key Enter` lib-stub path → exit 41 (fixture miss expected; routing path exercised).
2. Missing `--key` → EXIT_USAGE_ERROR.
3. `--tool=ghost-tool` → EXIT_USAGE_ERROR.
4. `--tool=playwright-cli` → EXIT_USAGE_ERROR (capability filter rejects).
5. `--dry-run` skips adapter, summary has `dry_run: true`.
6. `pick_tool press` → chrome-devtools-mcp.

Plus +1 case in `tests/chrome-devtools-bridge_real.bats` (one-shot real-mode against stub MCP) and +1 in `tests/chrome-devtools-mcp_daemon_e2e.bats` (daemon-routed press).

---

## Tag + push

```
git tag v0.22.0-phase-06-part-1-press
git push -u origin feature/phase-06-part-1-press
git push origin v0.22.0-phase-06-part-1-press
gh pr create --title "feat(phase-6-part-1): press verb (keyboard input via cdt-mcp)"
```
