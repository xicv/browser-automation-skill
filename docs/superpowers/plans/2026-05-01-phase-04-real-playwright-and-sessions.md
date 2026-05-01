# Phase 4 — Real Playwright (node-bridge adapter) + session loading

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the second concrete adapter — `scripts/lib/tool/playwright-lib.sh` — backed by a small Node ESM driver (`scripts/lib/node/playwright-driver.mjs`) that talks the real `playwright` package. Wire session loading (`--site NAME` / `--as SESSION`) into verb scripts so a stored storageState applies to the launched context before the adapter dispatches the verb. Replace the `tool=playwright-lib-stub` carry-forward in `scripts/browser-login.sh`.

**Architecture choice — stub-mode driver:** The Node driver supports `BROWSER_SKILL_LIB_STUB=1` mode that emits canned JSON shaped like the real driver without launching a browser. This keeps the bats suite + CI portable across machines without Playwright installed. Real-browser e2e tests live in a separate `tests/e2e/` suite gated by `command -v playwright`; deferred to a follow-up plan.

**Tech stack:** Bash 4+, node ≥ 20 (existing required check), jq, bats-core, the playwright npm package (loaded lazily by the driver only when stub mode is off).

**Spec references:**
- Parent spec §1 (storageState session model), §3.3 (adapter contract), §3.5 (site profile schema), §3.7 (session schema).
- Extension-model spec §2 (ABI surface), §4 (routing).
- Token-efficient-output spec §3 (output schema), §6 (capture file layout).
- Add-a-tool-adapter recipe — Path A applies (we're adding a new adapter; we DO promote it to default for one verb in Path B inside this plan since `login` cannot work via the stub-only playwright-cli adapter).

**Branch:** `feature/phase-04-real-playwright-and-sessions`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/node/playwright-driver.mjs` | ESM helper: launch chromium, optional storageState load, dispatch one verb, emit shaped JSON | ≤ 300 LOC |
| `scripts/lib/tool/playwright-lib.sh` | Second concrete adapter (shells to node driver) | ≤ 250 LOC |
| `tests/stubs/node-playwright-driver` | Stub binary mirroring the driver's argv → JSON contract | ≤ 80 LOC |
| `tests/fixtures/playwright-lib/<argv-hash>.json` | Per-argv canned responses (3–4 to start) | small |
| `tests/playwright-lib_adapter.bats` | Adapter contract + verb dispatch via stub | ≤ 250 LOC |
| `references/playwright-lib-cheatsheet.md` | User-facing cheatsheet | ≤ 200 LOC |
| `tests/session-loading.bats` | Session-loading integration tests for verb scripts | ≤ 200 LOC |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/router.sh` | Add `rule_session_required` → playwright-lib (Path B promotion) | +~15 LOC |
| `scripts/lib/verb_helpers.sh` | Add `resolve_session_storage_state` helper: maps `--site`/`--as` → storageState path | +~40 LOC |
| `scripts/browser-open.sh` | Call `resolve_session_storage_state`; pass `BROWSER_SKILL_STORAGE_STATE` env to adapter | +~10 LOC |
| `scripts/browser-login.sh` | Replace `tool=playwright-lib-stub` summary tag with real `tool=playwright-lib` (Phase 2 carry-forward) | +~5 LOC, -~5 LOC |
| `SKILL.md` | Add `--site NAME --as SESSION` example to verbs table; regen autogen Tools block | +~3 LOC |
| `references/tool-versions.md` | Autogen — picks up playwright-lib | regen |
| `CHANGELOG.md` | New `### Phase 4` subsection | +~10 LOC |

### Untouched

- `scripts/lib/common.sh`
- `scripts/lib/output.sh`
- `scripts/lib/site.sh`
- `scripts/lib/session.sh`
- `scripts/lib/tool/playwright-cli.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch from main → `feature/phase-04-real-playwright-and-sessions`.
- [ ] **Step 0.2** Commit plan: `docs: phase-4 plan — playwright-lib adapter + session loading`.

---

## Task 1: Node ESM driver + stub mode

**Files:** Create `scripts/lib/node/playwright-driver.mjs` + `tests/stubs/node-playwright-driver` + 3 fixtures.

The driver is a single ESM file. Argv shape (matches what the adapter passes):

```
node playwright-driver.mjs <verb> [--url URL] [--ref eN] [--selector CSS]
                                  [--text VALUE] [--secret-stdin]
                                  [--storage-state PATH] [--depth N]
                                  [--headed]
```

Output:
- One streaming JSON line per browser event (navigate, click, fill, etc.).
- One terminal JSON line with the verb's primary result (snapshot refs, title, etc.).
- Exit 0 on success; non-zero exit codes mirror the skill's `EXIT_*` table.

**Stub mode** (`BROWSER_SKILL_LIB_STUB=1`):
- The driver does NOT load `playwright`.
- Reads argv, computes `sha256(argv joined by NUL)`, looks up `tests/fixtures/playwright-lib/<hash>.json`.
- Emits the file's contents and exits 0.
- Identical behavior to `tests/stubs/playwright-cli` for testability.

Steps:
- [ ] **1.1** Write `tests/playwright-lib_adapter.bats` skeleton with 4 stub-mode tests (open, snapshot, click, missing-fixture).
- [ ] **1.2** Run RED.
- [ ] **1.3** Write `scripts/lib/node/playwright-driver.mjs` with stub-mode branch up front:
  - Top-level `if (process.env.BROWSER_SKILL_LIB_STUB === '1') { stub_dispatch(); process.exit(0); }`
  - `stub_dispatch()` reads argv, hashes, reads fixture, prints, exits.
  - The real-mode block is a stub (`throw new Error('real mode not yet implemented; set BROWSER_SKILL_LIB_STUB=1')`) — wired in a follow-up plan.
- [ ] **1.4** Compute argv hashes for 3 fixtures (open, snapshot, click); create the fixture files.
- [ ] **1.5** Run GREEN — adapter contract tests pass against stub.
- [ ] **1.6** Commit: `feat(node): playwright-driver.mjs — stub-mode dispatch (real-mode deferred)`.

---

## Task 2: scripts/lib/tool/playwright-lib.sh adapter

**Files:** Create `scripts/lib/tool/playwright-lib.sh` + `references/playwright-lib-cheatsheet.md`.

The adapter implements the Phase-3 ABI:
- `tool_metadata` — name=playwright-lib, abi_version=1, version_pin pinned to playwright `1.49.x`.
- `tool_capabilities` — declares open/click/fill/snapshot/inspect (same as playwright-cli) PLUS the **session-loading** capability (a non-verb capability key like `"session_load": true` so the routing rule can prefer this adapter when `--as` is set).
- `tool_doctor_check` — checks `node` + `npx --offline playwright --version` (offline avoids network).
- Verb-dispatch fns: shell to `node "$LIB_NODE_DIR/playwright-driver.mjs" <verb> [argv...]`. The adapter sources `output.sh` (lint tier 3 enforces).

Steps:
- [ ] **2.1** Add identity-function tests + verb-dispatch behavior tests (8+ cases) to `tests/playwright-lib_adapter.bats`.
- [ ] **2.2** Run RED.
- [ ] **2.3** Write `scripts/lib/tool/playwright-lib.sh`.
- [ ] **2.4** Run GREEN.
- [ ] **2.5** Write `references/playwright-lib-cheatsheet.md` (mirrors playwright-cli-cheatsheet.md but covers the node-bridge specifics + session-loading).
- [ ] **2.6** Run `scripts/regenerate-docs.sh all` to autogen the new adapter row.
- [ ] **2.7** Run `bash tests/lint.sh` — expect static + dynamic + drift all pass.
- [ ] **2.8** Commit: `feat(tool): playwright-lib adapter — node-bridge to real Playwright (stub-validated)`.

---

## Task 3: Session loading wired into verb scripts

**Files:** Modify `scripts/lib/verb_helpers.sh` + `scripts/browser-open.sh` + create `tests/session-loading.bats`.

The flow: when a verb script runs with `--site NAME` and the site profile has `default_session` set (or `--as SESSION` is supplied), look up the session's storageState file under `${SESSIONS_DIR}/<session>.json`, validate origin against the site URL via `session_origin_check` (Phase 2 lib), and pass the file path to the adapter via the `BROWSER_SKILL_STORAGE_STATE` env var.

Adapters that support session-loading (declared in `tool_capabilities`) read `BROWSER_SKILL_STORAGE_STATE` and forward to their driver. The router prefers a session-supporting adapter when the user supplies `--as` or the site has a `default_session`.

New helper: `resolve_session_storage_state` in `verb_helpers.sh`:
- Reads `ARG_SITE` (set by `parse_verb_globals`) and `ARG_AS` (NEW global flag).
- If neither set, no-op (export `BROWSER_SKILL_STORAGE_STATE=""`).
- If site set, load profile; if profile has `default_session`, use it.
- If `--as` set, override.
- Validate session exists via `session_exists`; load storageState; check origin via `session_origin_check`.
- Export `BROWSER_SKILL_STORAGE_STATE` to the resolved file path.
- On origin mismatch: die EXIT_SESSION_EXPIRED with self-healing hint.

New routing rule: `rule_session_required` — if `BROWSER_SKILL_STORAGE_STATE` is non-empty, prefer playwright-lib over playwright-cli.

Steps:
- [ ] **3.1** Add `ARG_AS` to `parse_verb_globals` (handles `--as VALUE`).
- [ ] **3.2** Add `resolve_session_storage_state` helper to `verb_helpers.sh`.
- [ ] **3.3** Add 6+ test cases to `tests/session-loading.bats` (no-site = no-op; site-without-default-session = no-op; site-with-default-session resolves; --as override; origin mismatch exits 22; missing session exits 22).
- [ ] **3.4** Wire the helper into `scripts/browser-open.sh` between `parse_verb_globals` and `pick_tool`.
- [ ] **3.5** Add `rule_session_required` to `scripts/lib/router.sh`; placed BEFORE `rule_default_navigation` so it wins when storage state is set.
- [ ] **3.6** Run RED → write impl → GREEN.
- [ ] **3.7** Commit: `feat(session): wire --site/--as → BROWSER_SKILL_STORAGE_STATE; router prefers playwright-lib when set`.

---

## Task 4: Replace `playwright-lib-stub` carry-forward in browser-login.sh

**Files:** Modify `scripts/browser-login.sh` + relevant bats tests.

Phase 2's login verb summary uses `tool=playwright-lib-stub` because no real adapter existed. With playwright-lib now shipped (stub-validated), login can route through it.

Steps:
- [ ] **4.1** Update `scripts/browser-login.sh` to call `pick_tool login` (the router will route to playwright-lib via `rule_session_required` when `--as` is supplied; here we add a `rule_login` rule that always routes login → playwright-lib).
- [ ] **4.2** Update `tests/login.bats` to expect `tool=playwright-lib` in summary.
- [ ] **4.3** Add `login` to playwright-lib's `tool_capabilities.verbs`.
- [ ] **4.4** Run full bats; expect all pass.
- [ ] **4.5** Commit: `feat(login): replace playwright-lib-stub carry-forward; route through real adapter`.

---

## Task 5: SKILL.md verb examples + CHANGELOG + tag

- [ ] **5.1** Add a session-loading example to the `open` row (or a note above the verbs table).
- [ ] **5.2** Run `scripts/regenerate-docs.sh all`.
- [ ] **5.3** Append `### Phase 4` subsection to `CHANGELOG.md`.
- [ ] **5.4** Run full suite + lint; must be green.
- [ ] **5.5** Commit + tag `v0.4.0-phase-04-playwright-lib-and-sessions`.

---

## Acceptance criteria

- [ ] `tests/playwright-lib_adapter.bats` — adapter contract + stub-validated verb dispatch (12+ cases).
- [ ] `tests/session-loading.bats` — `resolve_session_storage_state` covers happy path, no-op, override, origin mismatch (6+ cases).
- [ ] `tests/login.bats` — login summary now reports `tool=playwright-lib` (no `-stub` suffix).
- [ ] `tests/run.sh` green (current 215 + ~25 new).
- [ ] `bash tests/lint.sh` exit 0 across all three tiers.
- [ ] `scripts/regenerate-docs.sh all` produces a 2-row `tool-versions.md` (playwright-cli + playwright-lib) and 2-row SKILL.md tools-table.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (deferred)

| Item | Where it lives next |
|---|---|
| Real-browser e2e tests (no stub) | Phase 4 part 2 — adds `tests/e2e/playwright-lib.bats` gated by `command -v playwright`; not part of CI |
| `scripts/lib/tool/chrome-devtools-mcp.sh` (CDP-via-MCP adapter for audit/console/network capture) | Phase 5 |
| `scripts/lib/tool/obscura.sh` (stealth/anti-fingerprinting for `extract --scrape`) | Phase 8 |
| Capture sanitisation (HAR redact, Authorization header strip, screenshot region masks) | Phase 7 |
| Standalone `cdp-cli` adapter (raw CDP wire protocol, e.g. `chrome-cdp-cli` npm) | Not currently in the spec — opt-in via the add-a-tool-adapter recipe whenever needed |
