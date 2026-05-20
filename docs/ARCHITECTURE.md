# browser-automation-skill — architecture

A durable, top-down map of the codebase. Read this first when adding a new
adapter, a new verb, a new MCP tool, or a new schema. Every design decision
referenced here has a longer-form spec under `docs/superpowers/specs/`;
this doc consolidates them into one navigable surface.

This file is **load-bearing for extension authors**. If you can't find what
you're looking for, file an issue — the gap is real.

---

## 1. Purpose (the core idea, never changes)

Drive a real browser from Claude Code such that:

1. **Effective.** A verb invocation has a predictable, single-line JSON outcome.
2. **Accurate.** Every adapter call self-audits via a post-condition assertion
   so adapter-lies surface as `oblivious_success` in telemetry.
3. **Remembered.** Site + session + credential + capture + cache state lives
   under `~/.browser-skill/` (mode 0700) and survives sessions. Memory is
   intent-keyed so repeat actions cost zero LLM tokens.
4. **Secure.** Credentials never appear on argv, in git, or in the Claude
   transcript (AP-7). Captures are sanitized by default. The state dir is
   chmod 0700; per-file mode 0600.

Everything beyond those four invariants is extendable. Adapters,
verbs, capture formats, model backends, schema versions, MCP tools, local-VLM
stacks — all swappable without touching the core idea.

---

## 2. Codebase at a glance (2026-05-20 census)

| Layer | File count | LOC | Role |
|---|---:|---:|---|
| Verb scripts (`scripts/browser-*.sh`) | 44 | ~10 500 | One per skill verb. Parse argv → resolve site/session → pick adapter → invoke → emit telemetry → emit summary JSON. |
| Library (`scripts/lib/*.sh`) | 16 | ~3 400 | Shared concerns: common (errors/logging), output (emit_summary), router, verb_helpers, site/session/credential mgmt, capture pipeline, memory cache, stats telemetry, migration framework. |
| Tool adapters (`scripts/lib/tool/*.sh`) | 4 | ~1 500 | Plug-in points implementing the **Adapter ABI** (§5). One file per browser-driver backend. |
| Migrators (`scripts/lib/migrators/<schema>/*.sh`) | 1 | ~30 | One per schema version bump. Currently `memory/v1_to_v2.sh` (no-op identity). |
| Node helpers (`scripts/lib/node/*.mjs`) | 8 | ~5 600 | Cross-runtime bridges: chrome-devtools-bridge (1812 LOC client to chrome-devtools-mcp), playwright-driver (1104 LOC), mcp-server (191 LOC publishing OUR verbs as MCP tools), TOTP, URL-pattern utils. |
| Test suite (`tests/*.bats`) | 76 | ~12 000 | bats-core. Adapter contract tests, verb tests, lib unit tests, end-to-end daemon tests. Stubs + fixtures decouple from real browsers. |
| References (`references/*.md` + `references/recipes/*.md`) | 25 | — | Per-adapter cheatsheets, anti-patterns, extension recipes, agent-workflow walk-throughs. |
| Specs + plans (`docs/superpowers/{specs,plans}/*.md`) | 60+ | — | The why behind every Phase. Specs hold acceptance criteria; plans hold task breakdowns. |
| Total | 230+ | ~33 000 | Bash-heavy + Node bridges + bats tests + Markdown design corpus. |

---

## 3. Layer map

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                  CALLER                                      │
│                                                                              │
│  Claude Code skill invocation       External MCP clients                     │
│  (bash scripts/browser-<verb>.sh)   (midscene, agent-browser,                │
│                                      Stagehand, Continue, Cline)             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                ┌──────────────────┴──────────────────┐
                │                                     │
                ▼                                     ▼
  ┌────────────────────────────┐    ┌────────────────────────────────────┐
  │ Verb script                │    │ scripts/lib/node/mcp-server.mjs    │
  │ scripts/browser-<verb>.sh  │    │ (JSON-RPC NDJSON over stdio,       │
  │                            │    │  whitelisted env passthrough,      │
  │ - argv parsing             │◄───┤  spawns bash verb scripts)         │
  │ - site/session resolution  │    └────────────────────────────────────┘
  │ - cache lookup             │
  │ - adapter pick (router)    │
  │ - invoke + retry           │
  │ - post-condition check     │
  │ - stats event emit         │
  │ - capture write            │
  │ - single-line summary out  │
  └────────────┬───────────────┘
               │
               ▼
  ┌────────────────────────────┐    ┌────────────────────────────────────┐
  │ scripts/lib/router.sh      │───▶│ scripts/lib/tool/<adapter>.sh      │
  │ (capability filter +       │    │                                    │
  │  precedence rules)         │    │ Adapter ABI: 8 tool_* verb-fns +   │
  │                            │    │ tool_metadata + tool_capabilities  │
  │                            │    │ + tool_doctor_check                │
  └────────────────────────────┘    └────────┬───────────────────────────┘
                                             │
                                             ▼
                              ┌──────────────────────────────────┐
                              │ Upstream driver                  │
                              │  playwright (CLI / lib)          │
                              │  chrome-devtools-mcp (via bridge)│
                              │  obscura (stealth scraper)       │
                              └──────────────────────────────────┘
                                             │
                                             ▼
                                     ┌──────────────────┐
                                     │  Real browser    │
                                     │  (Chromium)      │
                                     └──────────────────┘
