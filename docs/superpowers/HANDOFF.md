Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-10 — Phase 8 part 1-iii shipped + jq-keyword fix)

main is at tag `v0.40.0-phase-08-part-1-iii-extract-stealth` (HEAD `29495d7`). **Phases 1-7 SHIPPED.** Phase 6 closed at 11/11 verbs; **Phase 7 closed at 5/5 sub-parts** — full capture pipeline (foundation + sanitize lib + inspect wire-up + `--unsanitized` audit + retention/prune). **Phase 8 1-i + 1-ii + 1-iii shipped** — obscura adapter shell + `tool_extract --scrape` (`obscura scrape`) + `tool_extract --stealth` (`obscura fetch --stealth --eval`). Path A still — `--scrape` / `--stealth` require `--tool obscura`; router promotion (Path B) lands in 8-2-i. **Phase 8 closure ~1 PR away.**

**`summary_json` jq-reserved-keyword cleanup also shipped (PR #73).** The pre-existing local-only failure on `tests/browser-select.bats:6` (tracked since Phase 6 as "jq-version-dependent") was traced to `summary_json` building filters where caller-supplied field names doubled as jq variable names — collisions on `label`, `def`, `or`, `and`, `not`, etc. Fix prefixes internal jq variables with `_v_`; output JSON shape unchanged.

### Phase 8 progress (PRs #68, #70, #72) — 3 of (3+) sub-parts shipped

| Sub-part | Scope | Status |
|---|---|---|
| 8-1-i | obscura adapter shell — `tool_metadata` + `tool_capabilities` (verbs: extract) + `tool_doctor_check` + 8 verb-dispatch fns (all 41-stubs). Path A "ship-without-promotion" (zero `router.sh` edits). Cheatsheet doc; `tests/stubs/obscura` `--version` mock. doctor enumerates 4 adapters now (was 3). | ✅ |
| 8-1-ii | `tool_extract --scrape <urls...>` real-mode — wraps `obscura scrape u1 u2 ... [--eval EXPR] [--concurrency N] --format json`. Per-URL streaming JSON event (direct jq emit; preserves `eval`'s `serde_json::Value` typing) + aggregate summary (`mode=scrape / total_urls / successful / failed`). Stub upgraded to fixture-based (`--version` short-circuits before STUB_LOG_FILE write); 3 fixtures. `--scrape` flag plumbing in `browser-extract.sh`. | ✅ |
| 8-1-iii | `tool_extract --stealth <url>` real-mode — wraps `obscura fetch <url> --stealth --eval EXPR`. Single URL; `--eval` required (without it `obscura fetch` dumps full HTML). One `extract_stealth` event with `{event, url, eval}` (eval always emitted as string — typed parsing deferred). `tool_extract` refactored to thin mode-dispatcher with `_tool_extract_scrape` + `_tool_extract_stealth` internal helpers. Modes mutually exclusive. New fixture; `--stealth` flag plumbing in `browser-extract.sh`. | ✅ |
| 8-2-i | Router promotion (Path B) — adds `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES`. Promotes obscura to default for `--scrape` / `--stealth`. **Closes Phase 8.** | 🔲 next |

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
- **4 of 4 adapter shells exist**; **obscura partial** — `tool_extract` now real-mode for **two modes** (`--scrape` + `--stealth`); remaining 7 verb-dispatch fns are 41-stubs by design (obscura is intentionally one-shot extract-only). doctor enumerates `adapters_ok:4`.
- **3 of 3 Tier-1 credential backends**.
- **770 tests pass / 0 fail / lint exit 0** locally (the formerly-quarantined `browser-select.bats:6` jq-`label`-keyword failure is now FIXED at the lib level via `summary_json`'s `_v_` prefix — PR #73).
- **70 PRs merged total** (24 in Phase 5, 13 in Phase 6 + 4 ancillary docs/CI + recipes catchup + Phase 7 parts 1-i/1-ii/1-iii/1-iv/1-v + Phase 11 design + skill model-routing + 5 HANDOFF refreshes + Phase 8 parts 1-i/1-ii/1-iii + summary_json jq-keyword fix; not counting this HANDOFF refresh).

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

## Next session: pick up at Phase 8 part 2-i (router promotion / Path B → CLOSES Phase 8)

Phase 8 1-i + 1-ii + 1-iii all shipped. **8-2-i closes Phase 8** — adds `rule_scrape_flag` + `rule_stealth_flag` to `scripts/lib/router.sh::ROUTING_RULES`. Promotes obscura to default when `--scrape` or `--stealth` is set; drops the "must pass `--tool obscura`" friction. Per adapter-extension-model spec §4.4 (Path B). Tiny PR (~30 LOC + ~3 bats).

| Adapter | Real-mode status |
|---|---|
| chrome-devtools-mcp | ✅ Full (8/8 verbs; daemon-resident bridge) |
| playwright-cli | ✅ Full |
| playwright-lib | ✅ Full |
| **obscura** | ⚠️ **Partial** — `tool_extract` real-mode for **both** `--scrape` (8-1-ii) and `--stealth` (8-1-iii). All other 7 verb-dispatch fns 41-stub by design (one-shot extract-only adapter). |

**Recommended next sub-part:**
- **8-2-i: router promotion (Path B)** — adds two precedence rules to `ROUTING_RULES`:
  - `rule_scrape_flag`: `--scrape` set → obscura
  - `rule_stealth_flag`: `--stealth` set → obscura
  Both rules placed BEFORE `rule_extract_default` (which currently routes extract to chrome-devtools-mcp). Bats: assert pick_tool routes correctly for each flag; assert capability filter still rejects mismatched verbs. Closes Phase 8.

**Alternative picks (small):**
- `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. ~50 lines + ~3 bats. Wraps existing `capture_prune` with `--keep N` / `--days D`. Verb count 34 → 35.
- Begin Phase 9 (flow runner) design doc — Phase 11 memory implementation queues AFTER Phase 9.

**Phase ordering recap:**
- Phase 8 — obscura adapter (3/4 sub-parts shipped; 8-2-i router promotion closes Phase 8)
- Phase 9 — flow runner (`flow record` / `flow run` / `replay` / `history`). Phase 11 memory design doc says Phase 11 implementation comes AFTER Phase 9.
- Phase 10 — schema migration tooling
- Phase 11 — memory (per-archetype selector/action cache; design doc shipped, implementation queued)

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

## Workflow expectations (proven across 70 PRs)

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
- **HANDOFF-refresh-as-separate-PR pattern** (proven 8 times now: PR #47, #50, #52, #54, #67, #69, #71, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh). **Combined-refresh exception** (this PR): when two substantive PRs land back-to-back without HANDOFF-impacting differences (e.g. 8-1-iii + a focused jq-fix), one combined refresh works.
- **New-adapter-CI-trap pattern** (codified in 8-1-i CI fixup): adding a 4th adapter without a stub binary breaks the **two existing tests** that assert `"all checks passed"` (doctor.bats:12 + install.bats:103). Reason: doctor's exit-status matrix returns `partial` (still exit 0) when ≥1 adapter is OK but ≥1 fails — the **output assertion** fails (warn line replaces "all checks passed") even though `assert_status 0` passes. Fix shape: ship `tests/stubs/<adapter>` mirroring `tests/stubs/playwright-cli`'s shape + wire `<ADAPTER>_BIN=${STUBS_DIR}/<adapter>` into both tests. **Future adapter PRs MUST include the stub + test wiring in the same PR** — CI failure on first push otherwise. Two precedents now (playwright-cli stub + obscura stub).
- **Streaming-events-via-direct-jq pattern** (codified in 8-1-ii): when an adapter's per-result events carry **arbitrary JSON values** (e.g. `eval` field is `serde_json::Value` upstream — can be string/number/array/null/object), `emit_event` falls short — its `key=value` autodetect only handles scalar types. Bypass `emit_event` for those streaming events and emit via direct `jq -c '...'` over the upstream payload (with `+ {event:"name"}` add and field projection). `emit_summary` stays the path for **summary** lines (fixed scalar fields, validation guards). Lint tier 3 only requires the adapter sources `output.sh`; not every line must go through emit helpers.
- **Stub-version-short-circuit-before-log pattern** (codified in 8-1-ii): when a fixture-based stub's binary doubles as a `--version` health-check responder (cf. tests/stubs/obscura), the `--version` branch MUST short-circuit and return BEFORE the STUB_LOG_FILE write. Otherwise, doctor probes during unrelated tests pollute argv-shape assertion logs and cause spurious matches in subsequent grep-based tests. Pattern is enforced by a dedicated bats case (`stub --version short-circuits before fixture lookup`).
- **Adapters-don't-source-common pattern** (codified in 8-1-iii): adapters MUST NOT call `common.sh` helpers (e.g. `now_ms`, `assert_safe_name`) directly. Production paths always have `common.sh` loaded BEFORE the adapter is sourced (verb script → common.sh → router.sh → adapter), but adapter unit tests source the adapter standalone. Calling `now_ms` from inside the adapter works in production but fails in tests with `command not found`. Pattern: **don't fabricate values that the upstream tool doesn't provide** (e.g. obscura `fetch` doesn't report `time_ms`, so the adapter omits it; the verb-script's `duration_ms` covers end-to-end timing). When adapters genuinely need a helper, hoist it to the adapter's own private `_<name>_<helper>` namespace OR have the verb-script pre-compute and pass via flag.
- **Decouple-jq-variable-names-from-JSON-field-names pattern** (codified in PR #73): `--arg <name> X` followed by `$<name>` triggers jq's tokenizer keyword collision when `<name>` matches a reserved word (`label`, `def`, `or`, `and`, `not`, `if`, `then`, `else`, `end`, `as`, `reduce`, `foreach`, `try`, `catch`, `import`, `include`, `module`, `true`, `false`, `null`, `break`). Even though `--arg label X` "should" bind a variable, jq parses `label` as the early-exit-syntax keyword instead. Fix: prefix internal jq variable names with `_v_` so the variable-name space is decoupled from caller-supplied JSON field names. **Same pattern applies anywhere bash builds jq filters dynamically from user-supplied identifiers.** Lint candidate: grep for `--arg <key> ... \\$<key>` patterns; flag if `<key>` matches the reserved set. Deferred until a third instance surfaces.

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
2. Confirm tag is `v0.40.0-phase-08-part-1-iii-extract-stealth` and main HEAD matches `29495d7`.
3. **Recommended:** Phase 8 part 2-i — router promotion (Path B). Adds `rule_scrape_flag` + `rule_stealth_flag` to `scripts/lib/router.sh::ROUTING_RULES`. Drops the `--tool obscura` friction. Closes Phase 8. Tiny PR (~30 LOC + ~3 bats).
4. **Alternative (small):** ship `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. Tiny PR; wraps existing `capture_prune` with `--keep N` / `--days D` flags.
5. **Alternative (next phase prep):** begin Phase 9 (flow runner) design doc — Phase 11 memory implementation queues AFTER Phase 9.

Start with: read CHANGELOG since `v0.40.0-phase-08-part-1-iii-extract-stealth` to confirm no in-flight work, then propose Phase 8 part 2-i sub-part split (or alternative). The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Reading priority for Phase 8-2-i:**
1. `scripts/lib/router.sh::ROUTING_RULES` — array of rule-function names; new rules append to it. Top-down precedence.
2. `scripts/lib/router.sh::rule_*` (existing rules) — pattern: a function that returns 0 if the rule fires for the (verb, flags) combination + emits `tool_name\twhy` on stdout. Rules like `rule_audit_or_perf` (line ~110) are the closest analog — single-flag check.
3. `tests/router.bats` — adapter-routing test patterns (positive + negative per rule). Add 2 cases per new rule (positive: flag set → routes to obscura; negative: flag unset → falls through).
4. `tests/routing-capability-sync.bats` — drift check; add `--scrape` and `--stealth` to the `for verb in ...` loop so the new rules are exercised. Or extend the test with new dedicated cases.
5. `references/obscura-cheatsheet.md` — "When the router picks this adapter" table; flip both `--scrape` and `--stealth` from "planned 8-2-i" to "yes (default)" once shipped.
