# Phase 5 part 1 — chrome-devtools-mcp adapter (Path A — opt-in)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the third concrete adapter — `scripts/lib/tool/chrome-devtools-mcp.sh` — implementing the Phase-3 ABI in **Path A** form (opt-in via `--tool=chrome-devtools-mcp`; zero edits to `scripts/lib/router.sh`, doctor, or any verb script). The adapter declares all 8 verbs (`open click fill snapshot inspect audit extract eval`) so the capability filter in `pick_tool` lets `--tool=` callers exercise the full surface. Real-mode is a sentinel `EXIT_TOOL_UNSUPPORTED_OP` + JSON hint pointing at the deferred MCP stdio bridge (part 1b). Stub mode mirrors the `playwright-cli` adapter exactly — argv hash → fixture lookup — so the bats suite + CI stay portable on machines without `chrome-devtools-mcp` installed.

**Architecture choice — sentinel real-mode, deferred bridge:** The upstream `chrome-devtools-mcp` is an MCP server (npx-spawned, JSON-RPC over stdio), not a CLI binary. Implementing the stdio MCP client bridge is substantial (~250 LOC node + transport tests). Splitting the adapter introduction (this PR) from the bridge (part 1b) follows AP-4 (no same-PR promotion) and the Phase-4-part-4a precedent (real-mode shipped dark, then bridge wired in part 4b). Capability declaration is sufficient to make the adapter Path-A reachable today.

**Tech stack:** Bash 5+, jq, bats-core. No new runtime deps for this PR (node + npx land with the bridge in part 1b).

