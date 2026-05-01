# Phase 4 part 4c — IPC daemon for stateful verbs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Make `snapshot` / `click` / `fill` / `login` work in real mode against the playwright-lib daemon. Empirical investigation in part 4b confirmed that `chromium.connect()` clients **do not share contexts** across connections — state opened in one client process disappears when that client disconnects. The daemon must therefore hold the browser state itself and expose verb operations over IPC; verb processes become thin clients that send command messages and receive results.

**Architecture:** Unix-domain socket at `${BROWSER_SKILL_HOME}/playwright-lib-daemon.sock`. Daemon process holds (BrowserServer, Browser, current Context, current Page, ref-map). Client verbs `connect()` to the socket, send one JSON line `{verb, ...flags}`, read one JSON line response, exit.

**Why Unix socket (not HTTP):** zero deps (Node's `net` is built-in), filesystem-permission-scoped (mode 0600 via parent dir), no port-collision concerns, identical perf for our use case.

**Spec references:**
- Token-efficient adapter output spec §3 (output schema), §5 (eN refs), §6 (capture file layout).
- Phase 4 part 4a CHANGELOG entry — describes the daemon lifecycle this plan extends.

**Branch (recommended):** `feature/phase-04-part-4c-ipc-daemon`.

---

## File Structure

### New (creates)
- `tests/playwright-lib_stateful_e2e.bats` — gated end-to-end chain (start → open → snapshot → click → fill → stop), covers ref-map persistence across processes.

### Modified
- `scripts/lib/node/playwright-driver.mjs`:
  - `daemonChildMain` becomes an IPC server: creates browser/context/page state, listens on socket, dispatches incoming JSON commands.
  - `runOpen` / `runSnapshot` / `runClick` / `runFill` redirect through `ipcCall(socketPath, msg)` → daemon does the work, client just forwards stdout.
  - One-shot fallback for `runOpen` when no daemon stays as-is (single-shot smoke test).
- `scripts/lib/tool/playwright-lib.sh`:
  - `tool_doctor_check` reports daemon socket presence + readiness.
  - `tool_capabilities` unchanged.
- `references/playwright-lib-cheatsheet.md`:
  - Daemon section: `daemon-start` required for stateful verbs; lifecycle commands; ref-map semantics.

### Untouched
- `scripts/lib/router.sh` (rule_session_required / rule_default_navigation already correct).
- All other adapters / verb scripts.

---

## Tasks

### Task 1: IPC server in `daemonChildMain`
- [ ] **1.1** Daemon holds `{browser, context, page, refMap}` in closure scope.
- [ ] **1.2** `createServer((conn) => …)` parses newline-delimited JSON; dispatches to `handleVerb(msg)`.
- [ ] **1.3** Socket listens at `${BROWSER_SKILL_HOME}/playwright-lib-daemon.sock`; mode 0600 via parent-dir 0700.
- [ ] **1.4** Cleanup on SIGTERM closes server, browser, unlinks socket file + state file.
- [ ] **1.5** State file (`playwright-lib-daemon.json`) gains `socket_path` field.

### Task 2: Verb handlers in daemon
- [ ] **2.1** `handleOpen({url, storageState, userAgent, viewport, headed})` — closes prior context, creates new one with options, navigates, returns `{event:'navigated', url, title, status}`.
- [ ] **2.2** `handleSnapshot()` — `accessibility.snapshot({interestingOnly:false})`, walk tree, assign `eN`, store map in `refMap`, return `{event:'snapshot', refs}`. The daemon also writes the ref-map to `${BROWSER_SKILL_HOME}/playwright-lib-refs.json` for diagnostics.
- [ ] **2.3** `handleClick({ref})` — look up ref in `refMap`, `getByRole(role, {name}).first().click()`, return `{event:'click', ref, status:'ok'}`.
- [ ] **2.4** `handleFill({ref, text})` — same as click + `.fill(text)`. Secret never echoed; response carries `text_length` only.
- [ ] **2.5** `handleClose()` — daemon command to close current context (without killing the daemon).

### Task 3: Client-side `ipcCall` helper
- [ ] **3.1** `ipcCall(msg)` — connects to socket, writes one JSON line, reads one JSON line, resolves. Times out after `BROWSER_SKILL_LIB_TIMEOUT_MS` (default 30000).
- [ ] **3.2** `runOpen` / `runSnapshot` / `runClick` / `runFill` route through `ipcCall` when daemon present.
- [ ] **3.3** `runOpen` keeps one-shot fallback when no daemon (Phase 4 part 3 behavior).
- [ ] **3.4** `runFill` reads stdin for `--secret-stdin` BEFORE the IPC call so the daemon never sees the unbuffered stdin.

### Task 4: e2e tests
- [ ] **4.1** `tests/playwright-lib_stateful_e2e.bats`:
  - daemon-start → open https://example.com → snapshot returns ≥ 1 ref → click e1 succeeds → daemon-stop.
  - fill via --secret-stdin: secret never appears in IPC log (gated assertion).
  - re-snapshot after page mutation invalidates old refs (one positive case).
- [ ] **4.2** Gated on `command -v playwright`; `setup_file()` skip for CI without Playwright.

### Task 5: Adapter doctor + cheatsheet
- [ ] **5.1** `tool_doctor_check` looks for socket file and reports `daemon_running: bool` + path.
- [ ] **5.2** `references/playwright-lib-cheatsheet.md` Daemon section: lifecycle, IPC protocol, ref-map semantics, troubleshooting.

### Task 6: CHANGELOG + tag
- [ ] **6.1** New `### Phase 4 part 4c` subsection.
- [ ] **6.2** Tag `v0.5.0-phase-04-part-4c-ipc-daemon` (minor bump because adapter behavior changes meaningfully).

---

## Acceptance criteria

- [ ] `tests/run.sh` green; new totals = current + ~5 stateful e2e.
- [ ] `bash tests/lint.sh` exit 0.
- [ ] Manual chain: `daemon-start; open URL; snapshot; click eN; fill eM "text"; daemon-stop` works end-to-end against real Chromium.
- [ ] Daemon shutdown is clean (SIGTERM → no orphan chromium processes; socket + state files removed).
- [ ] CI (without Playwright) green via gated skips.

---

## Out of scope (deferred again)

| Item | Where it lives next |
|---|---|
| Real-mode `login` (headed browser, wait-for-user, capture storageState) | Phase 4 part 4d |
| Multi-page tabs / window management | Phase 4 part 5 |
| `chrome-devtools-mcp.sh` adapter (audit / console / network capture for inspect) | Phase 5 |
