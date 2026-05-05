# Phase 6 part 5 — `drag` verb (pointer drag src → dst by refs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Pointer drag from one element to another. Both refs (src + dst) translated to uids server-side via daemon's refMap. MCP `drag` tool accepts `{src_uid, dst_uid}`.

**Branch:** `feature/phase-06-part-5-drag`
**Tag:** `v0.26.0-phase-06-part-5-drag`.

---

## Surface

```
bash scripts/browser-drag.sh --src-ref e3 --dst-ref e7
```

Both `--src-ref` and `--dst-ref` required. Stateful — daemon-required (refMap precondition for both refs).

Selector-based drag (`--src-selector` / `--dst-selector`) deferred to follow-up.

---

## File Structure

### New
- `scripts/browser-drag.sh` — verb script.
- `tests/browser-drag.bats` — 6 cases.
- `docs/superpowers/plans/2026-05-05-phase-06-part-5-drag.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_drag_default` slotted after `rule_wait_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `drag` capability + `tool_drag` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — drag has 2-ref argv shape; daemon dispatch `case 'drag'` resolves both refs.
- `tests/stubs/mcp-server-stub.mjs` — `drag` handler.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon happy, no-daemon, unknown src ref, unknown dst ref.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 5 subsection.

---

## Why drag is special

First verb in this codebase with 2-ref argv shape. Pre-5: stateful verbs all used `<verb> <ref> [...rest]`. Drag uses `drag <src-ref> <dst-ref>`. Daemon dispatch translates BOTH refs separately (each with its own error path on missing-ref).

Sets the precedent for any future N-ref verbs (multi-element selection, batch click). The 2-ref pattern is also what `tab-switch --by-current-window` doesn't need but `select-multiple` would.

---

## Tag + push

```
git tag v0.26.0-phase-06-part-5-drag
git push -u origin feature/phase-06-part-5-drag
git push origin v0.26.0-phase-06-part-5-drag
gh pr create --title "feat(phase-6-part-5): drag verb (pointer drag src → dst via daemon)"
```