**Spec references:**
- Parent spec §1 (`chrome-devtools-mcp` listed in `doctor`'s dependency set), §13 Appendix A row 27 (`inspect`), Appendix B routing matrix (chrome-devtools-mcp picked for `--capture-console`/`--capture-network`/`--lighthouse`/verb=`audit` — Path B work, deferred to part 1c).
- Extension-model spec §2 (ABI surface), §4 (routing precedence stays single-source-of-truth in `router.sh`), §6 (autogen recipe).
- Token-efficient-output spec §3 (output schema), §8 (lint tier 3 — adapters MUST source `scripts/lib/output.sh`).
- `references/recipes/add-a-tool-adapter.md` Path A checklist — canonical 8-step recipe followed below.
- `references/recipes/anti-patterns-tool-extension.md` AP-4 (no same-PR promotion), AP-5 (no hand-edit autogen), AP-6 (namespace-prefix file-scope globals), AP-7 (no secrets in argv), AP-8 (no network at file-source time).

**Branch:** `feature/phase-05-part-1-chrome-devtools-mcp`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/tool/chrome-devtools-mcp.sh` | Adapter — ABI funcs + 8 verb-dispatch fns; sources `output.sh`; shells to `${CHROME_DEVTOOLS_MCP_BIN}` (overridable for stub) | ≤ 300 LOC |
| `tests/stubs/chrome-devtools-mcp` | Mock binary — argv-hash → fixture (mirrors `tests/stubs/playwright-cli`) | ≤ 50 LOC |
| `tests/fixtures/chrome-devtools-mcp/<sha>.json` | Canned responses for inspect/audit/snapshot/eval happy paths (~4 fixtures) | small |
| `tests/chrome-devtools-mcp_adapter.bats` | Adapter contract + verb-dispatch via stub | ≤ 250 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | When-to-use; opt-in via `--tool=`; deferred-bridge call-out | ≤ 150 LOC |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `references/tool-versions.md` | Autogen — picks up new adapter row | regen |
| `SKILL.md` | Autogen — tools-table grows by 1 row | regen |
| `CHANGELOG.md` | One line: `[adapter] added chrome-devtools-mcp (Path A — opt-in via --tool=chrome-devtools-mcp)` | +1 |

### Untouched (Path A discipline)

- `scripts/lib/router.sh`
- `scripts/lib/common.sh`
- `scripts/lib/output.sh`
- `scripts/browser-doctor.sh`
- every `scripts/browser-<verb>.sh`
- `references/routing-heuristics.md`
- `tests/router.bats`
- `scripts/lib/tool/playwright-cli.sh`, `scripts/lib/tool/playwright-lib.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch from main → `feature/phase-05-part-1-chrome-devtools-mcp`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-1 plan — chrome-devtools-mcp adapter (Path A)`.

---

## Task 1: RED — bats skeleton

**Files:** Create `tests/chrome-devtools-mcp_adapter.bats` with a small contract-only skeleton (file existence will fail until task 2).

Skeleton tests (~6 cases):
- file exists + readable
- `tool_metadata` returns valid JSON
- `tool_metadata.name == "chrome-devtools-mcp"` (matches filename — lint tier 2 enforces)
- `tool_metadata.abi_version == BROWSER_SKILL_TOOL_ABI` (lint tier 2 enforces)
- `tool_metadata` has `version_pin` + `cheatsheet_path`
- all 8 verb-dispatch fns are defined

Steps:
- [ ] **1.1** Write skeleton bats matching the layout of `tests/playwright-cli_adapter.bats`.
- [ ] **1.2** Run `bash tests/run.sh` — expect new file's tests to fail (adapter file missing).

---

## Task 2: GREEN — minimal adapter

**Files:** Create `scripts/lib/tool/chrome-devtools-mcp.sh`.

Adapter shape (mirrors `playwright-cli.sh` + `playwright-lib.sh`):

- Sentinel guard: `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_LOADED` (AP-6 namespace prefix).
- `source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"` (lint tier 3 enforces).
- Readonly bin var: `_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN="${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}"`.

`tool_metadata`:
```json
{
  "name": "chrome-devtools-mcp",
  "abi_version": 1,
  "version_pin": "0.x",
  "cheatsheet_path": "references/chrome-devtools-mcp-cheatsheet.md",
  "install_hint": "npm i -g chrome-devtools-mcp (or run via 'npx chrome-devtools-mcp@latest' over stdio MCP)"
}
```

`tool_capabilities` — declare all 8 verbs (B1 surface):
```json
{
  "verbs": {
    "open":     { "flags": ["--headed", "--url"] },
    "click":    { "flags": ["--ref"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": ["--depth"] },
    "inspect":  { "flags": ["--capture-console", "--capture-network", "--screenshot"] },
    "audit":    { "flags": ["--lighthouse", "--perf-trace"] },
    "extract":  { "flags": ["--selector", "--eval"] },
    "eval":     { "flags": ["--expression"] }
  }
}
```

`tool_doctor_check` (E1 minimal): `command -v "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}"`; on miss return `{ok:false, ..., install_hint}`; on hit return `{ok:true, binary, version}` from `--version` if available else `"unknown"`. No network at source time (AP-8).

Verb-dispatch (8 fns): every fn shells to the bin with verb-positional-then-translated argv (mirror `tool_open`/`tool_click` pattern from playwright-cli — translate skill flags to positional where the upstream MCP wrapper expects positional). The adapter's caller invariant is: stub mode binary returns the canned fixture; real mode binary doesn't exist on most boxes, so the doctor + lint paths cover that case loudly.

Real-mode failure shape (C1 sentinel): when `${CHROME_DEVTOOLS_MCP_BIN}` is the default (`chrome-devtools-mcp`) and not on PATH, the verb-dispatch shell exec fails — which is fine; the test stub overrides via `CHROME_DEVTOOLS_MCP_BIN`. We do NOT add a stub-mode env var because the bin override is sufficient (mirror playwright-cli).

`tool_fill --secret-stdin` honored: pipe stdin through to bin invocation (the bin contract reads stdin when `--secret-stdin` present). This differs from `playwright-cli` which rejects stdin (no upstream support); chrome-devtools-mcp's `fill_form` MCP tool can pass values from a stdin-staged JSON envelope, so we support it via the fixture stub.

Steps:
- [ ] **2.1** Write `scripts/lib/tool/chrome-devtools-mcp.sh` — sentinel + identity + 8 verb-dispatch fns.
- [ ] **2.2** Run `bash tests/run.sh tests/chrome-devtools-mcp_adapter.bats` — expect skeleton tests pass.
- [ ] **2.3** Run `bash tests/lint.sh --static-only` — expect pass (file-content checks).

---

## Task 3: Stub binary + fixtures

**Files:** Create `tests/stubs/chrome-devtools-mcp` + `tests/fixtures/chrome-devtools-mcp/*.json` (~4 fixtures).

Stub contract (verbatim mirror of `tests/stubs/playwright-cli`):
- `chmod +x` executable.
- Logs argv (one per line) to `${STUB_LOG_FILE:-/tmp/chrome-devtools-mcp-stub.log}` for argv-shape assertions.
- `sha256(argv joined by NUL)` → `tests/fixtures/chrome-devtools-mcp/<sha>.json`. Print + exit 0 on hit.
- On miss: `{"status":"error","reason":"no fixture for argv-hash <sha>","argv":[...]}` + exit 41.

Fixtures (4 to start; argv shapes determined by adapter's translation):
- `inspect --capture-console` → `{"event":"inspect","console_messages":2,"network_requests":5}`
- `audit --lighthouse` → `{"event":"audit","lighthouse_score":0.92}`
- `snapshot` → `{"event":"snapshot","refs":[{"id":"e1","role":"button","name":"Submit"},{"id":"e2","role":"link","name":"Home"}]}`
- `eval --expression "1+1"` → `{"event":"eval","value":2}`

Each fixture's filename = `sha256("$@" joined by NUL)` of the argv the adapter actually emits to the bin. Compute via:
```bash
printf '%s\0' "verb-as-shelled" "arg1" "arg2" | shasum -a 256 | awk '{print $1}'
```

Steps:
- [ ] **3.1** Determine adapter's argv-shape per verb (read `tool_open`/`tool_inspect`/etc bodies); record canonical argv for each fixture.
- [ ] **3.2** Compute sha256 for each; write the 4 fixture files.
- [ ] **3.3** Write `tests/stubs/chrome-devtools-mcp` (copy + adapt `tests/stubs/playwright-cli`).
- [ ] **3.4** `chmod +x tests/stubs/chrome-devtools-mcp`.

---

## Task 4: Full bats coverage

**Files:** Expand `tests/chrome-devtools-mcp_adapter.bats` to ~14 cases.

Coverage (mirror playwright-cli_adapter.bats + add the cdt-mcp-specific ones):
- 6 contract cases (already in skeleton).
- `tool_capabilities.verbs.inspect` exists (cdt-mcp's flagship verb — ASSERTS the differentiator).
- `tool_capabilities.verbs.audit` exists.
- `tool_capabilities.verbs.extract` exists.
- `tool_doctor_check` returns valid JSON with `.ok` boolean.
- `tool_open --url ...` shells to bin with translated argv (no `--url` leaks if translation occurs).
- `tool_snapshot` echoes fixture refs (length == 2).
- `tool_inspect --capture-console` echoes fixture (cdt-mcp's reason-to-exist).
- `tool_audit --lighthouse` echoes fixture.
- `tool_eval --expression "1+1"` echoes fixture.
- `tool_fill --secret-stdin` accepts stdin (does NOT 41 like playwright-cli does).
- Missing-fixture path: stub returns 41; adapter propagates.

Steps:
- [ ] **4.1** Expand the bats file with the new cases.
- [ ] **4.2** Run `bash tests/run.sh tests/chrome-devtools-mcp_adapter.bats` — expect all green.

---

## Task 5: Cheatsheet + autogen + CHANGELOG + lint

**Files:** Create `references/chrome-devtools-mcp-cheatsheet.md`. Autogen `references/tool-versions.md` + `SKILL.md`. Edit `CHANGELOG.md`.

Cheatsheet sections (mirror `references/playwright-cli-cheatsheet.md`):
- When the router picks this adapter — table marking ALL eight verbs as "no — opt-in via `--tool=` until part 1c"; flagship cells call out `inspect`/`audit`/`extract` as the long-term defaults per Appendix B.
- Capabilities declared (copy `tool_capabilities` JSON).
- Doctor check (the `--version` line).
- Version pin (`0.x` until upstream stabilizes).
- Override syntax (`--tool=chrome-devtools-mcp`).
- Limitations: real MCP stdio bridge deferred to part 1b; today the adapter is reachable only via a stub or a binary that wraps `npx chrome-devtools-mcp@latest` for you.
- See-also: parent spec, recipe, AP doc.

Steps:
- [ ] **5.1** Write `references/chrome-devtools-mcp-cheatsheet.md`.
- [ ] **5.2** Run `bash scripts/regenerate-docs.sh all` — autogens `references/tool-versions.md` + the `SKILL.md` tools-table block.
- [ ] **5.3** Add CHANGELOG line under a new `### Phase 5` subsection.
- [ ] **5.4** Run `bash tests/lint.sh` (all 3 tiers) — expect exit 0.
- [ ] **5.5** Run `bash tests/run.sh` — expect 274 + ~14 new = ~288 pass / 0 fail.
- [ ] **5.6** Commit: `feat(phase-5-part-1): chrome-devtools-mcp adapter (Path A — opt-in)`.
- [ ] **5.7** Tag: `v0.6.0-phase-05-part-1-chrome-devtools-mcp`.

---

## Acceptance criteria

- [ ] `tests/chrome-devtools-mcp_adapter.bats` — adapter contract + 8 verb-dispatch + secret-stdin path + missing-fixture path (~14 cases).
- [ ] `tests/run.sh` green (current 274 + ~14 new).
- [ ] `bash tests/lint.sh` exit 0 across all three tiers (static / dynamic / drift).
- [ ] `scripts/regenerate-docs.sh all` produces a 3-row `tool-versions.md` (playwright-cli + playwright-lib + chrome-devtools-mcp) and 3-row SKILL.md tools-table.
- [ ] `scripts/lib/router.sh` UNTOUCHED (Path A invariant).
- [ ] Every `scripts/browser-<verb>.sh` UNTOUCHED.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| Real stdio MCP-client bridge (`scripts/lib/node/chrome-devtools-bridge.mjs`) — spawns `npx chrome-devtools-mcp@latest`, speaks JSON-RPC over stdio, marshals responses | **part 1b** |
| Router promotion: `--capture-console`/`--capture-network` → cdt-mcp; `--lighthouse`/`--perf-trace`/verb=`audit` → cdt-mcp (Path B) | **part 1c** (after `--tool=` soak) |
| New verb scripts: `scripts/browser-audit.sh`, `scripts/browser-extract.sh`; un-skip `tests/browser-inspect.bats` | **part 1d** |
| Session-loading via Chrome `--user-data-dir` (different mechanism than playwright-lib's `storageState`) | **part 1e** |
| Capture sanitisation (HAR redact, Authorization-header strip) | Phase 7 |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Adapter declares verbs but no real bridge means `--tool=` calls hit exit-41 on most boxes | Doctor check surfaces it; cheatsheet calls it out; tests use stub override; CI is unaffected |
| Capability declaration drifts from real MCP-tool surface | Capabilities mirror upstream's tool list (see `mcp__chrome-devtools__*` enumerated in repo's HANDOFF + claude tool list); part 1b will validate against the real bridge |
| 14 new tests increase CI runtime | Stub-mode bats fast (~50ms each); ≤ 1s total added |
| Path A discipline drift in future PRs | AP-4 + recipe checklist + this plan's `Untouched` list make any router edit visible in review |
