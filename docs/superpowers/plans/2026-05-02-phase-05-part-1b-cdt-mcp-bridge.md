# Phase 5 part 1b — chrome-devtools-mcp bridge scaffold + lib-stub pivot

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the node ESM bridge that the chrome-devtools-mcp adapter will eventually use to speak MCP stdio JSON-RPC to upstream `chrome-devtools-mcp`. This PR is the **scaffold + stub-mode pivot** — mirroring Phase 4 part 4a (which landed `playwright-driver.mjs` lifecycle without real verb execution). Real MCP transport (initialize handshake + `tools/call` + `uid → eN` translation) is deferred to part 1c so this PR stays small + reviewable + focused on the architecture move.

**The architecture move:** Pivot the chrome-devtools-mcp adapter's stub mechanism from the bash binary stub (`tests/stubs/chrome-devtools-mcp` overridden via `CHROME_DEVTOOLS_MCP_BIN`) to a **library stub** (`BROWSER_SKILL_LIB_STUB=1` honored inside the bridge.mjs), exactly mirroring `playwright-lib`'s pattern with `playwright-driver.mjs`. This collapses the codebase to one stub model across all node-bridge adapters, deletes ~50 LOC of bash stub, and prepares the adapter for real MCP transport in part 1c.

**Tech stack:** Node ≥ 20 (already required), bash 5+, jq, bats-core. No new npm deps for this PR (the upstream `chrome-devtools-mcp` package is invoked via `npx` only when real-mode lands in part 1c).

