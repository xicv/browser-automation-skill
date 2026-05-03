# Phase 5 part 1c — chrome-devtools-mcp real MCP stdio transport (stateless verbs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Fill in the `real_dispatch` slot in `scripts/lib/node/chrome-devtools-bridge.mjs` (currently throws "deferred to part 1c"). The bridge spawns the upstream `chrome-devtools-mcp` MCP server (`npx chrome-devtools-mcp@latest` or any wrapper at `${CHROME_DEVTOOLS_MCP_BIN}`), speaks JSON-RPC 2.0 NDJSON over stdio, performs the `initialize` handshake, dispatches one `tools/call`, shapes the response into the skill's single-line summary JSON, and exits.

**Stateless-only scope:** Only verbs that DON'T require ref persistence across calls land in this PR — `open`, `snapshot`, `eval`, `audit`. The state-persistence-dependent verbs (`click`, `fill`, `inspect`, `extract`) need cross-call `eN` ↔ `uid` ref mapping and stay deferred to part 1c-ii (which will likely daemonize the bridge per the playwright-lib IPC daemon precedent).

**Test strategy — mock MCP server:** A node script at `tests/stubs/mcp-server-stub.mjs` mimics the upstream's stdio JSON-RPC behavior. Bats tests set `CHROME_DEVTOOLS_MCP_BIN=tests/stubs/mcp-server-stub.mjs` and invoke the bridge in real mode. CI runs identically on macos + ubuntu without network or Chrome install. Real-real integration testing (`npx chrome-devtools-mcp@latest` against actual Chrome) is a manual / gated-CI follow-up.

**Branch:** `feature/phase-05-part-1c-cdt-mcp-transport`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `tests/stubs/mcp-server-stub.mjs` | Mock MCP server — JSON-RPC NDJSON stdio; handles `initialize` + `tools/call` for `navigate_page`, `take_snapshot`, `evaluate_script`, `lighthouse_audit` | ≤ 150 LOC |
| `tests/chrome-devtools-bridge_real.bats` | Bridge real-mode integration tests (against the mock) | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-03-phase-05-part-1c-cdt-mcp-transport.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/node/chrome-devtools-bridge.mjs` | Implement `realDispatch(argv)` — spawn MCP server, initialize handshake, verb→tools/call translation, shape response | +~250 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | Update "Real MCP transport deferred to part 1c" → reflect what shipped (stateless verbs work, stateful verbs deferred to 1c-ii) | +~15 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 1c` subsection | +~15 LOC |

### Untouched

- `scripts/lib/router.sh` (Path A still — no router edits)
- `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`
- `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/verb_helpers.sh`
- `scripts/lib/tool/chrome-devtools-mcp.sh` (adapter capabilities unchanged; bridge is the new implementation site)
- every `scripts/browser-*.sh`
- every other adapter file
- `tests/lint.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-1c-cdt-mcp-transport`.
- [ ] **Step 0.2** Commit plan.

---

## Task 1: Mock MCP server stub

`tests/stubs/mcp-server-stub.mjs` mimics the upstream's stdio behavior so CI can exercise the real-mode transport end-to-end without `npx chrome-devtools-mcp@latest` (which needs network + Chrome).

Wire format: JSON-RPC 2.0 messages, one per line on stdin and stdout (NDJSON, per MCP stdio convention).

Handles:
- `initialize` → respond with `{result: {capabilities: {}, serverInfo: {name: "stub", version: "0.0.0"}, protocolVersion: "2024-11-05"}}`
- `tools/call` with name=`navigate_page` + `arguments.url` → `{result: {content: [{type:"text", text:"navigated to ${url}"}], isError: false}}`
- `tools/call` name=`take_snapshot` → canned 2-element snapshot
- `tools/call` name=`evaluate_script` → echo back the script in a result envelope
- `tools/call` name=`lighthouse_audit` → canned score object
- Unknown method/tool → `{error: {code: -32601, message: "method not found"}}`

