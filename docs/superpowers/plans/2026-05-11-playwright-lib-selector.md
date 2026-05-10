# playwright-lib `--selector` driver plumbing — IPC schema extension for fill + click

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Extend playwright-driver.mjs to accept `--selector CSS` for `runFill` + `runClick`, and extend the IPC daemon's `case 'fill':` + `case 'click':` to use `page.locator(selector).first()` when the IPC message carries `selector`. Closes the gap noted in selector-mode-fill (PR #99 S2): "playwright-lib `--selector` deferred — driver IPC schema bump; coordinate with click in its own PR."

**Branch:** `playwright-lib-selector`
**Tag:** `v0.55.0-playwright-lib-selector`

---

## Locked decisions

- **PL1 — Backwards-compatible IPC schema (no version bump).** Extend `{verb, ref}` → `{verb, ref?, selector?}` with mutual-exclusion + at-least-one validation. The existing `--ref` path remains unchanged; new IPC messages with `selector` use locator-based resolution. **No `schema_version` bump** because the message shape is additive — old senders (sending only `ref`) work as before; new senders (sending `selector`) work too. Cleaner deprecation path; no parallel-message-shape window required.
- **PL2 — Coordinate fill + click together in this PR.** Driver IPC schema changes for fill should land alongside click since both use the same locator path; shipping them separately would create a brief window where IPC accepts `selector` for one but not the other (more confusing to debug). Same PR; matched semantics.
- **PL3 — `page.locator(selector).first()` for selector path.** Mirrors `locatorFor()`'s `.first()` semantics for refMap entries (lib/node/playwright-driver.mjs:830). First match wins; same precedence rule as ref path.
- **PL4 — Hover NOT in scope.** Hover doesn't have a playwright-lib driver path today (hover routes only to chrome-devtools-mcp per `lib/router.sh::rule_hover_default`). No need to extend playwright-lib for hover; if hover routing ever expands to playwright-lib, that's a separate sub-PR.
- **PL5 — Adapter unchanged.** `scripts/lib/tool/playwright-lib.sh::tool_fill` and `tool_click` are already `_drive fill "$@"` / `_drive click "$@"` — they pass argv verbatim to the driver. Driver flag-parser (line 900) already accepts arbitrary `--key value` pairs into `flags.<key>`. So `--selector X` reaches `runFill(flags)` as `flags.selector` without adapter changes.

## Surface

```
# Driver invocation (passed through by adapter)
playwright-driver.mjs fill (--ref eN | --selector CSS) (--text VALUE | --secret-stdin)
playwright-driver.mjs click (--ref eN | --selector CSS)
```

## Implementation strategy

### `scripts/lib/node/playwright-driver.mjs::runFill`

Current (line 119-140):
```js
async function runFill(flags) {
  if (!flags.ref) {
    process.stderr.write('playwright-driver.mjs::fill: --ref eN is required\n');
    process.exit(2);
  }
  ...
  const reply = await ipcCall({ verb: 'fill', ref: flags.ref, text });
}
```

New:
```js
async function runFill(flags) {
  if (flags.ref && flags.selector) {
    process.stderr.write('playwright-driver.mjs::fill: --ref and --selector are mutually exclusive\n');
    process.exit(2);
  }
  if (!flags.ref && !flags.selector) {
    process.stderr.write('playwright-driver.mjs::fill: --ref eN or --selector CSS is required\n');
    process.exit(2);
  }
  ...
  const ipcMsg = { verb: 'fill', text };
  if (flags.ref) ipcMsg.ref = flags.ref;
  else ipcMsg.selector = flags.selector;
  const reply = await ipcCall(ipcMsg);
}
```

### `scripts/lib/node/playwright-driver.mjs::runClick`

Current (line 109-117):
```js
async function runClick(flags) {
  if (!flags.ref) {
    process.stderr.write('playwright-driver.mjs::click: --ref eN is required\n');
    process.exit(2);
  }
  const reply = await ipcCall({ verb: 'click', ref: flags.ref });
}
```

New: same shape as runFill (mutual-exclusion + at-least-one validation; ipcMsg conditional).

### `scripts/lib/node/playwright-driver.mjs` IPC handlers

`case 'click':` (line 704-715) currently does refMap lookup. New branch: if `msg.selector` present, use `page.locator(msg.selector).first().click()` directly. Skip refMap requirement (snapshot precondition no longer required for selector path — locators don't need refMap).

`case 'fill':` (line 717-744) same shape.

```js
case 'click': {
  if (!page) return { event: 'error', message: 'no open page' };
  if (msg.selector) {
    try {
      await page.locator(msg.selector).first().click();
    } catch (err) {
      return { event: 'error', message: `click failed: ${err?.message ?? String(err)}` };
    }
    return { event: 'click', selector: msg.selector, status: 'ok' };
  }
  // Existing ref path (unchanged):
  if (!refMap) return { event: 'error', message: 'no refs (run snapshot first)' };
  const entry = refMap.find((r) => r.id === msg.ref);
  ...
}
```

For `case 'fill':`, preserve the secret-scrubbing wrap (line 728-736) — same try/catch shape applies to selector path.

## Test cases (RED → GREEN)

`tests/playwright-lib_adapter.bats` (gains 4 cases — driver parse layer; daemon IPC tested in e2e):

1. `playwright-driver.mjs fill --selector X --ref e1 --text Y` → exit 2 + stderr "mutually exclusive".
2. `playwright-driver.mjs fill --text Y` → exit 2 + stderr "--ref eN or --selector CSS".
3. `playwright-driver.mjs click --selector X --ref e1` → exit 2 + "mutually exclusive".
4. `playwright-driver.mjs click` → exit 2 + "--ref eN or --selector CSS".

**Daemon IPC tests not added in this PR.** The `case 'click':` / `case 'fill':` selector branches need a live daemon + open page to verify; that's stateful e2e territory. Code review covers correctness; integration smoke happens when an agent uses `browser-do --verb fill` against a playwright-lib-routed flow (e.g. with `BROWSER_SKILL_STORAGE_STATE` set).

## Sub-scope (what this PR does NOT do)

- **No hover plumbing** (PL4; hover doesn't have a playwright-lib path).
- **No IPC schema version bump** (PL1; backwards-compatible additive).
- **No daemon e2e tests** for selector path — covered by parse-layer + code review; e2e is its own session-scoped surface.
- **No adapter changes** (PL5; existing `_drive fill "$@"` / `_drive click "$@"` pass argv verbatim).
- **No browser-do whitelist changes** — fill + click already in whitelist (PRs #99 + earlier); this PR widens the dispatch surface for them, doesn't change which verbs are dispatchable.

## Acceptance

- `tests/playwright-lib_adapter.bats` + 4 new cases all green.
- Full bats green; lint exit 0.
- `playwright-driver.mjs fill --selector 'input.email' --text alice` reaches the IPC layer (parse passes); daemon presence is what determines success/error from there.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **Daemon e2e for selector path** — write `tests/playwright-lib_stateful_e2e.bats` cases that spin up the daemon, open a page, then fill/click via `--selector`. Independent from this PR; can land later.
- **runHover --selector** — if hover routing ever expands to playwright-lib (currently chrome-devtools-mcp-only per `lib/router.sh::rule_hover_default`), add `runHover` flag handling + IPC `case 'hover':` selector branch. Same shape as fill/click in this PR.
- **runSelect --selector** — playwright-lib doesn't currently define `runSelect`; if it ever does, follow this PR's pattern.
- **Schema-version bump for IPC** — if a future change breaks backwards-compat, then bump. v1 stays unchanged for now.