```

Local-VLM stack (orthogonal — opt-in, doesn't sit on this critical path):

```
  scripts/browser-vlm.sh start            scripts/browser-doctor.sh
         │                                         │ (advisory probe)
         ▼                                         ▼
  llama-server (lean config; Metal)  ◄─────  curl /health
  http://127.0.0.1:8080                      "ok / not running"
         ▲
         │ MIDSCENE_MODEL_* env passes through MCP server whitelist
         │
  midscene client OR Path 3 cache-rescue probe (future)
```

---

## 4. State (everything mutable lives here)

```
~/.browser-skill/                       mode 0700, gitignored
├── version                              schema marker
├── versions.json                        per-schema versions (memory/sites/sessions/captures/baselines)
├── config.json                          retention thresholds + warn_at_pct  (mode 0600)
├── current                              currently-selected site name        (mode 0600, PERSONAL)
├── baselines.json                       named baseline registry             (mode 0600)
├── sites/    <name>.json + .meta.json   site profiles                       (mode 0600, SHAREABLE)
├── sessions/ <name>.json + .meta.json   storageState (cookies)              (mode 0600, PERSONAL — gitignored)
├── credentials/                          keychain / libsecret / plaintext   (per-backend)
├── captures/                             snapshots/, screenshots/, hars/, traces/, videos/, pdfs/, NNN/ dirs
├── flows/                                .flow.yaml definitions
├── memory/
│   ├── stats.jsonl                      per-action telemetry                (mode 0600)
│   ├── stats.db                         SQLite mirror (built from JSONL)
│   ├── events.jsonl                     browser-do cache hits/misses
│   ├── recent_urls.jsonl                passive navigation log
│   └── <site>/
│       ├── patterns.json                URL pattern → archetype-id mapping  (mode 0600, PERSONAL)
│       └── archetypes/<id>.json         cached (intent → selector) entries  (mode 0600, PERSONAL)
├── vlm.pid                              PID of running llama-server          (Phase 14, mode 0600)
└── vlm.log                              llama-server stdout+stderr           (Phase 14, mode 0600)
```

Per-schema migration framework (`scripts/lib/migrate.sh` +
`scripts/lib/migrators/<schema>/v<from>_to_<to>.sh`) lets each subdirectory
evolve independently. Doctor never auto-migrates; user runs
`browser-migrate run` explicitly.

---

## 5. The Adapter ABI (extension point #1)

Every file under `scripts/lib/tool/<name>.sh` MUST declare these 11
functions, enforced by `tests/lint.sh` (tier 1):

```bash
tool_metadata()         # → JSON: { name, abi_version, version_pin, cheatsheet_path, install_hint }
tool_capabilities()     # → JSON: { verbs: { <verb>: { flags: [...] } } }
tool_doctor_check()     # → JSON: { ok: bool, binary, version?, error?, install_hint? }