Logs each received message to `${MCP_STUB_LOG_FILE}` (one JSON per line) so bats can assert handshake order + tool args.

Steps:
- [ ] **1.1** Write the stub.

---

## Task 2: realDispatch implementation in bridge

Pseudo:
```js
async function realDispatch(argv) {
  const verb = argv[0];
  const verbArgs = argv.slice(1);

  const child = spawn(MCP_SERVER_BIN, [], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });

  // 1. Initialize handshake
  const initId = 1;
  await sendJsonRpc(child.stdin, {
    jsonrpc: '2.0', id: initId, method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'browser-skill', version: '0.9' },
    },
  });
  const initResp = await readJsonRpcResponse(child.stdout, initId, 5000);
  if (initResp.error) throw new Error(`MCP initialize failed: ${initResp.error.message}`);

  // 2. Translate verb to MCP tool call
  const { toolName, toolArgs } = translateVerb(verb, verbArgs);
  if (toolName === null) {
    // Deferred verb (click/fill/inspect/extract — needs state persistence)
    process.stderr.write(`chrome-devtools-bridge: real-mode verb '${verb}' deferred to phase-05 part 1c-ii (needs eN→uid persistence)\n`);
    process.exit(41);
  }

  // 3. tools/call
  const callId = 2;
  await sendJsonRpc(child.stdin, {
    jsonrpc: '2.0', id: callId, method: 'tools/call',
    params: { name: toolName, arguments: toolArgs },
  });
  const callResp = await readJsonRpcResponse(child.stdout, callId, 30000);

  // 4. Shape and emit
  const summary = shapeResponse(verb, callResp);
  process.stdout.write(JSON.stringify(summary) + '\n');

  // 5. Clean shutdown
  child.stdin.end();
  await waitForExit(child, 5000);
}
```

Verb translation table (this PR — 4 verbs):

| Verb | MCP tool | Args |
|---|---|---|
| `open` | `navigate_page` | `{url: <positional>}` |
| `snapshot` | `take_snapshot` | `{}` |
| `eval` | `evaluate_script` | `{script: <positional>}` |
| `audit` | `lighthouse_audit` | `{}` |
| `click`, `fill`, `inspect`, `extract` | (null) | exit 41 with hint |

Snapshot output: walk `result.content` (or wherever take_snapshot returns the tree), assign sequential `eN` ids, return both `refs_inline` (the eN→{role,name} mapping) and a copy of the upstream uids for traceability. Per token-efficient-output spec §5: "Adapters that route to a tool exposing a different scheme MUST translate at the adapter boundary so verb users see one scheme."

State persistence: NOT in this PR. The eN→uid map exists only during the snapshot call; subsequent click/fill in a new bridge process has no map → 41 with hint.

Steps:
- [ ] **2.1** Write `realDispatch`, helpers (`sendJsonRpc`, `readJsonRpcResponse`, `translateVerb`, `shapeResponse`, `waitForExit`).
- [ ] **2.2** Verify against stub: `node bridge.mjs open https://example.com` (with `CHROME_DEVTOOLS_MCP_BIN=tests/stubs/mcp-server-stub.mjs`) emits a `navigate` summary.

---

## Task 3: Bats tests against the mock

`tests/chrome-devtools-bridge_real.bats` (~10 cases):
- bridge file exists
- `BROWSER_SKILL_LIB_STUB=1` still works (regression guard for part 1b)
- real-mode: initialize handshake exchanged before any tools/call (verify stub log)
- real-mode `open --url URL` → tools/call `navigate_page` with URL
- real-mode `snapshot` → returns refs (eN-shaped)
- real-mode `eval --expression` → returns result value
- real-mode `audit --lighthouse` → returns lighthouse score
- real-mode `click` (deferred verb) → exit 41 with hint
- real-mode `fill` (deferred) → exit 41
- real-mode `inspect` (deferred) → exit 41
- real-mode `extract` (deferred) → exit 41
- mock-server crash mid-call → bridge exits non-zero with error

