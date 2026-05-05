# Phase 5 part 1f — Chrome `--user-data-dir` passthrough for cdt-mcp

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Make Chrome session loading work with cdt-mcp. Plumb the `CHROME_USER_DATA_DIR` env var through the bridge → upstream MCP server child as a `--user-data-dir DIR` CLI arg. Without it: Chrome starts fresh (current behavior). With it: Chrome reuses the profile directory (cookies, localStorage, extensions all persist).

**Sub-scope (1f-i, minimal — passthrough only):**
- Bridge plumbs the env var through to the MCP child's spawn args.
- Sessions-on-disk integration deferred (login --capture-user-data-dir, session resolver hooks for cdt-mcp). User provides the directory themselves.
- Documentation: "to use a logged-in profile with cdt-mcp, log in once with real Chrome at a known directory; export `CHROME_USER_DATA_DIR=/path/to/profile` before running verb scripts".

**Branch:** `feature/phase-05-part-1f-user-data-dir`
**Tag:** `v0.14.0-phase-05-part-1f-user-data-dir`.

---

## File Structure

### Modified

| Path | Change | Diff |
|---|---|---|
| `scripts/lib/node/chrome-devtools-bridge.mjs` | new `mcpSpawnArgs()` helper. Used in all 3 MCP-child spawn sites: `runStatelessOneShot`, `daemonChildMain`, `withMcpClient` | +~15 LOC |
| `tests/stubs/mcp-server-stub.mjs` | log `process.argv.slice(2)` to MCP_STUB_LOG_FILE on startup so bats can grep | +~5 LOC |
| `tests/chrome-devtools-bridge_real.bats` | +1 case: bridge with `CHROME_USER_DATA_DIR=/tmp/x` forwards `--user-data-dir /tmp/x` to MCP child | +~10 LOC |
| `tests/chrome-devtools-mcp_daemon_e2e.bats` | +1 case: daemon spawned with `CHROME_USER_DATA_DIR=/tmp/x` forwards the arg | +~10 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | new "Session loading" subsection + env-var table row | +~20 LOC |
| `CHANGELOG.md` | Phase 5 part 1f subsection | +~10 LOC |

### Untouched
- All adapters (no capability declaration changes — env var is bridge-internal).
- Verb scripts (no flag changes).
- Router rules.
- Session resolver / login flow (deferred to later sub-part if needed).

---

## Test approach

### Stub change

```js
// At startup, before listening:
if (LOG) {
  try { appendFileSync(LOG, `--- spawn-argv: ${JSON.stringify(process.argv.slice(2))} ---\n`); } catch (_) {}
}
```

### Bats cases

```
@test "bridge: CHROME_USER_DATA_DIR forwards --user-data-dir DIR to MCP child (one-shot)" {
  CHROME_USER_DATA_DIR=/tmp/test-profile run_real open https://example.com >/dev/null
  grep -- '--user-data-dir' "${MCP_STUB_LOG_FILE}" | grep -q '/tmp/test-profile'
}

@test "daemon: CHROME_USER_DATA_DIR forwards --user-data-dir DIR to MCP child" {
  CHROME_USER_DATA_DIR=/tmp/test-profile node "${BRIDGE}" daemon-start >/dev/null
  grep -- '--user-data-dir' "${MCP_STUB_LOG_FILE}" | grep -q '/tmp/test-profile'
}
```

### GREEN impl

```js
function mcpSpawnArgs() {
  const args = [];
  if (process.env.CHROME_USER_DATA_DIR) {
    args.push('--user-data-dir', process.env.CHROME_USER_DATA_DIR);
  }
  return args;
}
```

Replace `[]` in all 3 `spawn(bin, [], {...})` sites with `mcpSpawnArgs()`.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Upstream chrome-devtools-mcp may not accept `--user-data-dir` as a CLI arg | Document the behavior. If upstream rejects, the user's MCP child fails; user gets clear error. Bats only verifies the bridge forwards it — actual upstream support is upstream's responsibility |
| Profile directory needs to be writable + Chrome-compatible format | Document: user must point at an actual Chrome profile dir |
| Concurrent runs sharing a profile dir cause Chrome lock conflicts | Documented limitation — user must serialize |

---

## Tag + push

```
git tag v0.14.0-phase-05-part-1f-user-data-dir
git push -u origin feature/phase-05-part-1f-user-data-dir
git push origin v0.14.0-phase-05-part-1f-user-data-dir
gh pr create --title "feat(phase-5-part-1f): CHROME_USER_DATA_DIR passthrough for cdt-mcp"
```