tool_open()             # all 8 verb-dispatch functions; return 41 (EXIT_TOOL_UNSUPPORTED_OP)
tool_click()            # if the verb is not in this adapter's capability set.
tool_fill()
tool_snapshot()
tool_inspect()
tool_audit()
tool_extract()
tool_eval()
```

Adapters are **LEAVES** — never source another adapter. Shared logic
factors into `scripts/lib/<concern>.sh`.

**Current adapter roster** (per `references/tool-versions.md`):

| Adapter | Strong at | Notes |
|---|---|---|
| `playwright-cli` | navigation, click, fill, snapshot | CLI shells to playwright binary. Default router pick for these verbs. |
| `playwright-lib` | session-loaded operations, --secret-stdin | Node-bridged, reads storageState, accepts stdin secrets safely (AP-7). |
| `chrome-devtools-mcp` | inspect, audit, extract, console, network, lighthouse | Node bridge to upstream chrome-devtools-mcp MCP server. Daemon mode for stateful verbs. |
| `obscura` | stealth scrape, multi-URL | Auto-routes on `--scrape` and `--stealth` flags. |

**Candidates evaluated but not shipped** (see `references/adapter-candidates.md`):
- `pinchtab` — declined; concrete unblock triggers documented.

### How to add a new adapter

Read `references/recipes/add-a-tool-adapter.md` end-to-end. Two-paragraph
summary:

1. Copy `scripts/lib/tool/playwright-cli.sh` as `scripts/lib/tool/<your-tool>.sh`.
   Implement all 11 functions. Unsupported verbs return `EXIT_TOOL_UNSUPPORTED_OP`
   (41). Source `scripts/lib/output.sh` for `emit_summary`/`emit_event`/
   `capture_path` — never hand-roll JSON (spec
   `2026-05-01-token-efficient-adapter-output-design.md` §8 enforces).
2. Write `tests/<your-tool>_adapter.bats` mirroring
   `tests/chrome-devtools-mcp_adapter.bats`. Add at least one fixture under
   `tests/fixtures/<your-tool>/`. Adapter starts opt-in via
   `--tool=<your-tool>`; promotion to router default happens in a later
   PR after a soak window (anti-pattern AP-4 — don't promote in the
   shipping commit).

---

## 6. Verb scripts (extension point #2)

Each `scripts/browser-<verb>.sh` follows the same shape:

```bash
#!/usr/bin/env bash
set -euo pipefail; IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/output.sh"
source "${SCRIPT_DIR}/lib/router.sh"
source "${SCRIPT_DIR}/lib/verb_helpers.sh"
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths
SUMMARY_T0="$(now_ms)"; export SUMMARY_T0
parse_verb_globals "$@"
resolve_session_storage_state

