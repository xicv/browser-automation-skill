# Phase 5 part 1c-ii — chrome-devtools-mcp daemon + ref persistence (click/fill)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Add daemon lifecycle (`daemon-start` / `daemon-stop` / `daemon-status`) to `scripts/lib/node/chrome-devtools-bridge.mjs`. Daemon holds the upstream MCP server child + `eN ↔ uid` ref map across calls. Wire `click` and `fill` through daemon IPC so the agent can interact with elements after a `snapshot`. Mirrors `scripts/lib/node/playwright-driver.mjs:409-595` (Phase 4 part 4b precedent).

**Stateful scope (B1 — minimal):** Only `click` and `fill` land in this PR. `inspect` and `extract` stay at exit 41 — they will be bundled with their verb-script counterparts in **part 1e** (`scripts/browser-audit.sh`, `scripts/browser-extract.sh`).

**Test strategy — extend mock MCP server:** `tests/stubs/mcp-server-stub.mjs` gains `click` + `fill` tool handlers. New bats `tests/chrome-devtools-mcp_daemon_e2e.bats` mirrors `tests/playwright-lib_daemon_e2e.bats` shape. CI runs identically on macos + ubuntu without real Chrome.

**Branch:** `feature/phase-05-part-1c-ii-cdt-mcp-daemon`
**Tag:** `v0.10.0-phase-05-part-1c-ii-cdt-mcp-daemon` (minor bump — structural unblocker for parts 1d/1e/1f).

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `tests/chrome-devtools-mcp_daemon_e2e.bats` | Daemon lifecycle + click/fill IPC tests against `mcp-server-stub.mjs`. Privacy canary on fill. | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-05-phase-05-part-1c-ii-cdt-mcp-daemon.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/node/chrome-devtools-bridge.mjs` | + daemon-start / daemon-stop / daemon-status verb dispatch + IPC server (TCP loopback + random port) + daemon dispatcher (snapshot/click/fill) + IPC client for stateful verbs | +~280 LOC |
| `tests/stubs/mcp-server-stub.mjs` | + `click` + `fill` tool handlers (echo `uid` + `text` to log) | +~30 LOC |
| `tests/chrome-devtools-bridge_real.bats` | click/fill exit-41 test message updates: "deferred to 1c-ii" → "requires running daemon" | +~5 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | sync stateful-verb status: click/fill via daemon (real-mode); inspect/extract still deferred to 1e | +~15 LOC |
| `scripts/lib/tool/chrome-devtools-mcp.sh` | tool_doctor_check note bump (transport not deferred for click/fill) | +~3 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 1c-ii` subsection | +~15 LOC |

### Untouched

- `scripts/lib/router.sh` (Path A still — no router edits; promotion bundled with part 1d)
- `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/browser-click.sh`, `scripts/browser-fill.sh` (verb scripts unchanged — they shell to adapter; adapter shells to bridge; bridge handles IPC)

---

## Daemon shape

Mirrors playwright-driver:

- **State file:** `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json` mode 0600. Schema: `{ pid, port, mcp_bin, started_at }`.
- **State dir:** `${BROWSER_SKILL_HOME}` mode 0700 (already created by helpers).
- **Spawn:** `daemon-start` re-execs self with `--internal-server` flag, detached, unref. Parent polls state file (10s deadline), prints state, exits.
- **IPC:** TCP loopback (`127.0.0.1:0` → random port) — Unix sun_path 104-char cap on macOS bats temp paths. Same precedent as playwright-driver.
- **Daemon child main:** spawns one MCP server child; performs initialize handshake once; holds child stdin/stdout for life of daemon. NDJSON line server accepts verb messages from clients.
- **Stop:** SIGTERM PID + unlink state file. PID-not-alive on stop = no-op success.
- **Logs:** daemon child stderr → `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.log` mode 0600 (mirror `playwright-lib-daemon.log`).

