# Phase 6 part 2 — `select` verb (`<select>` option pick by ref)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Phase 6's first stateful bulk verb. `select` picks an `<option>` from a `<select>` element by `eN` ref + exactly one of value / label / index. Mirrors click/fill in shape (stateful + daemon-required).

**Branch:** `feature/phase-06-part-2-select`
**Tag:** `v0.23.0-phase-06-part-2-select`.

---

## Surface

```
bash scripts/browser-select.sh --ref e3 --value "us-east-1"
bash scripts/browser-select.sh --ref e3 --label "US East (N. Virginia)"
bash scripts/browser-select.sh --ref e3 --index 2
```

Exactly one of `--value` / `--label` / `--index` required (mutex enforced).

Stateful: requires running daemon. Without daemon → exit 41 with hint.

---

## File Structure

### New
- `scripts/browser-select.sh` — verb script.
- `tests/browser-select.bats` — 7 cases (missing-ref, missing-mode, mutex, ghost-tool, cap-filter, dry-run, router).
- `docs/superpowers/plans/2026-05-05-phase-06-part-2-select.md` — this plan.

### Modified
- `scripts/lib/router.sh` — new `rule_select_default` → chrome-devtools-mcp.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `select` capability + `tool_select` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — extended for `select` argv parsing; daemon `dispatch.case 'select'` translates ref → uid + calls MCP `select_option`.
- `tests/stubs/mcp-server-stub.mjs` — `select_option` handler.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — value/label/index happy paths + no-daemon + unknown-ref.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 2 subsection.

### Untouched
- All other verb scripts.
- playwright-cli/lib adapters (could declare select via `selectOption` API in follow-up).
- Credentials / session libs.

---

## Test approach

Use the same daemon-stateful pattern as click/fill: snapshot first to populate refMap with `cdp-uid-1234`, then exercise select. Stub's `select_option` handler echoes `selected <uid> by <mode>=<val>`. Bats verifies stub log captures correct args + reply shape includes ref/uid/mode-field.

---

## Tag + push

```
git tag v0.23.0-phase-06-part-2-select
git push -u origin feature/phase-06-part-2-select
git push origin v0.23.0-phase-06-part-2-select
gh pr create --title "feat(phase-6-part-2): select verb (<select> option pick via daemon)"
```
