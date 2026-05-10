Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-10 — Phase 9 part 1-ii shipped)

main is at tag `v0.43.0-phase-09-part-1-ii-refs-and-assert` (HEAD `e7cdf0c`). **Phases 1-8 SHIPPED.** Phase 6 closed at 11/11 verbs; Phase 7 closed at 5/5 sub-parts (full capture pipeline); Phase 8 closed at 4/4 sub-parts (obscura adapter). **Phase 9 1-i + 1-ii shipped** — `flow run` foundation + `${refs.NAME}` resolution + new `assert` verb. Flows can now snapshot, fill via accessibility-tree refs, and assert text predicates end-to-end.

**Phase 9 design doc shipped earlier this session.** `docs/superpowers/specs/2026-05-10-phase-09-flow-runner-design.md` locks decisions F1-F8. Five-sub-part split (9-1-i through 9-1-v); storage shape frozen.

**`summary_json` jq-reserved-keyword cleanup also shipped (PR #73).** The pre-existing local-only failure on `tests/browser-select.bats:6` (tracked since Phase 6 as "jq-version-dependent") was traced to `summary_json` building filters where caller-supplied field names doubled as jq variable names — collisions on `label`, `def`, `or`, `and`, `not`, etc. Fix prefixes internal jq variables with `_v_`; output JSON shape unchanged.

### Phase 9 progress (PRs #77 design, #78 9-1-i, #80 9-1-ii) — 2 of 5 sub-parts shipped

| Sub-part | Scope | Status |
|---|---|---|
| 9 design | Phase 9 design doc (`2026-05-10-phase-09-flow-runner-design.md`). Locks F1-F8. | ✅ |
| 9-1-i | `flow run <file>` foundation. `scripts/browser-flow.sh` + `scripts/lib/flow.sh` (3-fn API). Bash-side YAML parser (no node-helper). `_kind`-tagged JSON (subshell-survivable). `${var}` substitution. Whole-flow capture composition. `--var` override; `--dry-run` plan path. | ✅ |
| 9-1-ii | `${refs.NAME}` resolution + `assert` step. flow_apply_vars gains refs-mode (strict/skip); flow_dispatch extracts refs[] from snapshot stdout into step.refs; main loop harvests step.refs into FLOW_REFS (latest-wins). New `scripts/browser-assert.sh` — composition over adapter ABI (shells to extract; bash-compares). Locked decisions R1-R4 + A1. | ✅ |
| 9-1-iii | `flow record` — wrap `playwright codegen`; transformer JS → YAML; password canary on recorder write side. | 🔲 next |
| 9-1-iv | `replay <id>` — re-execute capture's steps; structured diff (status / output / per-aspect file). New `--strict` flag. | 🔲 |
| 9-1-v | `history list/show/diff/clear` + `baseline save/list/remove`. **Closes Phase 9.** Folds in HANDOFF's "browser-clean.sh" follow-up as `history clear`. | 🔲 |

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

- **36 user-facing verbs** (Phase 9 1-ii adds `assert` — second new parent row in Phase 9).
- **3 lib helpers shipped post-Phase-7**: `scripts/lib/capture.sh`, `scripts/lib/sanitize.sh`, `scripts/lib/flow.sh` (gained refs-mode arg + step.refs extraction in 9-1-ii).
- **4 of 4 adapter shells exist**; all 4 routed to as defaults for at least one verb. obscura: `tool_extract` real-mode for `--scrape` + `--stealth`; remaining 7 verb-dispatch fns 41-stub by design. doctor enumerates `adapters_ok:4`.
- **3 of 3 Tier-1 credential backends**.
- **802 tests pass / 0 fail / lint exit 0** locally.
- **77 PRs merged total** (Phase 7 parts 1-i/1-ii/1-iii/1-iv/1-v + Phase 11 design + skill model-routing + 6 HANDOFF refreshes + Phase 8 parts 1-i/1-ii/1-iii/2-i + summary_json jq-keyword fix + Phase 9 design + Phase 9 parts 1-i/1-ii; not counting this HANDOFF refresh).

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

## Next session: pick up at Phase 9 part 1-iii (`flow record` — codegen wrapper)

Phase 9 1-i + 1-ii shipped. Flows now snapshot, fill via accessibility-tree refs, and assert text predicates end-to-end. **9-1-iii adds the recorder** — turns headed-session interactions into `.flow.yaml` files automatically.

**Recommended next sub-part:**
- **9-1-iii: `flow record`** — wraps `playwright codegen <site-url>`. User clicks/types in the popped headed Chromium; on close, transformer converts codegen's JS output into our flow YAML shape. **Privacy canary on recorder write side**: passwords (`input[type=password]`) detected and replaced with `${secrets.password}` placeholder before persisting. Per design doc §3 F6 + plan recipe `references/recipes/privacy-canary.md`.

**Open shape questions for 9-1-iii (decide during plan-doc):**
- Codegen JS → YAML transformer scope: hand-roll regex-based mapper for the 5-6 most-common JS patterns (`page.goto`, `getByRole().click()`, `getByRole().fill()`, etc.) OR a more-robust AST parse via node? Lean hand-roll regex for v1 (simpler; no node dep on the recorder side either).
- Where does the recorder write? `${BROWSER_SKILL_HOME}/flows/<name>.flow.yaml` (the flows/ dir from the design doc storage shape) OR `--out FILE` only (no default location)? Lean both: default to `--out` required; suggest `flows/` in docs.
- Password detection scope: strict `input[type=password]` only OR also detect by name pattern (`name="password"` etc.)? Lean strict; document the bypass.
- Recorder rejects `--tool obscura`? Per design §12 open Q (6) — codegen targets Playwright; obscura's stateless one-shot model doesn't have an interactive recording surface.

**Alternative picks:**
- Skip to 9-1-iv (`replay <id>`) — possible since replay re-executes captured steps verbatim (no recording needed). 9-1-iii could ship as a follow-up.
- Skip to 9-1-v (`history` + `baseline`) — read-side ops; doesn't depend on 9-1-iii / 9-1-iv. Could ship in parallel.

**Phase ordering recap:**
- Phase 8 ✅ COMPLETE (4/4 sub-parts shipped — obscura adapter + router promotion)
- Phase 9 🔲 design doc + 1-i + 1-ii shipped (2 of 5 sub-parts). 9-1-iii / 9-1-iv / 9-1-v remain.
- Phase 10 🔲 — schema migration tooling
- Phase 11 🔲 — memory (per-archetype selector/action cache; design doc shipped, implementation queued AFTER Phase 9)

## Phase 11 — memory (design doc shipped; implementation queued AFTER Phase 9)

User confirmed (2026-05-08) that no memory-like feature is currently shipped. Sites profile holds login selectors (manually entered); daemon `refMap` is in-memory only; Phase 9's planned `flow record` is manual recording, not auto-learned. The auto-learned per-archetype selector/action cache (the "get smarter the more we use it" pattern from Skyvern/Stagehand/Agent-E) is a **Phase 11 candidate**.

Design doc: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md`. Decisions locked: M1+U1+E1+H1.

| Sub-part | Scope | Status |
|---|---|---|
| 11-1-i | `lib/memory.sh` foundation (read/write archetype JSON; URL→archetype via URLPattern API) | 🔲 (after Phase 9) |
| 11-1-ii | `browser-do --intent "..."` verb — cache lookup → hit-direct OR miss-fallback to snapshot+reasoning + write-back | 🔲 |
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

## Workflow expectations (proven across 77 PRs)

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
- **HANDOFF-refresh-as-separate-PR pattern** (proven 11 times now: PR #47, #50, #52, #54, #67, #69, #71, #74, #76, #79, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh). **Combined-refresh exception** (PR #74): when two substantive PRs land back-to-back without HANDOFF-impacting differences (e.g. 8-1-iii + a focused jq-fix), one combined refresh works.
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
2. Confirm tag is `v0.43.0-phase-09-part-1-ii-refs-and-assert` and main HEAD matches `e7cdf0c`.
3. **Recommended:** Phase 9 part 1-iii — `flow record` (codegen wrapper). Per the open-shape questions in the "Next session" block above (transformer scope, output location, password detection scope, obscura rejection).
4. **Alternative (skip-ahead):** Phase 9 part 1-iv (`replay <id>`) — possible since replay re-executes captured steps verbatim.
5. **Alternative (parallelizable):** Phase 9 part 1-v (`history` + `baseline`) — read-side ops; doesn't depend on 9-1-iii / 9-1-iv.

Start with: read CHANGELOG since `v0.43.0-phase-09-part-1-ii-refs-and-assert` to confirm no in-flight work, then propose 9-1-iii sub-part split (or alternative). User prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Reading priority for Phase 9-1-iii:**
1. `docs/superpowers/specs/2026-05-10-phase-09-flow-runner-design.md` §3 F6 — the recorder contract. Codegen JS → YAML mapping table.
2. [Playwright codegen docs](https://playwright.dev/docs/codegen) — what does `playwright codegen <url>` actually output? JavaScript / TypeScript / Python options. v1 likely targets JS (smaller transformer scope).
3. `scripts/browser-flow.sh` — the existing flow runner that the recorded YAMLs will be consumed by. Recorded files MUST round-trip with `flow run`.
4. `scripts/browser-login.sh` — existing precedent for headed-browser-spawning verb. The recorder will spawn `playwright codegen` (or similar) and wait for user to close the headed window.
5. `references/recipes/privacy-canary.md` — recorder write-side canary contract. Passwords must be detected and replaced with `${secrets.password}` before persisting.