**Spec references:**
- Parent spec §1 (`chrome-devtools-mcp` listed in `doctor`'s dependency set), Appendix B routing matrix.
- Extension-model spec §2 (ABI surface — capabilities unchanged this PR).
- Token-efficient-output spec §5 (`eN` element-ref translation at adapter boundary — wire transport prep, full impl in part 1c).
- Phase 4 part 4a plan (`docs/superpowers/plans/2026-05-01-phase-04-part-4a-playwright-lib-daemon.md`) — the analog this PR mirrors.
- Anti-patterns: AP-2 (no cross-adapter sourcing), AP-6 (namespace-prefix file-scope globals), AP-7 (no secrets in argv), AP-8 (no network at file-source time).

**Branch:** `feature/phase-05-part-1b-cdt-mcp-bridge`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/node/chrome-devtools-bridge.mjs` | ESM bridge — top-level `if (BROWSER_SKILL_LIB_STUB === '1') stub_dispatch(); else real_dispatch()`. Stub: argv → sha256 → fixture → stdout → exit 0; miss → error JSON + exit 41; logs argv to `STUB_LOG_FILE` for parity with the bash stub. Real: `throw new Error('real-mode MCP transport deferred to part 1c')` | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/tool/chrome-devtools-mcp.sh` | Replace `${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}` with `${NODE_BIN} ${BRIDGE}` shells via a new `_drive` helper. Doctor check pivots from "bin on PATH" to "node on PATH + bridge file present" (mirror `playwright-lib::tool_doctor_check`). Capabilities untouched. | ~+30 LOC, -~30 LOC (net flat) |
| `tests/chrome-devtools-mcp_adapter.bats` | Pivot env vars: `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` → `BROWSER_SKILL_LIB_STUB=1`. `CHROME_DEVTOOLS_MCP_FIXTURES_DIR` stays (bridge respects it too). Drop the part-1 "stub bin on PATH" doctor test; replace with "node on PATH" assertion. Argv-shape tests unchanged (bridge logs to `STUB_LOG_FILE`). | ~25 lines edited |
| `tests/doctor.bats` | Revert the part-1 `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` additions in 3 sites — no longer needed because doctor now passes on node alone (mirror `playwright-lib`'s no-bin-required doctor). | -3 lines |
| `tests/install.bats` | Same revert as `tests/doctor.bats`, 1 site | -1 line |
| `references/chrome-devtools-mcp-cheatsheet.md` | Update "Stub mode" section: `BROWSER_SKILL_LIB_STUB=1` instead of `CHROME_DEVTOOLS_MCP_BIN`. Update "Limitations" section: rename "Real bridge missing" to "Real MCP transport deferred to part 1c". Add a new "Architecture" subsection noting the bridge.mjs lives at `scripts/lib/node/chrome-devtools-bridge.mjs` and mirrors `playwright-driver.mjs`. | ~25 lines edited |
| `CHANGELOG.md` | One subsection: `### Phase 5 part 1b — cdt-mcp bridge scaffold + lib-stub pivot` | +~12 lines |

### Deleted

| Path | Reason |
|---|---|
| `tests/stubs/chrome-devtools-mcp` | Replaced by lib-stub mode in `chrome-devtools-bridge.mjs`. The 8 fixtures under `tests/fixtures/chrome-devtools-mcp/` stay — bridge reads same path, same sha256 hash logic. |

### Untouched

- `scripts/lib/router.sh` (Path A still — no router edits)
- `scripts/lib/common.sh`
- `scripts/lib/output.sh`
- `scripts/browser-doctor.sh`
- every `scripts/browser-<verb>.sh`
- both pre-existing adapter files (`playwright-cli.sh`, `playwright-lib.sh`)
- 8 fixtures under `tests/fixtures/chrome-devtools-mcp/`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch from main → `feature/phase-05-part-1b-cdt-mcp-bridge`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-1b plan — cdt-mcp bridge scaffold + lib-stub pivot`.

---

## Task 1: Verify sha256 parity bash↔node

Sanity step before writing any production code.

The bash stub's hash is `printf '%s\0' "$@" | shasum -a 256` — that's each arg followed by a NUL, so the bytes for `inspect --capture-console` are `inspect\0--capture-console\0` (26 bytes including both NULs). The node bridge must produce the same digest.

In node:
```js
import { createHash } from 'node:crypto';
const data = argv.map(a => a + '\0').join('');  // 'inspect\0--capture-console\0'
createHash('sha256').update(data).digest('hex');
// expected: af343073058e3234c08e7193ef4da40b433aad63631ecae8119edfe432aa31a5
```

If the digests don't match, fixture lookups will silently miss in real adapter calls (test stubs won't catch this — they'd just exit 41). Verify with the known-good `inspect --capture-console` fixture before continuing.

Steps:
- [ ] **1.1** Run a one-liner that computes both digests and compares.
- [ ] **1.2** Document the canonical hash form in the bridge's header comment so future contributors don't have to re-derive it.

---

## Task 2: RED — pivot bats env vars

Update `tests/chrome-devtools-mcp_adapter.bats` to use `BROWSER_SKILL_LIB_STUB=1` instead of `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"`. The bridge file doesn't exist yet so tests will fail; this is the RED step.

Steps:
- [ ] **2.1** `s/CHROME_DEVTOOLS_MCP_BIN="\${STUBS_DIR}\/chrome-devtools-mcp"/BROWSER_SKILL_LIB_STUB=1/g` across the file.
- [ ] **2.2** `CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp"` stays — bridge reads the same env var.
- [ ] **2.3** Drop the old "tool_doctor_check is ok=true when stub bin is on PATH" test; replace with "tool_doctor_check is ok=true when node is on PATH" (no env var override needed — node is always on CI).
- [ ] **2.4** Argv-shape tests via `STUB_LOG_FILE` stay unchanged; the bridge will log argv there in stub mode.
- [ ] **2.5** Run `bash tests/run.sh tests/chrome-devtools-mcp_adapter.bats` — expect ≥10 failures (every test that expected the bash stub will fail because adapter still calls bin).

---

## Task 3: GREEN — bridge.mjs stub mode

Write `scripts/lib/node/chrome-devtools-bridge.mjs`. Top-level branch on `BROWSER_SKILL_LIB_STUB`.

Sketch:
```js
#!/usr/bin/env node
// scripts/lib/node/chrome-devtools-bridge.mjs
//
// Bridge between the chrome-devtools-mcp adapter (bash) and the upstream
// chrome-devtools-mcp MCP server (npx, JSON-RPC over stdio).
//
// Stub mode (BROWSER_SKILL_LIB_STUB=1): no MCP server spawned. argv hashed
// (sha256 of args joined+terminated by NUL — matches printf '%s\0' behavior),
// fixture file under ${CHROME_DEVTOOLS_MCP_FIXTURES_DIR} echoed, exit 0.
//
// Real mode (default): spawns the MCP server, performs initialize handshake,
// dispatches tools/call. NOT implemented in this PR; deferred to part 1c.

import { createHash } from 'node:crypto';
import { readFileSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
  process.exit(0);
}

throw new Error('chrome-devtools-bridge: real-mode MCP transport deferred to phase-05 part 1c; set BROWSER_SKILL_LIB_STUB=1 to use stub mode');

function stubDispatch(argv) {
  const logFile = process.env.STUB_LOG_FILE;
  if (logFile) {
    const ts = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    appendFileSync(logFile, `--- ${ts} ---\n`);
    for (const a of argv) appendFileSync(logFile, `${a}\n`);
  }

  const data = argv.map(a => a + '\0').join('');
  const hash = createHash('sha256').update(data).digest('hex');

  const here = dirname(fileURLToPath(import.meta.url));
  const fixturesDir = process.env.CHROME_DEVTOOLS_MCP_FIXTURES_DIR
    || join(here, '..', '..', '..', 'tests', 'fixtures', 'chrome-devtools-mcp');
  const fixturePath = join(fixturesDir, `${hash}.json`);

  try {
    process.stdout.write(readFileSync(fixturePath, 'utf8'));
  } catch {
    process.stdout.write(JSON.stringify({
      status: 'error',
      reason: `no fixture for argv-hash ${hash}`,
      argv,
    }) + '\n');
    process.exit(41);
  }
}
```

Steps:
- [ ] **3.1** Write the file per the sketch above.
- [ ] **3.2** Verify directly: `BROWSER_SKILL_LIB_STUB=1 node scripts/lib/node/chrome-devtools-bridge.mjs inspect --capture-console` should echo the inspect fixture's contents.
- [ ] **3.3** Confirm hash matches: `BROWSER_SKILL_LIB_STUB=1 STUB_LOG_FILE=/tmp/log node ... && cat /tmp/log` shows the argv lines.

---

## Task 4: Rewire adapter to bridge

Modify `scripts/lib/tool/chrome-devtools-mcp.sh`:
- Drop `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN`.
- Add `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN` (defaults `${BROWSER_SKILL_NODE_BIN:-node}`).
- Add `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BRIDGE` (resolved relative to adapter file).
- Add `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_MCP_SERVER_BIN` (defaults `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}`) — semantics shift: env var now means "the upstream MCP server binary the bridge spawns in real mode" rather than "the binary the adapter shells to". Doc this in the file header.
- New `_drive` helper: `"${NODE_BIN}" "${BRIDGE}" "$@"`.
- Verb-dispatch fns shell to `_drive verb args` instead of `${BIN} verb args`. Argv translation logic unchanged (the NUL-joined sha256 hashes the same input).
- `tool_doctor_check` rewires to mirror `playwright-lib::tool_doctor_check`: check node on PATH; check bridge file present; report node version + mcp_server_bin name; note that real-mode MCP transport is deferred to part 1c.

Steps:
- [ ] **4.1** Apply the rewire.
- [ ] **4.2** Run `bash tests/run.sh tests/chrome-devtools-mcp_adapter.bats` — expect ALL GREEN.
- [ ] **4.3** Run `bash tests/lint.sh --static-only` (file-content checks) — expect pass.

---

## Task 5: Cleanup — delete bash stub + revert doctor/install env vars

The bash stub is now unreachable from any test. Delete it.

The part-1 additions to `tests/doctor.bats` (3 sites) and `tests/install.bats` (1 site) added `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` so doctor's adapter walk passed. With doctor now checking node-and-bridge instead of a bin (mirroring `playwright-lib`), those overrides are dead weight. Revert them.

Steps:
- [ ] **5.1** `rm tests/stubs/chrome-devtools-mcp`.
- [ ] **5.2** Revert the 3 `CHROME_DEVTOOLS_MCP_BIN` lines in `tests/doctor.bats`.
- [ ] **5.3** Revert the 1 `CHROME_DEVTOOLS_MCP_BIN` line in `tests/install.bats`.
- [ ] **5.4** Run full `bash tests/run.sh` — expect 298 pass / 0 fail.

---

## Task 6: Update cheatsheet

Modify `references/chrome-devtools-mcp-cheatsheet.md`:
- "Status — Path A introduction (phase-05 part 1)" → keep but add "Phase-05 part 1b shipped the node bridge scaffold (stub-mode only). Real MCP transport lands in part 1c."
- "Stub mode" subsection: replace `CHROME_DEVTOOLS_MCP_BIN` override with `BROWSER_SKILL_LIB_STUB=1`.
- New "Architecture" subsection: bridge.mjs at `scripts/lib/node/chrome-devtools-bridge.mjs`; ESM; mirrors `playwright-driver.mjs`.
- "Limitations" subsection: rename "Real bridge missing" → "Real MCP transport deferred to part 1c".

Steps:
- [ ] **6.1** Edit the cheatsheet.
- [ ] **6.2** Run `bash tests/lint.sh --dynamic-only` (cheatsheet path validity check).

---

## Task 7: CHANGELOG + commit + tag + PR

Steps:
- [ ] **7.1** Add `### Phase 5 part 1b` subsection to `CHANGELOG.md` summarizing: bridge scaffold, lib-stub pivot, bash-stub deletion, doctor pivot to node-and-bridge, real-mode deferred to part 1c.
- [ ] **7.2** `bash tests/lint.sh` — exit 0 across all 3 tiers.
- [ ] **7.3** `bash tests/run.sh` — 298 pass / 0 fail.
- [ ] **7.4** Commit: `feat(phase-5-part-1b): cdt-mcp bridge scaffold + lib-stub pivot`.
- [ ] **7.5** Tag: `v0.6.1-phase-05-part-1b-cdt-mcp-bridge`.
- [ ] **7.6** Push branch + tag; `gh pr create`.
- [ ] **7.7** Wait CI green on macos-latest + ubuntu-latest.
- [ ] **7.8** `gh pr merge --squash --delete-branch`.

---

## Acceptance criteria

- [ ] `scripts/lib/node/chrome-devtools-bridge.mjs` exists; stub mode round-trips fixtures with sha256 parity vs the bash stub form.
- [ ] `scripts/lib/tool/chrome-devtools-mcp.sh` shells to `${NODE_BIN} ${BRIDGE}`; no longer references `${CHROME_DEVTOOLS_MCP_BIN}` for dispatch (env var still exists, semantics shifted to "real-mode MCP server bin").
- [ ] `tests/chrome-devtools-mcp_adapter.bats` uses `BROWSER_SKILL_LIB_STUB=1`; all 21 cases pass.
- [ ] `tests/stubs/chrome-devtools-mcp` deleted.
- [ ] `tests/doctor.bats` + `tests/install.bats` reverts: no `CHROME_DEVTOOLS_MCP_BIN` env in those files.
- [ ] Doctor reports cdt-mcp adapter as `ok:true` on plain CI (node present, bridge file present); no env override required.
- [ ] `bash tests/lint.sh` exit 0 across all 3 tiers.
- [ ] `bash tests/run.sh` 298 pass / 0 fail (no count change — same coverage, different mechanism).
- [ ] `scripts/lib/router.sh` UNTOUCHED (Path A held).
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| Real MCP transport in bridge.mjs (initialize handshake + `tools/call` + `uid → eN` translation) | **part 1c** |
| Path B router promotion: `--capture-console`/`--capture-network`/`--lighthouse`/verb=`audit` → cdt-mcp default | **part 1d** |
| Verb scripts: `scripts/browser-audit.sh`, `scripts/browser-extract.sh`; un-skip `tests/browser-inspect.bats` | **part 1e** |
| Chrome `--user-data-dir` session loading | **part 1f** |
| Daemon-resident bridge (mirror playwright-lib's IPC daemon for cdt-mcp) | only if perf demands it; not currently planned |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Sha256 parity bug between bash and node — fixtures silently miss in real adapter calls | Task 1 sanity-checks parity before any production code lands; bridge header comment documents the canonical hash form |
| Bridge spawn time adds latency vs the bash stub (node startup ~30ms) | Acceptable for stub mode; real mode (part 1c) will inherit the same overhead — playwright-lib has it too and is fine |
| Doctor pivot from bin-check to node-and-bridge-check makes adapter look "ok" even when MCP server is unavailable | Honest — that's the truth in this PR. Doctor JSON includes `note: "real-mode MCP transport deferred to phase-05 part 1c"` so the user sees the caveat |
| Test rebase needed if main moves while branch is open | Trivial — no overlapping files with the docs/adapter-candidates PR or any in-flight work |
