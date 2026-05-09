Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-10 — Phase 8 ✅ COMPLETE)

main is at tag `v0.41.0-phase-08-part-2-i-router-promotion` (HEAD `60d2009`). **Phases 1-8 SHIPPED.** Phase 6 closed at 11/11 verbs; Phase 7 closed at 5/5 sub-parts (full capture pipeline); **Phase 8 closed at 4/4 sub-parts** — obscura adapter (shell + `--scrape` + `--stealth` + router promotion). Adapter roster locked at 4 of 4 (chrome-devtools-mcp + playwright-cli + playwright-lib + obscura); routing precedence locked across all default verbs; `--scrape` / `--stealth` auto-route to obscura without `--tool` flag.

**`summary_json` jq-reserved-keyword cleanup also shipped (PR #73).** The pre-existing local-only failure on `tests/browser-select.bats:6` (tracked since Phase 6 as "jq-version-dependent") was traced to `summary_json` building filters where caller-supplied field names doubled as jq variable names — collisions on `label`, `def`, `or`, `and`, `not`, etc. Fix prefixes internal jq variables with `_v_`; output JSON shape unchanged.

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

- **34 user-facing verbs** (extract gained `--scrape` + `--stealth` modes in 8-1-ii / 8-1-iii — same verb count). Phase 6 11/11 closed.
- **2 lib helpers shipped in Phase 7**: `scripts/lib/capture.sh` (gained `capture_prune` + `sanitized` arg + cross-platform age parser), `scripts/lib/sanitize.sh` (gained `sanitize_inspect_reply` helper).
- **4 of 4 adapter shells exist**; **all 4 routed to as defaults** for at least one verb. obscura partial — `tool_extract` real-mode for two modes (`--scrape` + `--stealth`) + auto-routed by `rule_scrape_flag` / `rule_stealth_flag`; remaining 7 verb-dispatch fns are 41-stubs by design. doctor enumerates `adapters_ok:4`.
- **3 of 3 Tier-1 credential backends**.
- **780 tests pass / 0 fail / lint exit 0** locally.
- **72 PRs merged total** (24 in Phase 5, 13 in Phase 6 + 4 ancillary docs/CI + recipes catchup + Phase 7 parts 1-i/1-ii/1-iii/1-iv/1-v + Phase 11 design + skill model-routing + 5 HANDOFF refreshes + Phase 8 parts 1-i/1-ii/1-iii/2-i + summary_json jq-keyword fix; not counting this HANDOFF refresh).

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

## Next session: pick up at Phase 9 (flow runner) — design doc first

Phase 8 ✅ COMPLETE. The 4-adapter roster is locked; routing precedence is locked; `--scrape` / `--stealth` auto-route to obscura. Adapter inventory final state:

| Adapter | Real-mode status |
|---|---|
| chrome-devtools-mcp | ✅ Full (8/8 verbs; daemon-resident bridge) |
| playwright-cli | ✅ Full |
| playwright-lib | ✅ Full |
| **obscura** | ✅ Real-mode for the unique-lane verb (`tool_extract --scrape` + `tool_extract --stealth`); 7 other verb-dispatch fns are 41-stub by design (one-shot extract-only adapter) |

**Recommended next sub-part: Phase 9 design doc.** Per parent spec §12 (sequencing): Phase 9 = flow runner (`flow record` / `flow run` / `replay` / `history`). Phase 11 (memory) implementation queues AFTER Phase 9 per design-doc decision. Design doc first to lock decisions before code lands — same "design before code" cadence as Phase 11 design doc (`docs/superpowers/specs/2026-05-08-phase-11-memory-design.md`). Open questions to lock:

- **Storage shape** — `~/.browser-skill/flows/<name>.flow.yaml`? Or `.json`?
- **Recording mechanism** — bridge-daemon eventstream? bash-side pre/post hooks? Hybrid?
- **Replay semantics** — strict (exit on any divergence) vs lenient (best-effort with diff)? Both?
- **Capture composition** — does each step get its own capture dir, or does the whole flow share one?
- **Variables / templating** — Mustache-style `{{site}}` in YAML? Skipped in v1?

**Alternative picks (small):**
- `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. Tiny PR (~50 LOC + ~3 bats). Wraps existing `capture_prune` with `--keep N` / `--days D` flags. Verb count 34 → 35.
- Begin shape work for Phase 11 (memory) — but the sequencing-locked design doc says wait for Phase 9 to ship first.

**Phase ordering recap:**
- Phase 8 ✅ COMPLETE (4/4 sub-parts shipped — obscura adapter + router promotion)
- Phase 9 🔲 next — flow runner (`flow record` / `flow run` / `replay` / `history`). Phase 11 memory design doc says Phase 11 implementation comes AFTER Phase 9.
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

## Workflow expectations (proven across 72 PRs)

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
- **HANDOFF-refresh-as-separate-PR pattern** (proven 9 times now: PR #47, #50, #52, #54, #67, #69, #71, #74, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh). **Combined-refresh exception** (PR #74): when two substantive PRs land back-to-back without HANDOFF-impacting differences (e.g. 8-1-iii + a focused jq-fix), one combined refresh works.
- **New-adapter-CI-trap pattern** (codified in 8-1-i CI fixup): adding a 4th adapter without a stub binary breaks the **two existing tests** that assert `"all checks passed"` (doctor.bats:12 + install.bats:103). Reason: doctor's exit-status matrix returns `partial` (still exit 0) when ≥1 adapter is OK but ≥1 fails — the **output assertion** fails (warn line replaces "all checks passed") even though `assert_status 0` passes. Fix shape: ship `tests/stubs/<adapter>` mirroring `tests/stubs/playwright-cli`'s shape + wire `<ADAPTER>_BIN=${STUBS_DIR}/<adapter>` into both tests. **Future adapter PRs MUST include the stub + test wiring in the same PR** — CI failure on first push otherwise. Two precedents now (playwright-cli stub + obscura stub).
- **Streaming-events-via-direct-jq pattern** (codified in 8-1-ii): when an adapter's per-result events carry **arbitrary JSON values** (e.g. `eval` field is `serde_json::Value` upstream — can be string/number/array/null/object), `emit_event` falls short — its `key=value` autodetect only handles scalar types. Bypass `emit_event` for those streaming events and emit via direct `jq -c '...'` over the upstream payload (with `+ {event:"name"}` add and field projection). `emit_summary` stays the path for **summary** lines (fixed scalar fields, validation guards). Lint tier 3 only requires the adapter sources `output.sh`; not every line must go through emit helpers.
- **Stub-version-short-circuit-before-log pattern** (codified in 8-1-ii): when a fixture-based stub's binary doubles as a `--version` health-check responder (cf. tests/stubs/obscura), the `--version` branch MUST short-circuit and return BEFORE the STUB_LOG_FILE write. Otherwise, doctor probes during unrelated tests pollute argv-shape assertion logs and cause spurious matches in subsequent grep-based tests. Pattern is enforced by a dedicated bats case (`stub --version short-circuits before fixture lookup`).
- **Adapters-don't-source-common pattern** (codified in 8-1-iii): adapters MUST NOT call `common.sh` helpers (e.g. `now_ms`, `assert_safe_name`) directly. Production paths always have `common.sh` loaded BEFORE the adapter is sourced (verb script → common.sh → router.sh → adapter), but adapter unit tests source the adapter standalone. Calling `now_ms` from inside the adapter works in production but fails in tests with `command not found`. Pattern: **don't fabricate values that the upstream tool doesn't provide** (e.g. obscura `fetch` doesn't report `time_ms`, so the adapter omits it; the verb-script's `duration_ms` covers end-to-end timing). When adapters genuinely need a helper, hoist it to the adapter's own private `_<name>_<helper>` namespace OR have the verb-script pre-compute and pass via flag.
- **Decouple-jq-variable-names-from-JSON-field-names pattern** (codified in PR #73): `--arg <name> X` followed by `$<name>` triggers jq's tokenizer keyword collision when `<name>` matches a reserved word (`label`, `def`, `or`, `and`, `not`, `if`, `then`, `else`, `end`, `as`, `reduce`, `foreach`, `try`, `catch`, `import`, `include`, `module`, `true`, `false`, `null`, `break`). Even though `--arg label X` "should" bind a variable, jq parses `label` as the early-exit-syntax keyword instead. Fix: prefix internal jq variable names with `_v_` so the variable-name space is decoupled from caller-supplied JSON field names. **Same pattern applies anywhere bash builds jq filters dynamically from user-supplied identifiers.** Lint candidate: grep for `--arg <key> ... \\$<key>` patterns; flag if `<key>` matches the reserved set. Deferred until a third instance surfaces.
- **Path A → Path B adapter rollout pattern** (Phase 8 closure proof): Phase 8 split the obscura adapter rollout into Path A (`--tool obscura` only; zero `router.sh` edits) for 8-1-i / 8-1-ii / 8-1-iii, then Path B (router promotion adds default-routing) in 8-2-i. Each PR carried single-concern risk: Path A PRs reviewed adapter / verb backend / fixture-stub design without routing entanglement; Path B PR reviewed two precedence rules with full capability-filter test coverage. The pattern lives in `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` §4.4 and proved its value end-to-end across 4 PRs and 4 sub-parts of Phase 8. **Adopt for any future adapter (Phase 9+ if applicable).**
- **Capability-filter-as-safety-net pattern** (highlighted by 8-2-i): when a precedence rule fires for a verb the named tool doesn't support (e.g. `open --scrape` triggers `rule_scrape_flag` → obscura, but obscura doesn't declare `open`), the capability filter rejects + emits `warn: rule X picked TOOL but it doesn't support verb=Y; falling through` and the router walks to the next rule. **Routing-rule typos are caught at runtime, not in production traffic** — the cost is one extra `_tool_supports` jq call per fall-through. Codified in `tests/router.bats` (`open --scrape falls through to playwright-cli`). Future precedence rules should NOT defensively add their own verb checks; trust the capability filter.

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
2. Confirm tag is `v0.41.0-phase-08-part-2-i-router-promotion` and main HEAD matches `60d2009`.
3. **Recommended:** Begin Phase 9 (flow runner) **design doc**. Same pattern as Phase 11 design doc — lock decisions before code lands. Open questions enumerated in the "Next session" block above (storage shape, recording mechanism, replay semantics, capture composition, variables/templating).
4. **Alternative (small):** ship `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. Tiny PR (~50 LOC + ~3 bats). Verb count 34 → 35.
5. **Alternative (cleanup):** review parent spec Appendix A verbs vs current shipped roster — surface gaps for Phase 9+ planning.

Start with: read CHANGELOG since `v0.41.0-phase-08-part-2-i-router-promotion` to confirm no in-flight work, then propose Phase 9 design-doc structure (or alternative). The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Reading priority for Phase 9 design doc:**
1. `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §3 verbs 31-33 (`flow run / record`, `replay`, `history`, `baseline`) — parent-spec scope for Phase 9.
2. `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` — design-doc-first template; same shape applies.
3. `examples/*.flow.yaml` — five existing example YAMLs (morning-check, post-commit-verify, reproduce-bug-template, visual-regression, form-fill-template) — already define the v1 surface for what `flow run` consumes. Design must match (or explicitly extend) this YAML shape.
4. `scripts/lib/capture.sh` — capture pipeline (Phase 7) is the composition target. Design doc must decide: per-step capture or per-flow capture (or both).
5. `scripts/lib/tool/obscura.sh` (post-8-2-i) — the multi-mode dispatcher pattern from `tool_extract`. Flow runner is similar in spirit (one entry point, multiple sub-modes via flags).
