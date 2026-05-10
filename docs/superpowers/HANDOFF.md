Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-11 — Selector-mode plumbing fully adapter-complete for fill+click; whitelist `[click fill hover select]`)

main is at tag `v0.55.0-playwright-lib-selector` (HEAD `6ab59df`). **Phases 1-9 SHIPPED + Phase 11 ✅ FEATURE-COMPLETE for v1 (5/5) + selector-mode plumbing IN FLIGHT — 3/4 verbs shipped (fill + hover + select joined click; press deferred per SS5) + playwright-lib `--selector` driver plumbing SHIPPED (PR #105 — fill + click adapter-complete across all three routed adapters).** Phase 6 closed at 11/11 verbs; Phase 7 closed at 5/5 (capture pipeline); Phase 8 closed at 4/4 (obscura adapter); Phase 9 closed at 5/5 (flow runner); Phase 11 closed at 5/5 sub-parts; cache-write-security.md recipe SHIPPED (PR #94).

**`summary_json` jq-reserved-keyword cleanup also shipped (PR #73).** The pre-existing local-only failure on `tests/browser-select.bats:6` (tracked since Phase 6 as "jq-version-dependent") was traced to `summary_json` building filters where caller-supplied field names doubled as jq variable names — collisions on `label`, `def`, `or`, `and`, `not`, etc. Fix prefixes internal jq variables with `_v_`; output JSON shape unchanged.

### Phase 11 progress (PR #57 design, #88 1-i, #90 1-ii, #92 1-iii, #94 recipe, #95 2-i, #97 2-ii) — ✅ FEATURE-COMPLETE for v1 (5/5 sub-parts)

| Sub-part | Scope | Status |
|---|---|---|
| 11 design | Phase 11 design doc (`2026-05-08-phase-11-memory-design.md`). Locks M1+U1+E1+H1. | ✅ |
| 11-1-i | `scripts/lib/memory.sh` foundation — 8-fn API (init_dir, load/save_archetype, lookup, record, record_failure, record_pattern, resolve_archetype). Storage shape v1 frozen (`memory/<site>/{patterns.json, archetypes/<id>.json}` mode 0600 in mode-0700 dirs). H1 mechanic shipped (`fail_count > 3 → disabled:true`). **Deviation from design U1:** URLPattern global only stable in Node 23.8+; CI defaults to Node 20 until June 2026 — swapped to hand-rolled regex matcher (`:name` → `[^/]+`, `*` → `.*`); deterministic across Node versions; native URLPattern can replace when CI baseline lifts. | ✅ |
| 11-1-ii | `browser-do` verb — two sub-modes: `--verb VERB --intent "..."` (cache lookup; on hit dispatches existing `browser-VERB.sh --selector $cached`; on miss emits `_kind:cache_miss` event + exit 11) and `record --intent --selector --url` (explicit write-back via `memory_record` + `memory_record_pattern`; auto-derives pattern + archetype-id). **Deviation from design E1:** skill stays **model-agnostic** — verb does NOT call LLM; on miss, parent agent picks ref via its own snapshot+reasoning then explicitly calls `record`. v1 `--verb` whitelist = `[click]` only (other selector-target verbs take only `--ref eN` today; expand when adapter ABI gains selector-mode plumbing). Privacy canary refuses cache writes containing `PASSWORD-CANARY` → exit 28. Best-effort write-back: cache failure is `warn:`-only; doesn't taint dispatched verb's exit code. | ✅ |
| 11-1-iii | Self-heal loop — wires `memory_record_failure` into `browser-do --intent`'s post-dispatch failure path. **D1 exit-code whitelist** = `EMPTY_RESULT(11)` + `ASSERTION_FAILED(13)` only (network/tool/timeout codes are environmental; don't poison cache). **D2 re-record-heals-disabled:** `memory_record` upsert path resets `fail_count:0` + `disabled:false`. **D3 disabled is indistinguishable from "never cached"** at verb layer (agent response identical → no behavior gain from distinguishing). **D4 trigger only on confirmed cache-hit-then-dispatch-failed.** **D5 best-effort failure recording.** `BROWSER_DO_DISPATCH_OVERRIDE` env hook ships as test-only seam. **Phase 11 part 1 CLOSED.** | ✅ |
| recipe `cache-write-security.md` | Codifies Phase 11 part 1 cache-write contract: 5 rules (whitelist surface · canary refusal · best-effort writes · self-heal exit-code whitelist · schema-locked storage shape). WRONG/RIGHT snippets per rule. 8-case test template. "Don't" anti-patterns. Cross-references `privacy-canary.md`, `path-security.md`, `anti-patterns-tool-extension.md` (AP-7), Phase 11 design doc §6/§12/§3. Pure-docs PR; no tag bump. | ✅ |
| 11-2-i | `browser-do --intent` gains `--pattern '/devices/:id'` + `--archetype devices-id` flags (symmetric with `record` sub-mode shipped 1-ii). **R1 — Resolution priority (most-explicit-wins):** `--archetype NAME` > `--pattern PAT` > `--url URL` > none → `cache_miss reason:no_pattern_for_url` (backwards-compat preserved). **R2 — `--archetype` honors `assert_safe_name`.** **R3 — `--pattern` is read-side only** (does NOT call `memory_record_pattern`; `record` remains sole pattern-writing path). **R4 — No new `cache_miss` reason variants** (matches 1-iii D3 disabled-vs-never-cached precedent). | ✅ |
| 11-2-ii | `browser-do propose [--site] [--threshold N] [--url ...]` sub-mode — auto-cluster URL pattern detection. Reads URLs from `--url` args + stdin (one per line); clusters by templated pathname (numeric → `:id`, UUID → `:uuid`); emits `_kind:proposal` events for clusters meeting threshold AND not already in `patterns.json`. **C1 — Pure compute, no new persistence** (agent owns URL collection; composable with shell pipes). **C2 — Heuristic = numeric + UUID only for v1** (slug heuristic deferred — too high-entropy). **C3 — Default threshold N=3.** **C4 — Suppress already-known patterns.** **C5 — Always emit; never auto-record.** **C6 — Always exits 0.** New `scripts/lib/node/url-pattern-cluster.mjs` mirrors 1-i `url-pattern-resolver.mjs` precedent. **Phase 11 part 2 CLOSED. Phase 11 ✅ FEATURE-COMPLETE for v1.** | ✅ |

### Selector-mode plumbing for `browser-do --verb` whitelist (PRs #99 fill, #101 hover, #103 select) — IN FLIGHT (3/4 verbs shipped; press deferred)

| Sub-PR | Scope | Status |
|---|---|---|
| selector-mode-fill | `scripts/browser-fill.sh` accepts `--selector CSS` (mutually exclusive with `--ref eN`; mirrors `browser-click.sh` precedent). `playwright-cli` + `chrome-devtools-mcp` adapter `tool_fill` accept `--ref\|--selector` alias. **`browser-do --verb` whitelist grows: `[click]` → `[click fill]`.** **S2 — playwright-lib `--selector` deferred** (driver IPC schema bump; coordinate with click in its own PR; doesn't make existing behavior worse — playwright-lib doesn't support --selector for click either). | ✅ (PR #99) |
| selector-mode-hover | `scripts/browser-hover.sh` accepts `--selector CSS`. `chrome-devtools-mcp` adapter `tool_hover` accepts `--ref\|--selector` alias. **H2 — Adapter coverage = chrome-devtools-mcp only** (other adapters don't define `tool_hover`; router routes hover exclusively there). **H3 — Bridge unchanged.** **`browser-do --verb` whitelist grows: `[click fill]` → `[click fill hover]`.** | ✅ (PR #101) |
| selector-mode-select | `scripts/browser-select.sh` accepts `--selector CSS`. `chrome-devtools-mcp` adapter `tool_select` accepts `--ref\|--selector` alias. **SS2 — Adapter coverage = chrome-devtools-mcp only.** **SS3 — Bridge unchanged.** **SS4 — Mode flags (`--value`/`--label`/`--index`) unchanged**, exactly one required. **`browser-do --verb` whitelist grows: `[click fill hover]` → `[click fill hover select]`.** | ✅ (PR #103) |
| selector-mode-press (DEFERRED per SS5) | **Survey discovered `tool_press` accepts only `--key`; bridge `case 'press':` (chrome-devtools-bridge.mjs:488) takes only `key`, no target by design** (line 1098: "Stateless w.r.t. refMap — acts on the focused element or page"). Adding selector-targeting requires bridge schema bump for new "focus + press" semantic — bigger surface than per-verb mechanical pattern. Deferred to separate decision: (a) new `--focus-selector` flag on press, (b) skip from cache scope entirely, or (c) compose with click+press (no cache for press; relies on existing focus state). **Option (c) recommended — no-op-for-cache.** | 🔲 separate decision |
| playwright-lib `--selector` driver plumbing | `runFill` + `runClick` flag handling + `case 'fill'`/`case 'click'` IPC handler updates use `page.locator(selector).first()` when `msg.selector` present. **PL1 — Backwards-compatible IPC schema** (no version bump; additive). **PL2 — fill + click coordinated** in same PR (matched semantics). **PL3 — Selector path skips refMap precondition** (locators don't need snapshot). **PL4 — Hover NOT in scope** (no playwright-lib path; cdt-mcp-only per router). **PL5 — Adapter unchanged** (already passes argv verbatim). Secret-scrub semantics preserved on selector path. | ✅ (PR #105) |

### Phase 9 progress (PRs #77 design, #78, #80, #82, #84, #86) — ✅ COMPLETE

| Sub-part | Scope | Status |
|---|---|---|
| 9 design | Phase 9 design doc (`2026-05-10-phase-09-flow-runner-design.md`). Locks F1-F8. | ✅ |
| 9-1-i | `flow run <file>` foundation. Bash-side YAML parser. `_kind`-tagged JSON. `${var}`. Whole-flow capture. `--var` / `--dry-run`. | ✅ |
| 9-1-ii | `${refs.NAME}` resolution + `assert` step. flow_apply_vars refs-mode; flow_dispatch extracts refs[]; FLOW_REFS latest-wins. New `browser-assert.sh` (composition; no adapter ABI changes). | ✅ |
| 9-1-iii | `flow record` — wraps `playwright codegen`; `scripts/lib/flow_record.sh`. Regex-based JS→YAML mapper. Password canary write-side: `/password/i` → `${secrets.password}` placeholder; literal dropped. | ✅ |
| 9-1-iv | `replay <id>` — `scripts/browser-replay.sh` + `flow_diff_steps` helper. Per-step `replay_diff` + aggregate summary. `--strict` exits 13. Strips `duration_ms` before comparison. | ✅ |
| 9-1-v | `history list/show/diff/clear` + `baseline save/list/remove`. `history diff` reuses `flow_diff_steps`. `baseline` is thin wrapper over Phase 7's `meta.is_baseline:true` skip-rule (forward-compat landed in 7-1-v). `baselines.json` mode 0600. Folds in `browser-clean.sh` follow-up as `history clear`. **Phase 9 CLOSED.** | ✅ |

### Phase 8 progress (PRs #68, #70, #72, #75) — ✅ COMPLETE

| Sub-part | Scope | Status |
|---|---|---|
| 8-1-i | obscura adapter shell — `tool_metadata` + `tool_capabilities` (verbs: extract) + `tool_doctor_check` + 8 verb-dispatch fns (all 41-stubs). Path A "ship-without-promotion" (zero `router.sh` edits). Cheatsheet doc; `tests/stubs/obscura` `--version` mock. doctor enumerates 4 adapters now (was 3). | ✅ |
| 8-1-ii | `tool_extract --scrape <urls...>` real-mode — wraps `obscura scrape u1 u2 ... [--eval EXPR] [--concurrency N] --format json`. Per-URL streaming JSON event (direct jq emit; preserves `eval`'s `serde_json::Value` typing) + aggregate summary (`mode=scrape / total_urls / successful / failed`). Stub upgraded to fixture-based (`--version` short-circuits before STUB_LOG_FILE write); 3 fixtures. `--scrape` flag plumbing in `browser-extract.sh`. | ✅ |
| 8-1-iii | `tool_extract --stealth <url>` real-mode — wraps `obscura fetch <url> --stealth --eval EXPR`. Single URL; `--eval` required (without it `obscura fetch` dumps full HTML). One `extract_stealth` event with `{event, url, eval}` (eval always emitted as string — typed parsing deferred). `tool_extract` refactored to thin mode-dispatcher with `_tool_extract_scrape` + `_tool_extract_stealth` internal helpers. Modes mutually exclusive. New fixture; `--stealth` flag plumbing in `browser-extract.sh`. | ✅ |
| 8-2-i | Router promotion (Path B) — added `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES` (placed BEFORE `rule_extract_default`). Auto-routes `--scrape` / `--stealth` to obscura without `--tool` flag. Capability filter handles mismatched verbs (e.g. `open --scrape` falls through to playwright-cli). Cheatsheet flipped to "yes (default)". **Phase 8 CLOSED.** | ✅ |

### Phase 7 progress (PRs #56, #60, #62, #64, #66) — ✅ COMPLETE

| Sub-part | Scope | Status |
|---|---|---|
| 7-1-i | `lib/capture.sh` foundation (3-fn API: capture_init_dir / capture_start / capture_finish) + opt-in `--capture` on snapshot | ✅ |
| 7-1-ii | `lib/sanitize.sh` — pure jq-function library (sanitize_har + sanitize_console). 15 bats; 5 fixture JSONs; no verb integration | ✅ |
| 7-1-iii | `inspect --capture` wire-up — first composition test for capture + sanitize. Persists console.json + network.har sanitized; defense in depth (stdout sanitized too); 6-canary privacy regression suite. | ✅ |
| 7-1-iv | `--unsanitized` typed-phrase ack (`I want raw network/console data including auth tokens`) + `meta.sanitized: false` audit flag + `doctor` counter | ✅ |
| 7-1-v | `capture_prune` (count>500 / age>14d) + retention thresholds in `~/.browser-skill/config.json` + `_index.json` recompute on prune. Baseline-protection forward-compat (Phase 8). Cross-platform age parsing. | ✅ |

### Counters

- **41 user-facing verbs** (browser-do shipped 1-ii; 1-iii/2-i/2-ii extend it — no new verbs).
- **`browser-do --verb` whitelist:** `[click fill hover select]` (selector-mode plumbing 3/4 — press deferred per SS5).
- **5 lib helpers shipped post-Phase-7**: `scripts/lib/capture.sh`, `scripts/lib/sanitize.sh`, `scripts/lib/flow.sh` (gained `flow_diff_steps` in 9-1-iv), `scripts/lib/flow_record.sh`, `scripts/lib/memory.sh` (Phase 11 1-i; gained D2 re-record-heals-disabled tweak in 1-iii).
- **2 node helpers shipped Phase 11**: `scripts/lib/node/url-pattern-resolver.mjs` (1-i: URL→archetype lookup), `scripts/lib/node/url-pattern-cluster.mjs` (2-ii: URL clustering for propose).
- **7 recipes shipped**: `add-a-tool-adapter.md`, `anti-patterns-tool-extension.md`, `body-bytes-not-body.md`, `model-routing.md`, `path-security.md`, `privacy-canary.md`, **`cache-write-security.md`** (Phase 11 part 1 follow-up; PR #94).
- **4 of 4 adapter shells exist**; all 4 routed to as defaults for at least one verb. obscura: `tool_extract` real-mode for `--scrape` + `--stealth`; remaining 7 verb-dispatch fns 41-stub by design. doctor enumerates `adapters_ok:4`.
- **3 of 3 Tier-1 credential backends**.
- **899 tests pass / 0 fail / lint exit 0** locally (895 baseline + 4 playwright-lib_adapter.bats from playwright-lib-selector).
- **101 PRs merged total** (Phase 7 parts 1-i through 1-v + Phase 11 design + skill model-routing + 18 HANDOFF refreshes + Phase 8 parts 1-i/1-ii/1-iii/2-i + summary_json jq-keyword fix + Phase 9 design + Phase 9 parts 1-i/1-ii/1-iii/1-iv/1-v + Phase 11 parts 1-i/1-ii/1-iii + cache-write-security recipe (PR #94) + Phase 11 part 2-i (PR #95) + Phase 11 part 2-ii (PR #97) + selector-mode-fill (PR #99) + selector-mode-hover (PR #101) + selector-mode-select (PR #103) + **playwright-lib-selector (PR #105)**; not counting this HANDOFF refresh).

## Capture pipeline shape (shipped through 7-1-v — full)

```
${BROWSER_SKILL_HOME}/
├── config.json                                  # mode 0600 (NEW in 7-1-v)
│     { schema_version: 1, retention_days: 14,
│       retention_count: 500, warn_at_pct: 90 }
└── captures/                                    # mode 0700 (lazy-created)
    ├── _index.json                              # mode 0600 (recomputed on prune)
    │     {schema_version: 1, next_id: N, count: M, latest: "NNN", total_bytes: B}
    └── NNN/                                     # mode 0700, zero-padded 3-digit
        ├── meta.json                            # mode 0600
        │     { capture_id, verb, schema_version: 1,
        │       started_at, finished_at, status,
        │       sanitized,                        # 7-1-iv audit field
        │       total_bytes, files,
        │       is_baseline?  (Phase 8 forward-compat) }
        ├── snapshot.json                        # 7-1-i (snapshot verb)
        ├── console.json                         # 7-1-iii (inspect, sanitized)
        └── network.har                          # 7-1-iii (inspect, sanitized)
```

Per-aspect files (Phase 7 inventory):
- `snapshot.json` (snapshot verb)
- `console.json` + `network.har` (inspect verb; sanitized by default; raw under `--unsanitized` typed-phrase opt-out)
- Future: `screenshot.png`, `trace.zip`, `lighthouse.json` (audit verb — likely Phase 8 follow-up)

`meta.json`, `_index.json`, `config.json` schemas all **frozen at v1** for Phase 7. Field additions are non-breaking; renames/removals bump `schema_version`.

**Auto-prune contract:** every `capture_finish` calls `capture_prune` at end. Idempotent. Skip rules: `is_baseline:true` (Phase 8 forward-compat), `status:"in_progress"` (in-flight protection). Cross-platform age parsing via `_capture_iso_to_epoch` (GNU `date -d` → BSD `date -j -f` fallback).

## Next session: pick up at press-cache-decision OR Phase 10 OR Phase 11 v2 hardening OR daemon-e2e for selector path

playwright-lib `--selector` ✅ shipped (PR #105). Selector-mode plumbing now adapter-complete for fill+click across all three routed adapters (playwright-cli + chrome-devtools-mcp + playwright-lib). 3/4 verbs shipped (fill+hover+select); press deferred per SS5.

**Three roughly equal-priority next picks (each independent):**

**Pick A — Press cache-scope decision (tiny pure-docs PR if option b/c):**
- Pick option (a) new `--focus-selector` flag on press, (b) skip from cache scope entirely, or (c) compose: agent calls `browser-do --verb click --intent "focus input"` followed by `browser-press --key Enter` (no cache for press; relies on existing focus state).
- **Recommended (c) — no-op-for-cache.** Tiny pure-docs PR adds explicit "press not cacheable" note to `cache-write-security.md` recipe + closes SS5 deferral.

**Pick B — Phase 10 (schema migration tooling):**
- Per parent spec §13.6. Necessary infra when ANY v1 schema bumps to v2. Currently no urgent demand — no schema needs bumping today.

**Pick C — Phase 11 v2 hardening (any single item):**
- Slug heuristic in `url-pattern-cluster.mjs` (entropy-based; medium design surface).
- `--auto-record` flag on `browser-do propose` (small).
- Pattern-equivalence canonicalization (`/devices/:id` ≡ `/devices/:itemId`; small-medium).
- Active observation log (`recent_urls.jsonl`; small-medium; coordinates with Phase 10).

**Pick D — Daemon e2e for playwright-lib selector path:**
- Write `tests/playwright-lib_stateful_e2e.bats` cases that spin up the daemon, open a page, fill/click via `--selector`. Independent from PR #105's parse-layer tests; covers the IPC handler selector branches end-to-end. Estimated small-medium PR.

**Recommended:** **Pick A — close press cache-scope decision** with option (c) recommendation. Smallest reviewable PR; codifies the SS5 deferral as a permanent decision in `cache-write-security.md`; closes one open question while context is fresh. Then go for **Pick C** items in subsequent sessions.

**Phase ordering recap:**
- Phase 8 ✅ COMPLETE (4/4 obscura + router promotion)
- Phase 9 ✅ COMPLETE (5/5 flow runner)
- Phase 11 ✅ FEATURE-COMPLETE for v1 (5/5: memory cache + verb + self-heal + manual `--pattern` + auto-cluster `propose`)
- Recipe `cache-write-security.md` ✅ SHIPPED (PR #94)
- **Selector-mode plumbing — 3/4 verbs shipped** (fill+hover+select joined click; press deferred per SS5)
- **playwright-lib `--selector` ✅ SHIPPED** (PR #105 — fill+click adapter-complete)
- Press cache-scope decision 🔲 — pick (a)/(b)/(c); recommend (c)
- Phase 10 🔲 — schema migration tooling
- Phase 11 v2 hardening 🔲 — slug heuristic / `--auto-record` / canonicalization / active observation
- Daemon e2e for playwright-lib selector path 🔲 — independent quality follow-up

## Phase 11 — memory (design doc shipped; implementation queued AFTER Phase 9)

User confirmed (2026-05-08) that no memory-like feature is currently shipped. Sites profile holds login selectors (manually entered); daemon `refMap` is in-memory only; Phase 9's planned `flow record` is manual recording, not auto-learned. The auto-learned per-archetype selector/action cache (the "get smarter the more we use it" pattern from Skyvern/Stagehand/Agent-E) is a **Phase 11 candidate**.

Design doc: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md`. Decisions locked: M1+U1+E1+H1.

| Sub-part | Scope | Status |
|---|---|---|
| 11-1-i | `lib/memory.sh` foundation (read/write archetype JSON; URL→archetype via hand-rolled regex matcher — see deviation note in §11 progress table above) | ✅ (PR #88) |
| 11-1-ii | `browser-do --intent "..."` verb — cache lookup → hit-direct OR miss-fallback to snapshot+reasoning + write-back | 🔲 next |
| 11-1-iii | Self-healing — fail_count threshold → invalidate → re-resolve | 🔲 |
| 11-2-i | Manual user-defined `--pattern '/devices/:id'` flag | 🔲 |
| 11-2-ii | Auto-cluster URL patterns (observe N visits; propose pattern) | 🔲 |

**Sequencing locked.** Phase 11 implementation begins **after Phase 9 ships** (flow runner). Reasoning: flow record's manual semantics establish the deliberate-recording contract first; auto-recording layered on. Memory + flow record overlap (both are interaction-recording); ordering avoids retroactive contract changes.

**Open follow-up after Phase 11 part 1:** new recipe `references/recipes/cache-write-security.md` codifying selector-injection guards + cache-write privacy canary. **User confirmed: ships AFTER Phase 11 part 1, not with it.**

**Storage shape (frozen at v1):**
```
~/.browser-skill/memory/                       # mode 0700 (lazy-created)
├── _index.json                                # mode 0600
└── <site>/
    ├── patterns.json                          # URL → archetype mapping
    └── archetypes/<archetype_id>.json         # mode 0600
          { schema_version: 1, archetype_id, url_pattern,
            first_seen, last_seen, use_count,
            interactions: [{intent, selector, success_count, fail_count, disabled, ...}] }
```

**Cost compounding.** Memory hits = zero LLM tokens. Combined with model-routing default (`model: sonnet` + `effort: low` per skill turn) + `/model opusplan` parent session, fully realized memory is the **largest cost lever in the roadmap**. Target: ≥ 70% cache hit rate after 20+ similar actions per archetype (Agent-E-validated threshold).

## Workflow expectations (proven across 83 PRs)

- **TDD muscle-memory**: branch + bats RED → GREEN → lint → tag → push → PR → CI → squash-merge → reset main. ~95%+ CI-green-first-try across the project.
- **Phase 6 sub-part shape** (mechanical): bridge daemon dispatch case + capability declaration + tool dispatcher + router rule + verb script + bats + stub handler + drift sync (`scripts/regenerate-docs.sh all`) + plan-doc + CHANGELOG.
- **Phase 7 sub-part shape** (developing): lib helper file + bats unit cases + (eventually) verb wire-up + plan-doc + CHANGELOG. No router/adapter changes (capture is verb-script-level, not adapter-level).
- **Lint must exit 0** at all 3 tiers (`bash tests/lint.sh`). Drift-tier triggers when adapter capabilities change → run `regenerate-docs.sh all`.
- **Test-mode env vars** for testability without real Chrome (production paths gate on these):
  - `BROWSER_SKILL_LIB_STUB=1` — bridge fixture lookup mode.
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` / `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` — driver short-circuit hooks.
- **Cross-platform shell idioms**: GREP REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). `read -r -d ''` for NUL-stdin (bash vars can't hold NUL — but for stdin passthrough to a node bridge, the bash side doesn't read stdin at all; bridge's `readAllStdin` does).
- **Bats 1.13 footgun (new)**: `@test "..."` strings get `eval`-expanded by bats (line 471 of `test_functions.bash`) so parameterized names work. Side effect: any unbound `${VAR}` in a test description blows up `set -u` *before any test runs*. Never reference live shell variables in test names — keep them literal text.
- **CI workflow** runs on macos-latest + ubuntu-latest. Doesn't install Playwright/cdt-mcp by default — driver real-mode tests gated; bats coverage via stubs (`tests/stubs/mcp-server-stub.mjs` handles 19 MCP tools used by the bridge).
- **Privacy-canary pattern** (10+ instances now): every credential-emitting verb gets a sentinel canary in its bats file. Recipe: `references/recipes/privacy-canary.md`.
- **Path-security pattern** (introduced in 6-6 upload): sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization. Recipe: `references/recipes/path-security.md`.
- **Body-bytes-not-body pattern** (introduced in 7-ii route fulfill): when a verb ingests caller-supplied content, ship the byte length in the reply, not the content. Recipe: `references/recipes/body-bytes-not-body.md`.
- **Model-routing pattern** (new): three-tier strategy — parent session uses `opusplan` (or `/advisor` for advanced); this skill's turn drops to `model: sonnet` + `effort: low` via SKILL.md frontmatter; per-verb override deferred until demand surfaces. Recipe: `references/recipes/model-routing.md`.
- **Memory pattern** (Phase 11 — design shipped, implementation queued after Phase 9): per-archetype `(site, url_pattern, intent_phrase) → selector` cache; cache hits skip LLM inference entirely. Composes with model-routing for compounding cost reduction. Design: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md`. Recipe (post-Phase-11-1): `cache-write-security.md`.
- **Padded-NNN-id-as-string pattern** (codified in 7-1-i): zero-padded identifiers (`001`, `042`, `999`) are **strings**, not integers — `summary_json`'s numeric regex now rejects leading-zero ints. Future padded-id fields (capture_id today; possibly baseline_id in flow runner) preserve padding through the summary serializer.
- **Failure-path-finalize pattern** (codified in 7-1-i): when a verb opens a side-effect resource (capture dir, lock file, temp dir), the failure branch must run the same finalization as success — never leave `in_progress` orphans on disk. Test the failure-finalize directly; agents discovering an `in_progress` capture dir is a regression.
- **Defense-in-depth validation pattern** (codified in 7-ii): same validation at three layers (bash verb → bridge → daemon-child). Each layer is cheap (<10 lines). Daemon-child layer is the only required test surface for non-CLI IPC paths.
- **HANDOFF-refresh-as-separate-PR pattern** (proven 14 times now: PR #47, #50, #52, #54, #67, #69, #71, #74, #76, #79, #81, #83, #85, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh). **Combined-refresh exception** (PR #74): when two substantive PRs land back-to-back without HANDOFF-impacting differences (e.g. 8-1-iii + a focused jq-fix), one combined refresh works.
- **New-adapter-CI-trap pattern** (codified in 8-1-i CI fixup): adding a 4th adapter without a stub binary breaks the **two existing tests** that assert `"all checks passed"` (doctor.bats:12 + install.bats:103). Reason: doctor's exit-status matrix returns `partial` (still exit 0) when ≥1 adapter is OK but ≥1 fails — the **output assertion** fails (warn line replaces "all checks passed") even though `assert_status 0` passes. Fix shape: ship `tests/stubs/<adapter>` mirroring `tests/stubs/playwright-cli`'s shape + wire `<ADAPTER>_BIN=${STUBS_DIR}/<adapter>` into both tests. **Future adapter PRs MUST include the stub + test wiring in the same PR** — CI failure on first push otherwise. Two precedents now (playwright-cli stub + obscura stub).
- **Streaming-events-via-direct-jq pattern** (codified in 8-1-ii): when an adapter's per-result events carry **arbitrary JSON values** (e.g. `eval` field is `serde_json::Value` upstream — can be string/number/array/null/object), `emit_event` falls short — its `key=value` autodetect only handles scalar types. Bypass `emit_event` for those streaming events and emit via direct `jq -c '...'` over the upstream payload (with `+ {event:"name"}` add and field projection). `emit_summary` stays the path for **summary** lines (fixed scalar fields, validation guards). Lint tier 3 only requires the adapter sources `output.sh`; not every line must go through emit helpers.
- **Stub-version-short-circuit-before-log pattern** (codified in 8-1-ii): when a fixture-based stub's binary doubles as a `--version` health-check responder (cf. tests/stubs/obscura), the `--version` branch MUST short-circuit and return BEFORE the STUB_LOG_FILE write. Otherwise, doctor probes during unrelated tests pollute argv-shape assertion logs and cause spurious matches in subsequent grep-based tests. Pattern is enforced by a dedicated bats case (`stub --version short-circuits before fixture lookup`).
- **Adapters-don't-source-common pattern** (codified in 8-1-iii): adapters MUST NOT call `common.sh` helpers (e.g. `now_ms`, `assert_safe_name`) directly. Production paths always have `common.sh` loaded BEFORE the adapter is sourced (verb script → common.sh → router.sh → adapter), but adapter unit tests source the adapter standalone. Calling `now_ms` from inside the adapter works in production but fails in tests with `command not found`. Pattern: **don't fabricate values that the upstream tool doesn't provide** (e.g. obscura `fetch` doesn't report `time_ms`, so the adapter omits it; the verb-script's `duration_ms` covers end-to-end timing). When adapters genuinely need a helper, hoist it to the adapter's own private `_<name>_<helper>` namespace OR have the verb-script pre-compute and pass via flag.
- **Decouple-jq-variable-names-from-JSON-field-names pattern** (codified in PR #73): `--arg <name> X` followed by `$<name>` triggers jq's tokenizer keyword collision when `<name>` matches a reserved word (`label`, `def`, `or`, `and`, `not`, `if`, `then`, `else`, `end`, `as`, `reduce`, `foreach`, `try`, `catch`, `import`, `include`, `module`, `true`, `false`, `null`, `break`). Even though `--arg label X` "should" bind a variable, jq parses `label` as the early-exit-syntax keyword instead. Fix: prefix internal jq variable names with `_v_` so the variable-name space is decoupled from caller-supplied JSON field names. **Same pattern applies anywhere bash builds jq filters dynamically from user-supplied identifiers.** Lint candidate: grep for `--arg <key> ... \\$<key>` patterns; flag if `<key>` matches the reserved set. Deferred until a third instance surfaces.
- **Path A → Path B adapter rollout pattern** (Phase 8 closure proof): Phase 8 split the obscura adapter rollout into Path A (`--tool obscura` only; zero `router.sh` edits) for 8-1-i / 8-1-ii / 8-1-iii, then Path B (router promotion adds default-routing) in 8-2-i. Each PR carried single-concern risk: Path A PRs reviewed adapter / verb backend / fixture-stub design without routing entanglement; Path B PR reviewed two precedence rules with full capability-filter test coverage. The pattern lives in `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` §4.4 and proved its value end-to-end across 4 PRs and 4 sub-parts of Phase 8. **Adopt for any future adapter (Phase 9+ if applicable).**
- **Capability-filter-as-safety-net pattern** (highlighted by 8-2-i): when a precedence rule fires for a verb the named tool doesn't support (e.g. `open --scrape` triggers `rule_scrape_flag` → obscura, but obscura doesn't declare `open`), the capability filter rejects + emits `warn: rule X picked TOOL but it doesn't support verb=Y; falling through` and the router walks to the next rule. **Routing-rule typos are caught at runtime, not in production traffic** — the cost is one extra `_tool_supports` jq call per fall-through. Codified in `tests/router.bats` (`open --scrape falls through to playwright-cli`). Future precedence rules should NOT defensively add their own verb checks; trust the capability filter.
- **Design-doc-first-at-phase-boundary pattern** (proven 3 times now: parent spec authorship pre-Phase-1, Phase 11 design PR #58 pre-Phase-11, Phase 9 design pre-Phase-9): when opening a multi-sub-part phase, ship the design doc as its own PR (or fold inline if pure-docs) BEFORE coding starts. Locks decisions; surfaces open questions; gives reviewers something to push back on without diff-context. The design doc is never code; it's the contract that subsequent sub-part plan-docs reference. **Skip only if the phase is one sub-part with obvious shape.**
- **Subshell-survivable bash function output pattern** (codified in 9-1-i `flow_parse`): when a bash function needs to "return" structured data through `$(...)` capture, **emit JSON lines, not set globals**. Bash globals don't cross subshell boundaries; `parsed="$(my_fn)"` strips them. Tag each line with a discriminator (`{_kind: "meta", ...}` vs `{_kind: "step", ...}`) so callers can sort/filter the output. Generic for any "parse a config file → emit per-record events" use case in this project (memory archetypes in Phase 11, replay step iteration in 9-1-iv).
- **Spec-vs-implementation calibration pattern** (highlighted in 9-1-i): the design doc said "node-helper with js-yaml"; implementation discovered the npm-dep cost outweighed the parse-robustness gain at the v1-subset scope. **Spec is a guide, not a contract — when implementation surfaces a better trade-off, document the deviation in the CHANGELOG entry rather than silently changing course or rigidly following the spec.** The CHANGELOG becomes the authoritative record of what shipped vs what was specced; future agents read both.
- **Composition-over-ABI-extension pattern** (codified in 9-1-ii `assert` verb): when a new verb is a thin transform over an existing primitive, ship it as a verb script that COMPOSES the primitive (shells out + transforms output) rather than extending the adapter ABI with a new `tool_<verb>` function. Costs: 1 verb script (~80 LOC). Avoids: N adapter implementations × duplicated logic + router rule + capability-sync test extension + ABI bump. **`assert` chose composition** (shells to `extract --selector`; bash-compares text); compare with `tool_extract --scrape` (8-1-ii) which earned ABI placement because it had a unique adapter backend (obscura's parallel-scrape; not a transform over an existing verb). Decision rubric: **does the new behavior need adapter-specific code, OR is it the same logic regardless of which adapter is underneath?** If the latter — compose, don't extend.
- **Mid-flow state-harvest pattern** (codified in 9-1-ii browser-flow.sh main loop): when a multi-step orchestrator needs cross-step state (e.g. FLOW_REFS populated by snapshot for use by later steps), keep the **dispatch fn stateless** + have the **main loop** weave the events into the running state. flow_dispatch is one-step-in / one-event-out; the loop reads each event's payload (e.g. step.refs) and updates orchestrator-level globals. Generalizes to: replay's per-step diff accumulation (9-1-iv), memory cache write-back mid-flow (Phase 11), any future cross-step state. **Don't put orchestrator state in the dispatch fn.**
- **Privacy-canary-on-write-side pattern** (codified in 9-1-iii recorder; complements the read-side canary from Phase 7-1-iii inspect): when a verb WRITES caller-supplied data to disk (e.g. recorder writes user keystrokes to a flow file), apply sentinel-canary tests to prove sensitive bytes never reach the persisted artifact. Recorder fixture carries literal "PWD-CANARY-9-1-iii"; transformer output verified to NEVER contain that string. Generalizes to: any future "save user input to disk" verb (e.g. cookie export, form-data dump). **Different from read-side canaries** (Phase 7's HAR/console sanitization is on data the verb READS from the browser); both share the same enforcement contract — sentinel literal in fixture; bats grep MUST NOT find it in output.
- **Cross-platform-stat-trap pattern** (re-confirmed by 9-1-iii CI fixup): GNU `stat -f` does NOT fail — it dumps filesystem-status info instead. Always use `stat -c '%a' (GNU first) || stat -f '%Lp' (BSD fallback)` ordering for file-mode checks; reverse order yields garbage on Linux + breaks the test silently. Same precedent as common.sh::file_mode (HANDOFF prior entry). **Every new bats test using `stat` for file-mode MUST follow this ordering.**
- **gh-pr-checks-watch race-condition pattern** (proven 2× this session — PRs #70 + #82): `until ! grep -q IN_PROGRESS <<< "$(gh pr view ... statusCheckRollup ...)"; do sleep 25; done` exits prematurely when the PR's CI checks haven't materialized yet (empty rollup → grep returns 1 → `! grep` returns 0 → loop exits). Fix: require BOTH `[ -n "${s}" ]` AND `! grep -q IN_PROGRESS <<<"${s}"`. Single-line bash-pattern fix; saves 5+ min on every CI fixup-and-watch cycle.
- **Strip-timing-from-semantic-comparison pattern** (codified in 9-1-iv `flow_diff_steps`): when comparing two run outputs for "did this match", strip timing-sensitive fields (`duration_ms`, `started_at`, `finished_at`) BEFORE the comparison — they always vary between runs and aren't semantic differences. Without this, EVERY replay would diverge on EVERY step. Generalizes to any "did the output match" check across runs (Phase 11 cache-prediction-vs-actual checks, future flow vs flow comparison, future capture-vs-baseline diff). **Always pre-strip timing fields in any cross-run comparison.**
- **Forward-compat dependency landing pattern** (codified through Phase 7-1-v → Phase 9-1-v B1 contract; high leverage at phase closure): when Phase N implements a behavior whose contract is needed by Phase N+1, **land the contract dependency in Phase N as forward-compat code** even though Phase N+1 isn't writing yet. Phase 7-1-v added `meta.is_baseline:true` skip-rule to `capture_prune` despite no verb writing the field at the time; Phase 9-1-v's `baseline save` then "lit up" the existing skip-rule with zero migration cost. Decision rubric: **if Phase N's data-write side has a foreseeable consumer in Phase N+1, ship the read/skip side now and let it dormant; saves migrate-schema work + retroactive contract-rewrite risk later.** Same pattern shape as Phase 11 design's pre-shipped `cache-write-security.md` recipe — design contract first, implementation follows.

## Daemon state slots (shipped through 7-1-i — unchanged)

| Slot | Type | Phase | Notes |
|---|---|---|---|
| `refMap` | array | 5 part 1c-ii | eN ↔ uid translation, populated by snapshot |
| `routeRules` | array | 6 part 7-i / 7-ii | `{pattern, action}` for block/allow; `{pattern, action: "fulfill", status, body}` for fulfill. In-memory only — dies with daemon |
| `tabs` | array | 6 part 8-i | `{tab_id, url, title}` entries; replaced wholesale by `refreshTabs()` helper; spliced (no renumbering) by tab-close |
| `currentTab` | number \| null | 6 part 8-ii | tab_id pointer; updated by tab-switch; nulled by tab-close on match |

Phase 7 didn't touch daemon state in 1-i — capture pipeline is **verb-script-level**, not bridge-level. The `DaemonState` object refactor stays deferred (slots haven't started interacting yet).

## Stub coverage (mcp-server-stub.mjs, 19 tool handlers — unchanged)

| Tool | Purpose | Phase introduced |
|---|---|---|
| click | stateful click | 5 part 1c-ii |
| close_page | tab-close (best-effort name) | 6 part 8-iii |
| drag | pointer drag (2 uids) | 6 part 5 |
| evaluate_script | eval/extract/inspect-selector | 5 part 1c |
| fill | stateful fill | 5 part 1c-ii |
| hover | pointer hover | 6 part 3 |
| lighthouse_audit | audit verb | 5 part 1c |
| list_console_messages | inspect --capture-console | 5 part 1e-ii |
| list_network_requests | inspect --capture-network | 5 part 1e-ii |
| list_pages | tab-list (and auto-refresh in tab-switch / tab-close) | 6 part 8-i |
| navigate_page | open verb | 5 part 1c |
| press_key | press verb | 6 part 1 |
| route_url | route verb (fulfill passes status + body through) | 6 part 7-i / 7-ii |
| select_option | select verb | 6 part 2 |
| select_page | tab-switch (best-effort name) | 6 part 8-ii |
| take_screenshot | inspect --screenshot | 5 part 1e-ii |
| take_snapshot | snapshot verb | 5 part 1c |
| upload_file | upload verb | 6 part 6 |
| wait_for | wait verb | 6 part 4 |

Plus `initialize` + `notifications/initialized` (MCP handshake). 19 tool handlers total. Phase 7 doesn't add stub handlers — the capture write happens AFTER the adapter call, not inside an MCP tool.

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.46.0-phase-09-part-1-v-history-and-baseline` and main HEAD matches `ea7442e`.
3. **Recommended:** Phase 11 part 1-i — `lib/memory.sh` foundation (UNBLOCKED by Phase 9 closure). Per design doc `2026-05-08-phase-11-memory-design.md` §5. Pure read/write API; no verb integration yet (11-1-ii). Open-shape questions in next-session block above (URLPattern resolution mechanism / `_index.json` shape / lazy-creation precedent).
4. **Alternative (smaller):** Phase 10 — schema migration tooling. Per parent spec §13.6.
5. **Alternative (tiny):** ship `references/recipes/flow-record-secrets.md` recipe-doc (per 9-1-iii closure note). Pure-docs PR; doesn't block Phase 11.
6. **Alternative (small follow-up):** per-aspect file diff for `replay`/`history diff` (deferred from 9-1-iv).

Start with: read CHANGELOG since `v0.46.0-phase-09-part-1-v-history-and-baseline` to confirm no in-flight work, then propose Phase 11-1-i sub-part split (or alternative). User prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Reading priority for Phase 11-1-i:**
1. `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` — design contract. Decisions M1+U1+E1+H1 locked; storage shape frozen at v1.
2. `scripts/lib/capture.sh::capture_init_dir` — lazy-creation precedent for `~/.browser-skill/captures/` mode 0700. Memory dir mirrors this shape.
3. `scripts/lib/node/playwright-driver.mjs::createRequire` — node-helper dep-resolution precedent (try local require, fall back to npm-global). URLPattern resolution may use a tiny node helper.
4. `scripts/lib/flow.sh::flow_apply_vars` — 9-1-ii lib. Memory's `${refs.X}` resolution semantics could compose against this in 11-1-ii.
5. `references/recipes/privacy-canary.md` — applies to memory's interaction-record write side (cache must never carry credential bytes). Per design §6.