### eN ↔ uid map

- Daemon dispatch on `snapshot`: tools/call `take_snapshot` → MCP returns elements with `uid`. Daemon assigns `e1`, `e2`, … and stores `refMap = [{id: 'eN', uid, role, name}, …]`.
- Daemon dispatch on `click`: client sends `{verb: 'click', ref: 'e1'}` → daemon resolves `ref` → `uid` from refMap → tools/call MCP with `uid` arg.
- Daemon dispatch on `fill`: client sends `{verb: 'fill', ref: 'e1', text: '…'}` → resolve uid → tools/call MCP with `{uid, text}`.
- Missing ref → reply error event `{event: 'error', message: 'ref \\'eN\\' not found in last snapshot'}`.

### Client-side (verb invocation)

`bridge.mjs click e1` flow:
1. Read state file. If absent or PID dead → exit 41 with hint: `"click requires running daemon (run: node chrome-devtools-bridge.mjs daemon-start)"`.
2. Connect to TCP loopback port from state file.
3. Send NDJSON `{verb: 'click', ref: 'e1'}`. Wait reply (CALL_TIMEOUT_MS).
4. Shape reply (already shaped by daemon) → emit on stdout. Exit 0 / non-zero per reply.

Same flow for `fill` (with `text` or `--secret-stdin` read from process stdin). Stateless verbs (open/snapshot/eval/audit) keep one-shot behavior when daemon not running; route through daemon when running for symmetry. **Scope limit:** for B1 minimal, we keep stateless verbs as one-shot only — lifting them into the daemon is an optimization, not a value-add for click/fill.

### Privacy invariant (AP-7 + token-efficient-output spec)

- Fill secret never appears on argv to MCP child. Bridge IPC carries `{verb: fill, ref, text}` over loopback (loopback only — never serialized to disk).
- Bridge wraps MCP errors that may echo the text in their message; replaces the secret with `<redacted>` (mirrors playwright-driver:583-591).
- Sentinel canary `sekret-do-not-leak-CDT-1c-ii` test on fill: stdout never contains canary; stub log never contains canary.

---

## RED bats — what fails before impl

### Daemon lifecycle (4 tests)

1. `daemon-status` (no daemon) → emits `{event: "daemon-not-running"}`, exit 0.
2. `daemon-start` → emits `{event: "daemon-started", pid: <num>, port: <num>, mcp_bin: <path>}`. State file mode 0600.
3. `daemon-status` (running) → emits `{event: "daemon-running", pid, port}`, exit 0.
4. `daemon-start` when running → emits `{event: "daemon-already-running", pid, port}`, exit 0 (idempotent).
5. `daemon-stop` → emits `{event: "daemon-stopped"}`, state file unlinked, PID terminated.
6. `daemon-stop` when none → emits `{event: "daemon-not-running"}`, exit 0 (no-op).

### Click via daemon (3 tests)

7. `click e1` without daemon → exit 41, stderr contains "requires running daemon".
8. `daemon-start` → bridge open URL → bridge snapshot (caches refMap) → `click e1` → exit 0, summary `{verb: "click", ref: "e1", uid: "cdp-uid-1234", status: "ok"}`. Stub log shows `tools/call` for `click` (or whatever name) with `uid: cdp-uid-1234`.
9. `click e99` (ref not in last snapshot) → exit non-zero, error message names the missing ref.

### Fill via daemon (3 tests)

10. `fill e1 hello` → exit 0, summary `{verb: "fill", ref: "e1", uid: "cdp-uid-1234", status: "ok"}`. Stub log shows fill with `text: "hello"`.
11. `fill e1 --secret-stdin` (stdin = `sekret-do-not-leak-CDT-1c-ii\n`) → exit 0. **Privacy canary**: stdout (skill summary) never contains canary; stub log echoes the text but the test asserts skill stdout is sanitized.
12. `fill` without daemon → exit 41, stderr contains "requires running daemon".

