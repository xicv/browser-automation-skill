Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-09 — Phase 8 OPENED)

main is at tag `v0.38.0-phase-08-part-1-i-obscura-adapter-shell` (HEAD `6722290`). **Phases 1-7 SHIPPED.** Phase 6 closed at 11/11 verbs; **Phase 7 closed at 5/5 sub-parts** — full capture pipeline (foundation + sanitize lib + inspect wire-up + `--unsanitized` audit + retention/prune). **Phase 8 1-i shipped** — obscura adapter shell (Path A "ship-without-promotion"; reachable via `--tool obscura` only; verb-dispatch fns are 41-stubs awaiting 8-1-ii / 8-1-iii).

### Phase 8 progress (PR #68) — 1 of (3+) sub-parts shipped

| Sub-part | Scope | Status |
|---|---|---|
| 8-1-i | obscura adapter shell — `tool_metadata` + `tool_capabilities` (verbs: extract) + `tool_doctor_check` + 8 verb-dispatch fns (all 41-stubs). Path A "ship-without-promotion" (zero `router.sh` edits). Cheatsheet doc; tests/stubs/obscura `--version` mock. doctor enumerates 4 adapters now (was 3). | ✅ |
| 8-1-ii | `tool_extract --scrape <urls...>` real-mode — wraps `obscura scrape u1 u2 ... --eval EXPR --format json`. Per-URL streaming JSON + summary. Privacy canary in bats. tests/fixtures/obscura/ + fixture-based stub. | 🔲 next |
| 8-1-iii | `tool_extract --stealth` real-mode — wraps `obscura fetch <url> --stealth --eval`. `--stealth` flag plumbing in `browser-extract.sh`. | 🔲 |
| 8-2-i | Router promotion (Path B) — adds `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES`. Promotes obscura to default for `--scrape` / `--stealth`. | 🔲 |

### Phase 7 progress (PRs #56, #60, #62, #64, #66) — ✅ COMPLETE

| Sub-part | Scope | Status |
|---|---|---|
| 7-1-i | `lib/capture.sh` foundation (3-fn API: capture_init_dir / capture_start / capture_finish) + opt-in `--capture` on snapshot | ✅ |
| 7-1-ii | `lib/sanitize.sh` — pure jq-function library (sanitize_har + sanitize_console). 15 bats; 5 fixture JSONs; no verb integration | ✅ |
| 7-1-iii | `inspect --capture` wire-up — first composition test for capture + sanitize. Persists console.json + network.har sanitized; defense in depth (stdout sanitized too); 6-canary privacy regression suite. | ✅ |
| 7-1-iv | `--unsanitized` typed-phrase ack (`I want raw network/console data including auth tokens`) + `meta.sanitized: false` audit flag + `doctor` counter | ✅ |
| 7-1-v | `capture_prune` (count>500 / age>14d) + retention thresholds in `~/.browser-skill/config.json` + `_index.json` recompute on prune. Baseline-protection forward-compat (Phase 8). Cross-platform age parsing. | ✅ |

### Counters

- **34 user-facing verbs** (Phase 8 1-i adds no verbs — adapter shell only). Phase 6 11/11 closed.
- **2 lib helpers shipped in Phase 7**: `scripts/lib/capture.sh` (gained `capture_prune` + `sanitized` arg + cross-platform age parser), `scripts/lib/sanitize.sh` (gained `sanitize_inspect_reply` helper).
- **4 of 4 adapter shells exist**: playwright-cli ✅ + playwright-lib ✅ + chrome-devtools-mcp ✅ + **obscura ⚠️ shell-only** (verb backend in 8-1-ii / 8-1-iii). doctor enumerates `adapters_ok:4` now.
- **3 of 3 Tier-1 credential backends**.
- **~749 tests pass / 1 pre-existing fail / lint exit 0** locally (CI-authoritative; `tests/browser-select.bats:6` fails locally on newer jq versions where `label` is reserved — pre-existing since Phase 6, tracked as follow-up).
- **65 PRs merged total** (24 in Phase 5, 13 in Phase 6 + 4 ancillary docs/CI + recipes catchup + Phase 7 parts 1-i/1-ii/1-iii/1-iv/1-v + Phase 11 design + skill model-routing + 4 HANDOFF refreshes + Phase 8 part 1-i; not counting this HANDOFF refresh).

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

## Next session: pick up at Phase 8 part 1-ii (`tool_extract --scrape`)

Phase 8 1-i shipped the adapter shell. Per parent spec §12 (sequencing) + §3 (4-adapter routing), **8-1-ii ships the first real verb backend** — `tool_extract --scrape <urls...>` wrapping `obscura scrape`. Adapter inventory after 8-1-i:

