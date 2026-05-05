# Phase 6 part 3 — `hover` verb (pointer hover by ref)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Pointer hover. Stateful — `--ref eN` from refMap → uid via daemon → MCP `hover` tool. Mirrors click/select shape.

**Branch:** `feature/phase-06-part-3-hover`
**Tag:** `v0.24.0-phase-06-part-3-hover`.

---

## Surface

```
bash scripts/browser-hover.sh --ref e3
```

Stateful: requires running daemon. Without daemon → exit 41 with hint.

`--selector` path deferred — current shape is `--ref`-only mirroring click/select. If user demand surfaces for selector-based hover (without prior snapshot), add it as a follow-up sub-part.

---

## File Structure

### New
- `scripts/browser-hover.sh` — verb script (~75 LOC).
- `tests/browser-hover.bats` — 5 cases.
- `docs/superpowers/plans/2026-05-05-phase-06-part-3-hover.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_hover_default` slotted after `rule_select_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `hover` capability + `tool_hover` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — `hover` argv parse; daemon dispatch case `'hover'` → MCP `hover` tool with uid.
- `tests/stubs/mcp-server-stub.mjs` — `hover` handler.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy + no-daemon + unknown-ref.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 3 subsection.

---

## Tag + push

```
git tag v0.24.0-phase-06-part-3-hover
git push -u origin feature/phase-06-part-3-hover
git push origin v0.24.0-phase-06-part-3-hover
gh pr create --title "feat(phase-6-part-3): hover verb (pointer hover via daemon)"
```