### Regression (existing real-mode tests still green)

- All 13 existing tests in `tests/chrome-devtools-bridge_real.bats` keep passing. Update click/fill exit-41 test wording: "1c-ii hint" → "requires running daemon" (now they hit the IPC client check, not the deferred-translateVerb path).

---

## GREEN impl — phases

1. **Daemon state file helpers** (`daemonStatePath`, `readDaemonState`, `writeDaemonState`, `isPidAlive`) — copy shape from playwright-driver:380-405.
2. **Re-exec scaffold** (`runDaemonStart` / `daemonChildMain`) — `--internal-server` flag, detached spawn, unref, log redirect.
3. **Daemon child main** — spawn ONE MCP child + initialize handshake (refactor existing handshake into helper `mcpInitialize(child)`); start TCP loopback IPC server; close on SIGTERM.
4. **Daemon dispatch** — NDJSON line dispatcher; handlers for `snapshot` / `click` / `fill`; resolves ref → uid; calls MCP tools/call; shapes reply.
5. **IPC client** — `ipcCall(stateFile, msg, timeoutMs)`: connect, write line, await line, close. Used by stateful verb path in `realDispatch`.
6. **Verb routing in `realDispatch`** — top of function: if verb is `click` / `fill` → require daemon → IPC client → emit shape. If verb is `daemon-*` → daemon lifecycle dispatch. Otherwise stateless one-shot (existing path).
7. **Stub extension** — add `click` + `fill` handlers to `mcp-server-stub.mjs`. Reply `{content: [{type: 'text', text: 'clicked uid X'}], isError: false}` so the bridge can shape into summary.

---

## Test approach

- New bats file gates on `node` + bats stub — no real Chrome / npx. Sets `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/mcp-server-stub.mjs"`.
- `setup()` exports STUB bin var; `teardown()` always runs `daemon-stop` (matches playwright-lib bats teardown). Defensive setup pattern (HANDOFF §60).
- Daemon child stderr → `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.log` so debugging failed bats is one cat away.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Bats temp HOME orphans daemon if test fails before `daemon-stop` | `teardown()` always runs daemon-stop \|\| true; state file under `${BROWSER_SKILL_HOME}` (test temp dir) so `rm -rf TEST_HOME` reaps state file. |
| MCP child crash mid-call leaves daemon zombie | Daemon `child.on('exit')` triggers self-shutdown (mirror playwright-driver pattern). |
| Loopback port collision in CI | `127.0.0.1:0` returns ephemeral free port. State file persists actual port for clients. |
| Privacy: fill text echoed in MCP child stderr or stub log | Stub log will record the text (it's a test stub, not a privacy boundary). The skill stdout (what the agent sees) must be canary-free. Test asserts on stdout only. |

---

## Lint + drift

- bats-tier: shellcheck clean (no shell changes anyway — only node + tests).
- node-tier: no eslint config in repo; manual `node --check` on the .mjs file.
- Drift tier: no adapter capability change → no `regenerate-docs.sh` run needed.

---

## Tag + push

```
git tag v0.10.0-phase-05-part-1c-ii-cdt-mcp-daemon
git push -u origin feature/phase-05-part-1c-ii-cdt-mcp-daemon
git push origin v0.10.0-phase-05-part-1c-ii-cdt-mcp-daemon
gh pr create --title "feat(phase-5-part-1c-ii): cdt-mcp daemon + ref persistence (click/fill)"
```

After CI green + squash-merge: `git checkout main && git pull --ff-only`.

---

## Appendix: daemon state shape

```json
{
  "pid": 12345,
  "port": 53219,
  "mcp_bin": "/abs/path/to/chrome-devtools-mcp",
  "started_at": "2026-05-05T07:30:00.000Z",
  "schema_version": 1
}
```

File mode 0600. Directory mode 0700. Same convention as `playwright-lib-daemon.json`.