| Adapter | Real-mode status |
|---|---|
| chrome-devtools-mcp | ✅ Full (8/8 verbs; daemon-resident bridge) |
| playwright-cli | ✅ Full |
| playwright-lib | ✅ Full |
| **obscura** | ⚠️ **Shell only** — adapter shell + identity fns + cheatsheet + `--version`-only stub. All 8 verb-dispatch fns return 41. Verb backends in 8-1-ii / 8-1-iii. |

**Phase 8 research locked.** Obscura ships in two upstream modes:
- **Mode 1 — stateless one-shot:** `obscura fetch <url>` (single page) + `obscura scrape <urls...>` (parallel). **This adapter targets mode 1 exclusively** (the unique lane vs incumbents).
- **Mode 2 — CDP server:** `obscura serve --port 9222`. **Routed via future `playwright-lib --cdp-endpoint` flag, NOT this adapter.** Avoids two-CDP-transport-adapter mental-model split.

**Recommended next sub-part split:**
- **8-1-ii: `tool_extract --scrape` real-mode** — wraps `obscura scrape u1 u2 ... --eval EXPR --format json`. Per-URL streaming JSON line + summary. Privacy canary in bats. Adds `tests/fixtures/obscura/` + upgrades `tests/stubs/obscura` from `--version`-only to fixture-based (mirror `tests/stubs/playwright-cli` pattern). Also adds `--scrape` flag plumbing in `browser-extract.sh` so `--tool obscura --scrape` reaches the adapter with the URL list.
- **8-1-iii: `tool_extract --stealth` real-mode** — wraps `obscura fetch <url> --stealth --eval`. `--stealth` flag plumbing in `browser-extract.sh`.
- **8-2-i: router promotion (Path B)** — adds `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES`. Promotes obscura to default for `--scrape` / `--stealth`. Tiny PR.

**Smallest reviewable PR with user-visible value:** 8-1-ii. First real verb backend; ships `--tool obscura --scrape` end-to-end.

**Alternative pick** if user wants something even smaller: ship the optional `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. Tiny PR (~50 lines + ~3 bats). Wraps existing `capture_prune` with manual-trigger flags (`--keep N`, `--days D`). Verb count 34 → 35.

**Phase ordering recap:**
- Phase 8 — obscura adapter (1/3+ sub-parts shipped; 8-1-ii / 8-1-iii / 8-2-i remain)
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

## Workflow expectations (proven across 65 PRs)

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
- **HANDOFF-refresh-as-separate-PR pattern** (proven 6 times now: PR #47, #50, #52, #54, #67, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh).
- **New-adapter-CI-trap pattern** (codified in 8-1-i CI fixup): adding a 4th adapter without a stub binary breaks the **two existing tests** that assert `"all checks passed"` (doctor.bats:12 + install.bats:103). Reason: doctor's exit-status matrix returns `partial` (still exit 0) when ≥1 adapter is OK but ≥1 fails — the **output assertion** fails (warn line replaces "all checks passed") even though `assert_status 0` passes. Fix shape: ship `tests/stubs/<adapter>` mirroring `tests/stubs/playwright-cli`'s shape + wire `<ADAPTER>_BIN=${STUBS_DIR}/<adapter>` into both tests. **Future adapter PRs MUST include the stub + test wiring in the same PR** — CI failure on first push otherwise. Two precedents now (playwright-cli stub + obscura stub).

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
2. Confirm tag is `v0.38.0-phase-08-part-1-i-obscura-adapter-shell` and main HEAD matches `6722290`.
3. **Recommended:** Phase 8 part 1-ii — `tool_extract --scrape` real-mode backend. Branch + plan-doc once a fixture-shape decision lands (single-URL `obscura fetch --eval` JSON shape vs multi-URL `obscura scrape --format json` shape).
4. **Alternative (small):** ship `browser-clean.sh` force-prune verb (parent spec §3 verb #29) as a Phase 7 follow-up. Tiny PR; wraps existing `capture_prune` with `--keep N` / `--days D` flags.
5. **Alternative (cleanup):** address the pre-existing `tests/browser-select.bats:6` jq-label-keyword failure that's been local-only since Phase 6. Not blocking; small impact; satisfying to clear before continuing Phase 8.

Start with: read CHANGELOG since `v0.38.0-phase-08-part-1-i-obscura-adapter-shell` to confirm no in-flight work, then propose Phase 8 part 1-ii sub-part split (or alternative). The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Reading priority for Phase 8-1-ii:**
1. `scripts/lib/tool/obscura.sh` — adapter shell shipped in 8-1-i (the file you're filling in)
2. `references/obscura-cheatsheet.md` — modes / capabilities / limitations
3. `scripts/lib/tool/playwright-cli.sh` — closest CLI-shell adapter analog for the verb-dispatch shape
4. `tests/stubs/playwright-cli` + `tests/fixtures/playwright-cli/` — the fixture-based stub pattern to mirror at `tests/stubs/obscura` (currently `--version`-only)
5. `scripts/browser-extract.sh` — where `--scrape <urls...>` flag plumbing lands in 8-1-ii
