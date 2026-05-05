# Phase 5 part 1e-ii — Bridge dispatch for `inspect` + `extract` real-mode

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Wire `inspect` and `extract` into `chrome-devtools-bridge.mjs` real-mode (one-shot AND daemon paths). Currently both verbs exit 41 with hint pointing at part 1e. After this PR, they work end-to-end against a real upstream MCP server (`npx chrome-devtools-mcp@latest`).

**Branch:** `feature/phase-05-part-1e-ii-bridge-inspect-extract`
**Tag:** `v0.13.0-phase-05-part-1e-ii-bridge-inspect-extract` (minor — completes cdt-mcp's 8-verb coverage in real mode).

---

## Verb mapping to MCP tools

### `inspect` (multi-tool composition)

| Skill flag | MCP tool | Result field |
|---|---|---|
| `--capture-console` | `list_console_messages` | `console_messages` |
| `--capture-network` | `list_network_requests` | `network_requests` |
| `--screenshot` | `take_screenshot` | `screenshot_path` |
| `--selector CSS` | `evaluate_script` (with `document.querySelectorAll`) | `matches` |

Multi-flag = multiple sequential MCP calls; results aggregated into ONE summary JSON. Order: console → network → screenshot → selector. At least one flag required (verb script enforces).

### `extract` (single tool)

| Skill flag | MCP tool | Result field |
|---|---|---|
| `--selector CSS` | `evaluate_script` (`querySelectorAll → join textContent`) | `value` |
| `--eval JS` | `evaluate_script` (raw script) | `value` |

Both flags acceptable (eval can use selector via DOM API in its script).

---

## Refactor: extract `makeMcpCall` helper

Currently the daemon embeds an inline `mcpCall` closure (bridge.mjs ~line 370). Extract to a top-level factory so one-shot path can reuse:

```js
function makeMcpCall(child, reader, startId = 100) {
  let nextId = startId;
  return async function mcpCall(name, args, timeoutMs) {
    const id = ++nextId;
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0', id, method: 'tools/call',
      params: { name, arguments: args },
    });
    const resp = await reader.waitFor(id, timeoutMs ?? CALL_TIMEOUT_MS);
    if (resp.error) throw new Error(`MCP tools/call '${name}' failed: ${resp.error.message}`);
    return resp.result;
  };
}
```

Both daemon dispatch and a new `runStatelessOneShotMulti` (used for inspect/extract one-shot) use it.

---

## File Structure

### Modified

| Path | Change | Diff |
|---|---|---|
| `scripts/lib/node/chrome-devtools-bridge.mjs` | extract makeMcpCall + add inspect/extract dispatch (daemon + one-shot) + remove exit-41 path | +~250 LOC |
| `tests/stubs/mcp-server-stub.mjs` | +list_console_messages, list_network_requests, take_screenshot tool handlers | +~50 LOC |
| `tests/chrome-devtools-bridge_real.bats` | replace 2 exit-41 tests for inspect/extract with happy-path real-mode tests | +~30 LOC |
| `tests/chrome-devtools-mcp_daemon_e2e.bats` | +6 cases for inspect/extract via daemon | +~80 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | per-verb table reflects real-mode for all 8 verbs | +~10 LOC |
| `scripts/lib/tool/chrome-devtools-mcp.sh` | doctor note bump (no longer "deferred for any verb") | +~3 LOC |
| `CHANGELOG.md` | Phase 5 part 1e-ii subsection | +~15 LOC |

### New
- `docs/superpowers/plans/2026-05-05-phase-05-part-1e-ii-bridge-inspect-extract.md` — this plan.

### Untouched
- `scripts/lib/router.sh` (no rule changes)
- `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged — already declared inspect/extract)
- All verb scripts including `scripts/browser-inspect.sh` and `scripts/browser-extract.sh` (just added in 1e-i; they pass argv through to adapter which shells to bridge — bridge changes are transparent)

---

## RED bats — what fails before impl

### `tests/chrome-devtools-bridge_real.bats` (UPDATE 2 existing tests)

Replace:
```
bridge real-mode: stateful verb 'inspect' returns exit 41
bridge real-mode: stateful verb 'extract' returns exit 41
```

with:
```
bridge real-mode: inspect --capture-console emits console_messages summary (one-shot)
bridge real-mode: inspect --selector .x emits matches (one-shot)
bridge real-mode: extract --selector .x emits value (one-shot)
bridge real-mode: extract --eval expr emits value (one-shot)
```

### `tests/chrome-devtools-mcp_daemon_e2e.bats` (NEW cases)

```
daemon: inspect --capture-console via daemon emits console_messages
daemon: inspect --capture-console --capture-network multi-flag aggregation
daemon: inspect --screenshot returns screenshot_path
daemon: inspect --selector .x returns matches
daemon: extract --selector .x returns value
daemon: extract --eval document.title returns value
```

### Stub additions (`tests/stubs/mcp-server-stub.mjs`)

```js
case 'list_console_messages':
  reply(id, { content: [{type:'text', text:'console: 2 messages'}], messages:[{level:'log',text:'hi'},{level:'error',text:'oops'}], isError: false });
  break;
case 'list_network_requests':
  reply(id, { content: [{type:'text', text:'network: 5 requests'}], requests:[{url:'/api',status:200}], isError: false });
  break;
case 'take_screenshot':
  reply(id, { content: [{type:'text', text:'screenshot saved'}], path:'/tmp/screenshot-stub.png', isError: false });
  break;
```

---

## GREEN impl — phases

1. **Extract `makeMcpCall(child, reader, startId)` helper** — top-level function.
2. **Add `runStatelessOneShotMulti(verb, msg)`** — spawn child + init handshake + run a per-verb dispatch closure that may call mcpCall multiple times + shutdown.
3. **Add inspect dispatch** in daemon's `dispatch()` and as a one-shot variant. Multi-flag aggregation via sequential mcpCall.
4. **Add extract dispatch** — single `evaluate_script` tools/call.
5. **Remove the exit-41 path** for inspect/extract in `realDispatch`. They become routed verbs (daemon when running; one-shot otherwise).
6. **Stub additions** — 3 new tools/call handlers.

---

## Tag + push

```
git tag v0.13.0-phase-05-part-1e-ii-bridge-inspect-extract
git push -u origin feature/phase-05-part-1e-ii-bridge-inspect-extract
git push origin v0.13.0-phase-05-part-1e-ii-bridge-inspect-extract
gh pr create --title "feat(phase-5-part-1e-ii): bridge dispatch for inspect/extract real-mode (8/8 cdt-mcp verbs)"
```

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Multi-flag inspect makes 4 sequential MCP calls — slow if upstream is slow | Acceptable — agent-driven verb is exceptional path; lighthouse audit already takes 60s |
| Selector → evaluate_script script injection (CSS in `document.querySelectorAll('${sel}')`) | Use `JSON.stringify(sel)` in injection to avoid quote escaping; document the limit (no script injection because eval runs in page context, not local) |
| inspect with NO flags — undefined behavior | Verb script (1e-i) already enforces `--capture-* OR --selector` required; bridge just sees flags in argv and acts on what's present. If somehow no flags reach the bridge, returns empty result with status=ok |
| extract --selector returns array of strings; tests assert `.value` shape | Document: `value` is a string (joined by `\n`) — matches existing fixture shape |
