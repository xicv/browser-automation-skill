Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-08 — Phase 7 part 1-iii shipped)

main is at tag `v0.35.0-phase-07-part-1-iii-inspect-capture-wireup`. **Phases 1-6 SHIPPED** (Phase 6 closed at 11/11 verbs). **Phase 7 is 3/5 sub-parts done** — capture foundation + sanitize lib + inspect wire-up. `--unsanitized` audit flag + retention/prune remain.

### Phase 7 progress (PRs #56, #60, #62)

| Sub-part | Scope | Status |
|---|---|---|
| 7-1-i | `lib/capture.sh` foundation (3-fn API: capture_init_dir / capture_start / capture_finish) + opt-in `--capture` on snapshot | ✅ |
| 7-1-ii | `lib/sanitize.sh` — pure jq-function library (sanitize_har + sanitize_console). 15 bats; 5 fixture JSONs; no verb integration | ✅ |
| 7-1-iii | `inspect --capture` wire-up — first composition test for capture + sanitize. Persists console.json + network.har sanitized; defense in depth (stdout sanitized too); 6-canary privacy regression suite. | ✅ |
| 7-1-iv | `--unsanitized` typed-phrase ack (`I want raw network/console data including auth tokens`) + `meta.sanitized: false` audit flag + `doctor` counter | 🔲 |
| 7-1-v | `capture_prune` (count>500 / age>14d) + retention thresholds in `~/.browser-skill/config.json` + `_index.json` recompute on prune | 🔲 |

### Counters

- **34 user-facing verbs** (snapshot + inspect both extended with `--capture` opt-in flag — same verb count). Phase 6 11/11 closed.
- **2 lib helpers added in Phase 7**: `scripts/lib/capture.sh`, `scripts/lib/sanitize.sh`. Sanitize lib gained `sanitize_inspect_reply` helper in 7-1-iii.
- **3 of 4 adapters real-mode**: playwright-cli, playwright-lib, chrome-devtools-mcp. obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**.
- **~713 tests pass / 0 fail / lint exit 0** locally (CI-authoritative; local hangs on real-playwright e2e files when playwright globally installed; `tests/browser-select.bats:6` fails locally on newer jq versions where `label` is reserved — pre-existing, tracked as follow-up).
- **60 PRs merged total** (24 in Phase 5, 13 in Phase 6 + 4 ancillary docs/CI + recipes catchup + Phase 7 parts 1-i/1-ii/1-iii + Phase 11 design + skill model-routing; not counting future HANDOFF refresh).

## Capture pipeline shape (shipped through 7-1-i)

```
${BROWSER_SKILL_HOME}/captures/                  # mode 0700 (lazy-created)
├── _index.json                                  # mode 0600
│     {schema_version: 1, next_id: N, count: M, latest: "NNN", total_bytes: B}
└── NNN/                                         # mode 0700, zero-padded 3-digit
    ├── meta.json                                # mode 0600
    │     {capture_id, verb, schema_version: 1, started_at, finished_at,
    │      status: "ok"|"error"|"in_progress", total_bytes, files: [{name, bytes}]}
    └── snapshot.json                            # mode 0600 (per-aspect file)
```

Per-aspect files arrive incrementally:
- 7-1-i: `snapshot.json` (snapshot verb)
- 7-1-iii: `console.json`, `network.har` (inspect verb, **sanitized by default**)
- Future: `screenshot.png`, `trace.zip`, `lighthouse.json` (audit verb)

`meta.json` and `_index.json` schemas are **frozen at v1** for Phase 7. Field additions are non-breaking; renames/removals bump `schema_version`.

## Next session: pick up at Phase 7 part 1-iv (`--unsanitized` opt-out)

Recommended start: **`--unsanitized` typed-phrase ack (Phase 7 part 1-iv)**. The capture+sanitize pipeline now ships sanitized-by-default. 7-1-iv adds the typed-phrase escape-hatch for users who legitimately need raw network/console data (e.g. debugging an auth flow that the sanitizer is hiding).

Surface:

```bash
# Triggers a typed-phrase confirmation. Cannot be passed via flag value;
# user must echo the exact phrase via stdin or interactive prompt.
bash scripts/browser-inspect.sh --capture-console --capture-network --capture --unsanitized
# → asks for: "I want raw network/console data including auth tokens"
# → on confirm: captures/NNN/{console.json, network.har} written RAW
#                meta.json::sanitized = false (audit field)
# → on mismatch: EXIT_USAGE_ERROR; capture aborted
```

Scope:
- `scripts/browser-inspect.sh` — accept `--unsanitized`; require typed-phrase confirmation (mirror `creds-show --reveal` precedent for typed-phrase pattern).
- When `--unsanitized` confirmed: skip `sanitize_inspect_reply` for that capture; persist RAW console.json + network.har; write `meta.json::sanitized = false` (new field). Stdout still emits raw too (consistent with disk).
- `scripts/browser-doctor.sh` — count captures with `sanitized:false` in `meta.json`; surface as warning in doctor output ("N captures with sanitization disabled — review captures/NNN/").
- `scripts/lib/capture.sh::capture_finish` — accept optional `sanitized` flag to write into meta.json. Default true; overrideable.
- Bats: ~6-8 cases — typed-phrase happy + mismatch → error + canary survives in raw mode + meta.sanitized:false written + doctor counter increments.
- **Privacy guard:** `--unsanitized` MUST require interactive typed-phrase OR explicit env var `BROWSER_SKILL_UNSANITIZED_ACK=1` (for scripted use). Never bypassed by `-y` or `--yes` shortcuts. Mirrors the strict typed-phrase pattern from creds-show.

Estimated size: medium. Comparable to 7-1-iii. ~6-8 bats + verb script edit + capture-finish optional flag + doctor counter + typed-phrase plumbing.

After 7-1-iv: 7-1-v (retention/prune + `_index.json` recompute + config.json thresholds), then Phase 8 (obscura adapter).

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

## Workflow expectations (proven across 56 PRs)

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
- **HANDOFF-refresh-as-separate-PR pattern** (proven 5 times now: PR #47, #50, #52, #54, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries. Pure-docs-PR is the one exception (recipe-doc PR #55 folded HANDOFF refresh).

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
2. Confirm tag is `v0.34.0-phase-07-part-1-ii-sanitize-lib` and main HEAD matches.
3. **Recommended:** Phase 7 part 1-iv — `--unsanitized` typed-phrase opt-out + `meta.sanitized:false` audit flag + doctor counter. Branch `feature/phase-07-part-1-iv-unsanitized-flag`. Plan-doc + RED bats + GREEN inspect-script edit + capture-finish flag extension + doctor counter + lint + tag + PR + CI + squash-merge + reset main.
4. Read parent spec §8.5 (Audit & observability) — "Did a verb run --unsanitized? meta.json carries `sanitized:false`; doctor counts these" defines the exact contract.
5. Read existing typed-phrase precedent in `scripts/browser-creds-show.sh::--reveal` for the `--unsanitized` plumbing pattern. Mirror the strict-confirmation mechanic; never bypassable by `-y` / `--yes`.
6. **Privacy guard test**: bats case that asserts `--unsanitized` WITHOUT typed-phrase confirmation → `EXIT_USAGE_ERROR`. Plus a positive case where the typed phrase is supplied → raw data passes through; meta.json carries `sanitized: false`.

Start with: read CHANGELOG since `v0.35.0-phase-07-part-1-iii-inspect-capture-wireup` to confirm no in-flight work, then propose 7-1-iv sub-part scope (or alternative if user prefers). The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.