# 1. argv → verb_argv (strip global flags, normalise per-verb flags)
# 2. picked="$(pick_tool <verb> "${verb_argv[@]}")"
# 3. tool_name=${picked%%$'\t'*}; why=${picked#*$'\t'}
# 4. source_picked_adapter "${tool_name}"
# 5. stats_t0="$(now_ms)"
# 6. set +e; adapter_out="$(invoke_with_retry <verb> "${verb_argv[@]}")"; adapter_rc=$?; set -e
# 7. (optional Phase 14) auto-derive BROWSER_STATS_EXPECT_* per verb
# 8. stats_run_adapter_emit "<verb>" "${tool_name}" "${stats_t0}" "${adapter_rc}" \
#                            "${adapter_out}" "" -- "${verb_argv[@]}" || true
# 9. [ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"
# 10. emit_summary verb=<verb> tool="${tool_name}" why="${why}" status=ok ...
```

The pattern is so consistent that `verb_helpers.sh` factors most of it.
A new verb is ~80–150 LOC + a bats file.

### How to add a verb

1. Pick a name that doesn't collide with existing 44 verbs (see SKILL.md
   verb table or `ls scripts/browser-*.sh`).
2. Copy the closest existing verb script (e.g. `browser-click.sh` for
   action verbs, `browser-snapshot.sh` for capture verbs).
3. Declare the verb in each adapter's `tool_capabilities()` it supports
   (or leave it returning 41 in adapters that don't).
4. Add routing precedence to `scripts/lib/router.sh` if it shouldn't
   default to playwright-cli.
5. Write `tests/browser-<verb>.bats`.
6. Update `SKILL.md` verb table.

---

## 7. The output contract (token-efficient stdout)

Spec: `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`

Every verb writes:

1. Zero or more streaming JSON lines (optional per-verb).
2. **Exactly one** summary JSON line as the LAST stdout line.

Stderr is reserved for `ok:` / `warn:` / `error:` human messages — never
parsed by routing logic.

Summary required keys (§3.1): `verb, tool, why, status, duration_ms`.
Verb-specific keys add inline: `url`, `title`, `text`, `count`, `ref`, `selector`.
For heavy assets: write to capture file, return `<asset>_path` reference
(§2.2 "reference over value"). Phase 14 added `snapshot_path` + `n_refs` for
snapshot YAML > 2 KB.

Spec §7 lists six WRONG/RIGHT pairs (anti-patterns). Lint tier 3
(`tests/lint.sh --drift-only`) enforces.

---

## 8. Telemetry contract (every adapter call is observable)

`scripts/lib/stats.sh::stats_run_adapter_emit` writes one JSONL line per
adapter invocation to `${BROWSER_SKILL_HOME}/memory/stats.jsonl`. Schema
documented in `references/stats-schema.json` (JSON Schema draft-2020-12).
Field naming follows OpenInference + OTel GenAI v1.40 conventions for
direct Langfuse / Phoenix / Jaeger compatibility via an OTLP exporter.

Per-event fields include:
- Span IDs (`span_id`, `trace_id`, `parent_span_id`) for distributed correlation
- `adapter_route` + `verb` + `selector_kind` + `selector_value`
- `duration_ms`, `argv_bytes`, `stdout_bytes`, `stderr_bytes`
- `outcome` ∈ {success, fail, partial, skipped}
- `failure_mode` from a 14-value enum (Phase 14 added `unknown_failure`)
- Token usage fields (populated when `CLAUDE_USAGE_*` env vars present)
- Post-condition fields (`target_type`, `matcher`, `expected`, `observed`, `hit`)

**The killer accuracy signal**: `oblivious_success` fires when an adapter
reports `outcome=success` but the post-condition check fails. Without it,
self-reported success rates lie. Phase 14 wired `BROWSER_STATS_EXPECT_*`
auto-derivation into `browser-open.sh` so the signal lights up automatically.

Read paths: `scripts/browser-stats.sh` exposes `rebuild`/`report`/`mark`/`tune`.
SQLite mirror under `memory/stats.db` is lazy-built from cursor.

---

## 9. The MCP surface (extension point #3 — outward-facing)

`scripts/lib/node/mcp-server.mjs` publishes 5 of our verbs as MCP tools
(JSON-RPC 2.0 NDJSON over stdio, protocol `2024-11-05`):

- `browser_open`, `browser_snapshot`, `browser_click`, `browser_fill`, `browser_extract`

Every `tools/call` spawns the matching `scripts/browser-<verb>.sh`,
parses its single-line summary, returns it as `content[0].text`.
`_meta.exitCode` + `_meta.stderr` are surfaced for diagnostics.

**Env-var passthrough is WHITELISTED** (not blanket-inherited). Whitelist
prefixes: `BROWSER_SKILL_*`, `BROWSER_STATS_*`, `CLAUDE_*`, `MIDSCENE_MODEL_*`,
`PLAYWRIGHT_*`, `CHROME_DEVTOOLS_*`, `OBSCURA_*`, `STUB_*`, `FIXTURES_*`, `MCP_*`.
Plus POSIX essentials. See `mcp-server.mjs::filteredEnv()` for the full
list and `references/browser-mcp-cheatsheet.md` for the table.

AP-7 (no secrets in argv): `browser_fill` schema deliberately has NO
`secret` property and sets `additionalProperties: false`. MCP has no stdin
channel, so secrets MUST be passed via direct `scripts/browser-fill.sh --secret-stdin`
invocation, never through MCP. Test
`tests/browser-mcp.bats::browser_fill REJECTS attempts to pass secrets via MCP`
codifies this contract.

### How to expose a new verb via MCP

1. Add an entry to `TOOLS` in `scripts/lib/node/mcp-server.mjs`:
   `{ name, description, inputSchema, verbScript, argMap }`.
2. Mirror the bash verb's required-vs-optional flags in JSON Schema.
3. Set `additionalProperties: false`. Use `oneOf` for mutually-exclusive
   arg groups (ref vs selector, selector vs eval).
4. Update `references/browser-mcp-cheatsheet.md` "Tools exposed" table.
5. Write 2–3 bats tests in `tests/browser-mcp.bats` (success path,
   argument validation, env-passthrough check if applicable).

---

## 10. SOLID audit (evidence per principle)

### Single Responsibility (SRP) — STRONG
Each verb script does exactly one verb. Each lib module owns one concern
(common.sh = errors+logging only; output.sh = JSON emission only;
router.sh = adapter pick only). The single-caller helpers
(`sanitize.sh`, `mask.sh`, `secret_backend_select.sh`, `flow_record.sh`)
are correctly scoped — each isolates a domain-specific concern from its
verb's main flow.

**Largest file**: `scripts/lib/node/chrome-devtools-bridge.mjs` at 1812 LOC
contains stub-mode + one-shot real-mode + daemon-mode in one file.
Cohesive (one upstream MCP server, one bridge contract) but split into
3 modules in a future PR would be cleaner.

### Open / Closed (OCP) — STRONG
Adding a new adapter, verb, MCP tool, or migrator does NOT require
editing any existing adapter, verb, or core lib. The Adapter ABI is the
extension seam; the router is the only file aware of all adapters (and
only via filesystem glob, not hardcoded names).

**Drift**: `mcp-server.mjs::TOOLS` is currently a hand-maintained list. A
future enhancement could auto-derive from each adapter's
`tool_capabilities()` JSON to remove the manual sync step.

### Liskov Substitution (LSP) — STRONG
Any adapter is interchangeable with any other at the router boundary, as
long as `tool_capabilities()` declares the verb. The unified `eN`-ref
scheme (spec §5) means a snapshot from playwright-cli is fully addressable
by a click sent to chrome-devtools-mcp (after `uid → eN` translation at
the adapter boundary).

### Interface Segregation (ISP) — STRONG
Adapters declare only the verbs they support (`tool_capabilities().verbs`).
The router refuses to route a verb to an adapter that hasn't declared it
(`pick_tool` capability filter). No "do-nothing stub" sprawl.

### Dependency Inversion (DIP) — STRONG
Verb scripts depend on the ROUTER abstraction (`pick_tool`,
`source_picked_adapter`, `invoke_with_retry`) — never on adapter
internals. The verb has no knowledge of which adapter will be picked.

---

## 11. Quarantine + security boundaries

| Boundary | Mechanism |
|---|---|
| File system | `~/.browser-skill/` mode 0700; per-file mode 0600. Verb scripts use `init_paths` (lib/common.sh) — no hardcoded paths. |
| Argv | AP-7: secrets via stdin only. Lint regression test `tests/browser-fill.bats::secret-not-in-argv`. MCP server schema rejects `secret` property. |
| Env vars (MCP) | Whitelist filter in `mcp-server.mjs::filteredEnv()`. Bats verifies arbitrary envvar is BLOCKED from child. |
| Process | Each adapter call runs in its own subshell (`$(invoke_with_retry ...)`). Test bodies use `setup_temp_home` + `teardown_temp_home` for isolation. |
| Network | Verb scripts never make network calls directly; only adapters do. Lint catches `curl`/`wget`/`nc` at file scope in any adapter (`tests/lint.sh` static checks). |
| Captures | Sanitization on by default (`scripts/lib/sanitize.sh`). Captures gitignored. Audit flag `meta.sanitized` tracks state. |
| Git | `.gitignore` excludes `~/.browser-skill/`, `*.session.json`, etc. `.githooks/` blocks accidental credential commits (opt-in via install.sh --with-hooks). |
| Telemetry | Local-only (`memory/stats.jsonl`). No remote sink. `chrome-devtools-mcp` opt-out of upstream Clearcut via `--no-usage-statistics`. |
| Schema migrations | Atomic-swap + automatic backup. JSON validation precedes version bump. Lock file prevents concurrent runs. Doctor never auto-migrates. |

---

## 12. Test discipline (3 tiers)

`tests/lint.sh` runs three tiers (Phase 3 Task 13):

| Tier | What it checks | Failure mode |
|---|---|---|
| 1 — static | Adapter ABI conformance: every adapter exports 11 functions; no `cd` at file scope; no network calls outside `tool_*` functions; each adapter has a `<name>_adapter.bats`; file size cap (500 LOC per adapter). | Build red |
| 2 — dynamic | Subshell + JSON validation: each adapter's identity functions return valid JSON. | Build red |
| 3 — drift | Generated docs match generator output (`scripts/regenerate-docs.sh`). | Build red |

Plus the bats suite itself: 1050+ tests covering every verb + every lib + a few daemon-mode end-to-end paths. Stubs (`tests/stubs/`) replace external binaries; fixtures (`tests/fixtures/<adapter>/<sha>.json`) decouple from real browsers + real MCP servers.

---

## 13. Extension recipe index

The `references/recipes/` directory holds the discipline. Each recipe is
~1 KB and answers ONE "how do I…" question:

| Recipe | When you need it |
|---|---|
| `add-a-tool-adapter.md` | Adding a new browser-driver backend |
| `anti-patterns-tool-extension.md` | Before promoting a new adapter to router default |
| `body-bytes-not-body.md` | Telemetry: token-counting heavy assets |
| `cache-write-security.md` | Adding new `browser-do record` paths |
| `fingerprint-rescue.md` | Phase 13 stale-selector cache recovery |
| `model-routing.md` | Per-task model selection (OpenInference) |
| `path-security.md` | Filesystem-traversal prevention |
| `privacy-canary.md` | Detecting secret-leak regressions |
| `agent-workflows/login-then-scrape.md` | First-task tutorial for skill users |
| `agent-workflows/incremental-pattern-discovery.md` | Passive cache learning loop |
| `agent-workflows/flow-record-and-replay.md` | `flow record` + `replay` lifecycle |
| `agent-workflows/cache-driven-bulk-operation.md` | 50+ actions at zero LLM tokens |

---

## 14. Roadmap markers (open backlog)

Filed in `references/adapter-candidates.md` (rejected/deferred adapters)
and `references/midscene-integration.md` (three integration paths). Brief
synopsis of what's NOT yet done:

- **Stage 3 MCP verbs**: `browser_wait`, `browser_press`, `browser_select`,
  `browser_assert`. Pattern + tests laid down by Stage 1/2; each is
  ~50 LOC + bats.
- **Notifications/progress on MCP**: long-running verbs (audit, flow run)
  could emit progress events. MCP supports it; we don't yet.
- **Path 3 cache-rescue via local VLM**: highest-ROI token saver but
  blocked on model accuracy. Qwen3-VL-4B-q4_K_M smoke (Phase 14) showed
  borderline accuracy on primary-color identification; bump to 8B-q4 or
  4B-q8 or UI-TARS-1.5-7B before wiring.
- **Path 1 midscene-bridge as 5th adapter**: narrow scope (canvas /
  mobile / vision-only). Less urgent than Path 3.
- **agent-browser pattern borrows**: `--content-boundaries` sentinels,
  `--annotate` ref-overlay screenshots, semantic-locator `find role X --name Y`.
  Filed in `adapter-candidates.md`; cherry-pick when telemetry shows pain.
- **`browser-do` cache activation on registered sites**: wire
  `do propose` into `open` tail (~20 LOC). Real-world repetition starts
  compounding to zero-token actions.
- **MCP TOOLS auto-derivation**: replace hand-maintained array with
  capability-discovery loop reading each adapter's
  `tool_capabilities()`. Removes one couple-point.
- **Split `chrome-devtools-bridge.mjs`** (1812 LOC) into stub/one-shot/
  daemon modules. Cohesive but large; SRP refactor.

---

## 15. Reading order for new contributors

Approximate ramp from zero to "I can extend this":

1. **`SKILL.md`** — what the skill does, verb table, output contract pointer.
2. **This file (`docs/ARCHITECTURE.md`)** — layer map, extension points.
3. **`docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`** — original design rationale, scope, non-goals.
4. **`docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md`** — adapter ABI, routing model.
5. **`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`** — output contract, anti-patterns.
6. **`references/recipes/add-a-tool-adapter.md`** — first-extension walkthrough.
7. **`scripts/lib/tool/playwright-cli.sh`** — the simplest live adapter (156 LOC). Read it end-to-end; this is the template.
8. **`tests/playwright-cli_adapter.bats`** — matching test surface.
9. **One verb script of choice** — `scripts/browser-snapshot.sh` is medium-complexity, exercises the most pieces (router, capture, stats, post-condition derivation).

After step 9 you have a working mental model. After that, pick from the
roadmap markers or file a new extension request.

---

## 16. Invariants (what we promise won't change)

These are the load-bearing contracts. Breaking any of them is a
**[breaking]** change and requires a major version bump + migration plan.

1. The verb's last stdout line is a single-line JSON summary with
   `{verb, tool, why, status, duration_ms}` at minimum.
2. Adapter ABI: 11 functions, returning JSON, never network-calling at
   file scope, never sourcing other adapters.
3. State dir at `~/.browser-skill/` mode 0700; per-file mode 0600.
4. Secrets via stdin only (`--secret-stdin`). No exceptions through MCP
   or any other surface.
5. Telemetry is local-only. No remote sink. Ever.
6. Schema migrations are explicit; doctor never auto-migrates.

Everything else is extension territory.
