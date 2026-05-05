# Phase 6 part 4 — `wait` verb (explicit element-state wait)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Explicit wait for an element to reach a state. `--selector CSS` (required), `--state visible|hidden|attached|detached` (default visible), `--timeout MS` (optional). Stateless — one-shot or daemon-routed (parallel to eval/audit).

**Branch:** `feature/phase-06-part-4-wait`
**Tag:** `v0.25.0-phase-06-part-4-wait`.

---

## Surface

```
bash scripts/browser-wait.sh --selector ".dashboard" --state visible --timeout 5000
bash scripts/browser-wait.sh --selector ".loader" --state hidden
bash scripts/browser-wait.sh --selector ".toast"
```

State validation in verb script: `{visible, hidden, attached, detached}`. Other values → EXIT_USAGE_ERROR.

---

## File Structure

### New
- `scripts/browser-wait.sh` — verb script.
- `tests/browser-wait.bats` — 6 cases.
- `docs/superpowers/plans/2026-05-05-phase-06-part-4-wait.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_wait_default` slotted after `rule_hover_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `wait` capability + `tool_wait` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs` — `translateVerb` / `shapeResponse` / `runStatelessViaDaemon` / daemon dispatch all gain `wait` cases. Passes `{selector, state?, timeout?}` to MCP `wait_for`.
- `tests/stubs/mcp-server-stub.mjs` — `wait_for` handler.
- `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot wait.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed wait.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 4 subsection.

---

## Tag + push

```
git tag v0.25.0-phase-06-part-4-wait
git push -u origin feature/phase-06-part-4-wait
git push origin v0.25.0-phase-06-part-4-wait
gh pr create --title "feat(phase-6-part-4): wait verb (explicit element-state wait)"
```