Steps:
- [ ] **3.1** Write the bats.
- [ ] **3.2** Run RED → fix → GREEN.

---

## Task 4: Cheatsheet + CHANGELOG + lint + ship

Cheatsheet — update Status section + Architecture diagram + Limitations:
- "Real MCP transport deferred to part 1c" → "Real MCP transport (stateless verbs) shipped in part 1c"
- New limitation: "Stateful verbs (click/fill/inspect/extract) need eN→uid persistence — deferred to part 1c-ii"
- Add a one-paragraph "How real mode works" section pointing at the bridge

CHANGELOG: Phase 5 part 1c subsection.

Lint exit 0. Tests ≥448 pass / 0 fail.

Steps:
- [ ] **4.1** Update cheatsheet.
- [ ] **4.2** Add CHANGELOG entry.
- [ ] **4.3** Lint + tests green.
- [ ] **4.4** Commit + tag `v0.9.0-phase-05-part-1c-cdt-mcp-transport` + push + PR + CI + merge.

---

## Acceptance criteria

- [ ] `tests/stubs/mcp-server-stub.mjs` exists; speaks JSON-RPC NDJSON over stdio; handles initialize + 4 tools.
- [ ] Bridge `realDispatch` performs initialize handshake before tools/call; bats verifies via stub log order.
- [ ] 4 stateless verbs (open/snapshot/eval/audit) work end-to-end via mock.
- [ ] 4 stateful verbs (click/fill/inspect/extract) exit 41 with self-healing hint pointing at part 1c-ii.
- [ ] Snapshot output uses `eN` refs (translation at adapter boundary per token-efficient-output spec §5).
- [ ] `BROWSER_SKILL_LIB_STUB=1` mode still works (regression guard).
- [ ] `bash tests/lint.sh` exit 0.
- [ ] `bash tests/run.sh` ≥448 pass / 0 fail.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (defer)

| Item | Goes to |
|---|---|
| Stateful verbs (click/fill/inspect/extract) — need eN→uid persistence | **part 1c-ii** (likely daemonizes the bridge mirroring playwright-lib's IPC daemon) |
| Path B router promotion (cdt-mcp default for inspect/audit/extract/--capture-*) | **part 1d** |
| Verb scripts: `scripts/browser-audit.sh`, `scripts/browser-extract.sh`; un-skip `tests/browser-inspect.bats` | **part 1e** |
| Chrome `--user-data-dir` session loading | **part 1f** |
| Real-real integration test against `npx chrome-devtools-mcp@latest` (network + Chrome) | optional follow-up gated on opt-in CI matrix |

---

## Risk register

| Risk | Mitigation |
|---|---|
| MCP protocol version mismatch with upstream chrome-devtools-mcp evolution | Bridge sends `protocolVersion: "2024-11-05"` (current spec); mock matches. Real upstream might require newer; the bridge will then emit a clear error from initialize. Cheatsheet documents the version. |
| stdio buffering deadlock (child stuck waiting for input we already sent) | Use newline-flushed writes (`stdin.write(JSON.stringify(msg) + '\n')`); read line-by-line via readline. NDJSON is well-suited to this. |
| Stub diverges from real upstream's response shape | Stub matches the response envelope shape per JSON-RPC 2.0 + MCP convention; integration tests against real upstream are a follow-up |
| 30s timeout on tools/call too short for lighthouse_audit | Lighthouse can take 30+s; bump per-call timeout to 60s for `lighthouse_audit`, 30s default for others. Document tunable env var if needed (part 1d). |
| Bridge spawn cost (~50-100ms per node startup) per verb call | Acceptable for this PR; daemon-mode (1c-ii) addresses it |
| Mock-server-stub mismatch breaks tests but bridge works against real upstream | This is the inverse risk — possible but unlikely for the 4 simple verbs. Real-upstream gated CI is the safety net. |
