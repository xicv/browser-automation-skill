# Changelog

Every entry has a tag in `[brackets]`:
- `[feat]` user-visible new behavior
- `[fix]` user-visible bug fix
- `[security]` anything touching credentials, sessions, captures, hooks
- `[adapter]` added/updated tool adapter
- `[schema]` on-disk schema migration
- `[breaking]` requires action from existing users
- `[upstream]` updated pinned upstream tool version
- `[internal]` lint, tests, CI — no user-visible change
- `[docs]` README / SKILL.md / references / examples

## [Unreleased]

### Stage 4 part 1 — agent-workflow recipes (4 tutorial-shaped walkthroughs)

All HANDOFF-locked PR picks shipped (PRs #113-#129). Remaining work was Stage 4 adoption: recipes / demo / cookbook. This PR ships **agent-workflow recipes** — distinct from existing pattern recipes (codified discipline). Workflow recipes show sequenced commands + expected output for actual user-facing tasks.

- [docs] **`references/recipes/agent-workflows/`** new subdirectory + README index. 4 tutorial recipes:
  - **`login-then-scrape.md`** — first end-to-end task: register site → store creds (stdin-only) → interactive login → bulk scrape via obscura adapter. The "hello world" of the skill.
  - **`incremental-pattern-discovery.md`** — passive observation → propose → cache-hit loop end-to-end. Demonstrates PR #115 (events.jsonl) + PR #125 (recent_urls.jsonl) + PR #121 (--auto-record) + PR #119 (self_heal_history) together.
  - **`flow-record-and-replay.md`** — `flow record` (wraps `playwright codegen`) → run with `--capture` → `baseline save` → re-run later → `history diff`. Codifies the Phase 9 strip-timing-from-comparison pattern.
  - **`cache-driven-bulk-operation.md`** — 50+ actions at zero LLM tokens. The ROI-proof workflow: numerical breakdown of cache hit rate, wall-clock, token cost.
- [docs] **`SKILL.md`** gains an "Agent-workflow recipes" section with links to all 4 + a pointer to the pattern-recipe directory.
- [internal] 3 new bats in `tests/docs-coverage.bats`: (a) README index exists + links to all 4; (b) all 4 recipes exist + have **Goal:** + **Outcome:** statements; (c) recipes reference real verb names (drift guard — if a verb is renamed, the recipes must update).

**Design decision: clean-state assumption.** Recipes assume a fresh `~/.browser-skill/` (or skip step 0 if already installed). Each walks the reader through the full setup. Open question from HANDOFF resolved in favor of reproducibility over brevity.

**Sub-scope (this PR):**
- **Pure docs PR + minimal bats.** No production code change.
- **No demo video / asciinema cast.** Out of PR-mode; deferred to non-code stage-4 work.
- **No blog post / dev.to article.** Out of PR-mode.
- **No "agent-workflow" recipes for niche use cases** (e.g. multi-tab orchestration, audit pipelines). 4 representative cases cover the toolchain's main surfaces; more can land case-by-case.
- **No quickstart-to-recipe linking from README.md.** Keeping README's Quickstart standalone for now; the SKILL.md section is the entry point.

User-facing verb count unchanged (42). Total recipes: 7 pattern + 4 workflow = 11.

### Pick B — Daemon e2e for `playwright-lib --selector` (closes PR #105's daemon-runtime coverage gap)

PR #105 (Sep 2026) shipped `playwright-lib --selector` driver plumbing — IPC handler branches in `scripts/lib/node/playwright-driver.mjs` that route `msg.selector` through `page.locator(selector).first()` instead of the `refMap` lookup. Parse-layer bats covered argv plumbing thoroughly; the **daemon-runtime selector branches stayed untested** across 22 PRs. Pick B closes that gap with 2 e2e cases against a real Playwright daemon.

- [internal] **`tests/playwright-lib_stateful_e2e.bats` gains 2 cases:**
  - `click --selector h1`: end-to-end daemon round-trip — start → open → click(selector=h1) → assert `event:"click", status:"ok"` AND `.ref == null` (proves selector branch took, not ref branch).
  - `fill --selector --secret-stdin`: secret-scrub regression for the selector branch (parallel to the existing ref-branch test). Even though the fill fails (no matching `<input>` on example.com), the secret literal MUST NEVER appear in stdout/stderr.
- [internal] **Tests gated behind real Playwright install** via `setup_file()` (existing pattern — `if ! command -v playwright; then skip; fi`). CI without Playwright skips these cases; local dev with Playwright installed runs them.

**Sub-scope (this PR):**
- **No production code change.** Pure test addition. PR #105's driver code is unchanged; bats simply exercise the previously-uncovered runtime branches.
- **No `fill --selector` against missing-input no-match.** Initial test attempt tried `fill --selector 'input[name="missing"]'` expecting a quick error event; Playwright's locator semantics wait 30s (default locator timeout) on the element to appear before timing out. This is **not selector-specific** — `--ref` against a removed ref has the same behavior. Out of Pick B scope. (Real bug? Arguably — `playwright-driver.mjs` could pass a short timeout to `locator.fill()`. Deferred to a separate PR if user demand surfaces.)
- **No `hover --selector` / `select --selector` e2e.** PR #101 (hover) + PR #103 (select) shipped selector-mode only via `chrome-devtools-mcp`; `playwright-lib` doesn't expose those verbs at all. Out of scope.

**Result: PR #105's runtime branches are now CI-gated.** The selector branch can't silently regress without breaking the e2e suite (when Playwright is installed).

### Pick A2 — Slug heuristic in `url-pattern-cluster.mjs` — closes Phase 11 v2 hardening backlog

`url-pattern-cluster.mjs` (PR #97, 11-2-ii) previously clustered only numeric (`/items/123`) and UUID (`/items/abc-...`) segments. Slug paths (`/posts/my-post-title`, `/users/alice-cooper`) stayed as distinct unique strings → never reached the cluster threshold → never proposed. Pick A2 adds entropy-based slug detection.

- [feat] **`scripts/lib/node/url-pattern-cluster.mjs` gains a slug detection branch.** New regex `SLUG_RE = /^[a-z0-9_]+(-[a-z0-9_]+)+$/i` + length floor `MIN_SLUG_LEN = 5`. Fires after numeric/UUID in the `if`-chain order. Qualifying segments template to `:slug`; the cluster mechanism + threshold filter then propose the canonical pattern row.
- [feat] **Heuristic locked at the simplest reviewable shape:** segment must (a) contain ≥1 hyphen, (b) have ≥1 alphanumeric char on each side of every hyphen, (c) total length ≥5. Rejects short codes (`a-b` 3 chars, `1-2` 3 chars) + single-word literals (`about`, `login`, `contact` — no hyphen). Accepts `my-post` (7), `alice-cooper` (12), `2025-01-15` (10 — dates legitimately cluster).
- [feat] **No Node deps added.** Standard library RegExp only; ~6 LOC in the helper. Matches the no-deps constraint of the existing helper.
- [internal] 4 bats updates in `tests/browser-do.bats`: 1 flipped (slug bats from PR #97 `"slugs don't cluster"` → `"slugs DO cluster + correct archetype_id"`); 3 new (too-short hyphenated rejected · single-word literals rejected · slug + non-slug mix yields only slug cluster).

**Sub-scope (this PR):**
- **Heuristic only — no machine-learning / dictionary lookup.** A Markov chain on common path words could refine; deferred until false-positive surface area justifies the complexity (none seen in the 4 fixture cases shipped).
- **`:slug` derivation order is fixed.** numeric → UUID → slug → literal. Numeric segments like `123` continue to template to `:id` (NOT `:slug` even though they "would have matched" without the numeric branch).
- **No new archetype-id heuristic.** Existing `_derive_archetype_id` chain produces `posts-slug` for `/posts/:slug`; no special handling needed.
- **No retroactive reclassification of stored patterns.** Existing `patterns.json` rows untouched — only NEW `propose` invocations see the new clustering. Combined with A4's canonical compare (PR #123), the storage layer self-heals over time as duplicates collapse.
- **No interaction with --auto-record (PR #121) or --from-recent (PR #125) — composes naturally.** Both consume the same cluster output; the new slug branch enriches it.

User-facing verb count unchanged (42). The cluster helper grew from ~80 LOC → ~90 LOC; no other surface affected.

**Phase 11 v2 hardening backlog ✅ COMPLETE for v1.5.** All A-series picks shipped: A1 (events.jsonl writer) / A2 (slug heuristic) / A3 (--auto-record) / A4 (pattern canonicalization) / A5 (self_heal_history) / A6 (recent_urls observation log). Only **Pick B (daemon e2e)** + adoption work remain.

### Pick A6 — `recent_urls.jsonl` passive navigation observation log + `propose --from-recent`

`browser-do --intent` records cache hits/misses (PR #115 `events.jsonl`). What's been MISSING: every URL the user **visited** (via `browser-open`, `browser-flow run`, etc). Without that signal, `browser-do propose` could only see URLs the agent fed via `--url`. Pick A6: passive observation — `browser-open` tees URLs to a new append-only log; `propose --from-recent` reads from it.

- [feat] **New helper `scripts/lib/memory.sh::memory_record_recent_url SITE URL VERB`.** Appends `{ts, url, verb, site, schema_version:1}` to `${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl` (mode 0600 in mode 0700 `memory/`). Best-effort writer — failure emits `warn:` and continues; never taints caller exit code. Same convention as `_record_event` in `browser-do.sh` (PR #115).
- [feat] **`scripts/browser-open.sh` tees on success.** After the adapter returns 0, `memory_record_recent_url "${ARG_SITE:-$(current_get)}" "${url}" "open"` writes one row. Site resolution: `--site` flag wins; falls back to `current_get` (sticky current site). Site-less navigations skip the tee (recent_urls is site-scoped for `propose --from-recent` consumption).
- [feat] **`--dry-run` does NOT tee.** Mirrors the adapter call semantics — dry-run never executed the adapter, so no navigation actually happened. Bats pins this.
- [feat] **`scripts/browser-do.sh::propose --from-recent` flag.** Reads `recent_urls.jsonl`, filters to lines matching the resolved site, appends URLs to the cluster input. Composes additively with existing `--url` args and stdin URLs. Absent log → no-op (not an error). Useful for end-of-session: `bash scripts/browser-do.sh propose --site app --from-recent --auto-record` consolidates the day's navigation history into pattern rows in one call.
- [feat] **New `scripts/lib/migrators/recent_urls/` directory** (placeholder; README only). Schema starts at `v1` from inception — no migrator needed until a future shape bump. Mirrors the `lib/migrators/memory/` precedent from PR #111 (where `v1_to_v2.sh` shipped per actual bump, not preemptively).
- [internal] 10 new bats: 4 in `tests/memory.bats` (helper shape + mode 0600 + parent-dir 0700 lazy-create + best-effort write-failure non-fatal) + 4 in `tests/browser-do.bats` (`propose --from-recent` clusters + site-filter + combines with `--url` + absent-log graceful) + 2 in `tests/browser-open.bats` (success tees + `--dry-run` does NOT tee).

**Sub-scope (this PR):**
- **Initial write site is `browser-open` ONLY.** Smallest reviewable surface. Future verbs (`browser-flow run`, `browser-replay`, `browser-do` cache-hit dispatches) can tee in follow-up PRs without API surface change.
- **No retention/pruning.** Log grows unbounded for v1. Future maintenance verb (`browser-do clean-recent --keep N` or `--older-than D`?) can land case-by-case if growth becomes operational.
- **No URL canary check.** URLs may contain query params with sensitive bytes (tokens, session IDs). The log is mode 0600 inside mode 0700 `memory/` (same as credential metadata + archetype caches); content-filtering on URLs is out of scope and would break legitimate use cases (any URL with `?token=` parameter — those are agent-driven navigations the user explicitly wants logged for replay/cluster).
- **No time-window filter in `--from-recent`.** All lines are read; `propose`'s existing threshold filter handles the "is this URL family significant?" question. Future `--last-n` / `--since` flags could window the read; deferred.
- **No migrator code for v0_to_v1.** Schema starts at `v1`; the registry walks the `recent_urls` namespace via the placeholder README's existence (no fn to register).
- **No doctor surface for `recent_urls.jsonl`.** Doctor already surfaces `events.jsonl` via the `check:"memory_cache"` block (PR #113); a separate `check:"recent_urls"` block could land in a tiny follow-up.

User-facing verb count unchanged (42). Total memory-dir files: 3 (`patterns.json`, archetype JSONs, `events.jsonl`) → 4 (add `recent_urls.jsonl`). All mode 0600 inside mode 0700 `memory/`.

### Pick A4 — Pattern-equivalence canonicalization (`:NAME` collapse for compares)

Today, agents that hand-record patterns often pick different parameter names — `/devices/:id` and `/devices/:itemId` describe the SAME URL family but are stored as **different** rows in `patterns.json`, creating redundant entries and splitting cache hits across two archetypes. Pick A4 collapses `:NAME` segments to a canonical form (`:NAME` → `:_`) for comparison; storage preserves original names for readability.

- [feat] **`scripts/lib/memory.sh::memory_record_pattern` idempotency check now uses canonical form.** New inline jq helper `def _canonical: gsub(":[A-Za-z_][A-Za-z0-9_]*"; ":_")`. Idempotency key is **only the canonical url_pattern** (dropped the AND `.archetype_id` clause): re-recording `/devices/:itemId` when `/devices/:id` exists → 1 row, `hit_count` bumped, first-written `url_pattern` + `archetype_id` preserved.
- [feat] **`scripts/browser-do.sh::propose` suppression filter now canonical-aware.** The `inside($known)` check canonicalizes both the proposed cluster's `templated` and each known `url_pattern` from `patterns.json` before compare. Cluster `/devices/:id` is suppressed when `patterns.json` already has `/devices/:itemId`. `skipped_known` counter reflects canonical-match suppressions.
- [feat] **Resolver path unchanged.** `scripts/lib/node/url-pattern-resolver.mjs` already compiles `:NAME` → `[^/]+` agnostic to param name (its regex `/:[A-Za-z_][\w$]*/g`); URL→pattern matching has always worked across name variants. A4 adds the missing piece: the **write-side** equivalence check that prevents redundant rows from being created in the first place. New bats pin this resolver behavior as a regression net.
- [internal] 6 new bats: 5 in `tests/memory.bats` (collapse + first-write-wins preservation + canonical match wins over archetype_id mismatch + non-equivalent paths stay separate + resolver param-agnostic regression) + 1 in `tests/browser-do.bats` (propose suppresses canonically-equivalent cluster).

**Sub-scope (this PR):**
- **Locked decision: lexical normalization, not structural.** `:NAME` → `:_` for compare only. Skip Levenshtein / AST-style alternatives — they need more design surface for marginal gain.
- **Canonical key is COMPUTE-ONLY.** Storage preserves the original `url_pattern` text written by the user; the canonical form never lands on disk. Readability + audit trail remain intact.
- **No storage migration.** Existing rows keep their names; comparisons just stop discriminating on name. Doctor still surfaces `migrations` count of 0 after this PR (no schema bump).
- **No `_derive_archetype_id` canonicalization.** Archetype IDs are still derived from raw patterns (`/devices/:id` → `devices-id`; `/devices/:itemId` → `devices-itemid`). Two agents hand-recording with different `:NAME`s will produce different archetype IDs — but the SECOND record's archetype_id is silently discarded on canonical match (first-write wins).
- **No retroactive deduplication.** Existing redundant rows from before this PR stay as-is. A future maintenance verb (`browser-do dedup`?) could consolidate; deferred until demand surfaces.
- **No `memory_resolve_archetype` change.** The resolver already does the right thing per the JS regex; the bats regression test pins this behavior.

User-facing verb count unchanged (42). `patterns.json` schema unchanged.

### Pick A3 — `--auto-record` flag on `browser-do propose`

`propose` (PR #97, 11-2-ii) is read-only by default — emits `_kind:proposal` events for URL clusters meeting the threshold AND not already in `patterns.json`. Today the agent reads the proposals and decides whether/which to record explicitly. With `--auto-record`, every proposal that survives the existing suppression filter is auto-persisted via `memory_record_pattern`. Useful for batch-onboarding a corpus of URLs at session start.

- [feat] **`scripts/browser-do.sh` propose sub-mode gains `--auto-record` flag** (boolean; default off). When set, the proposal-emit loop calls `memory_record_pattern "${site}" "${url_pattern}" "${archetype_id}"` immediately after emitting each proposal event. The flag is purely additive — absence preserves the existing read-only contract (C5 invariant from 11-2-ii).
- [feat] **Auto-record runs AFTER the suppression filter.** The proposal stream is already `not inside(known)` filtered before any auto-record call; suppressed clusters never reach the write site. Mirrors C4: "already-known patterns suppress proposals." Combined effect: re-running `propose --auto-record` on the same corpus is **idempotent** — the second run sees the patterns it just wrote as known + skips them.
- [feat] **Best-effort writer** — `memory_record_pattern` failure emits `warn:` and continues; never taints `propose`'s exit code. Matches the established cache-write contract (Phase 11 1-ii: write-side failure must not break the read flow).
- [feat] **Summary `auto_recorded:N` field** — `summary_json` now reports the count of patterns persisted this run. Always present (zero when flag absent OR when no proposals were emitted), so consumers can rely on the field shape unconditionally.
- [internal] 4 new bats in `tests/browser-do.bats` (41 → 45 cases): (a) 3 numeric URLs → patterns.json gains 1 row + `auto_recorded:1`; (b) already-known pattern → 0 proposals + 0 auto-records (suppression filter wins; matches C4); (c) absence of `--auto-record` → patterns.json NOT created (preserves C5 read-only contract); (d) 2 distinct clusters → 2 rows + `auto_recorded:2`.

**Sub-scope (this PR):**
- **No design surface change.** propose's C1-C6 invariants from 11-2-ii are unchanged: pure compute on URL list / numeric + UUID heuristics only / default threshold N=3 / suppress already-known / always emit-never-auto-record-by-default / always exits 0.
- **No `--auto-record` typed-phrase confirmation.** Unlike `browser-migrate run` (destructive — bumps version), pattern recording is additive + idempotent; the flag suffices.
- **No retroactive auto-record of previous proposals.** This PR adds the flag to the current run only; persisting historical proposals would need a separate sub-mode.
- **No `--auto-record` on the `record` sub-mode.** `record` is already explicit-write-by-design; `--auto-record` is meaningful only when paired with the read-only `propose` flow.
- **No interaction with self-heal.** Pattern recording bumps `hit_count` on the pattern row; doesn't touch any archetype's `self_heal_history[]`.

User-facing verb count unchanged (42). `propose` summary line gains one new field (`auto_recorded`); existing fields unchanged.

### Pick A5 — `self_heal_history[]` audit-trail population

Phase 11 1-iii (PR #92) shipped the disable mechanic (`fail_count > 3 → disabled:true`) and the D2 heal mechanic (`memory_record` resets `fail_count` + `disabled`). The archetype schema reserved a `self_heal_history[]` array field on every interaction since Phase 11 1-i — but **no writer existed**. The field stayed `[]` forever. Pick A5 lights up the audit trail.

- [feat] **`scripts/lib/memory.sh::memory_record_failure`** appends one entry to `self_heal_history[]` on the **enabled→disabled transition** (single-shot). Shape: `{ts, event:"disabled", fail_count, selector_at_time}`. Subsequent failures past the threshold do NOT double-log — the guard `(.disabled // false) == false` ensures only the crossing fires. `selector_at_time` captures the cached selector that broke; useful for forensic queries ("what selectors keep breaking?").
- [feat] **`scripts/lib/memory.sh::memory_record`** appends one entry on the **disabled→enabled transition** (D2 heal path). Shape: `{ts, event:"healed", fail_count, selector_at_time}`. `fail_count` captures the **pre-reset** value (e.g. 4, the value at the time of disable). `selector_at_time` captures the **new** selector the agent re-resolved to. The guard `(.disabled // false) == true` ensures the entry only fires when there was something to heal — calling `memory_record` on a healthy interaction (D2 not triggered) does NOT append an entry.
- [feat] **Entry shape is stable + minimal:** `{ts, event, fail_count, selector_at_time}`. No nesting; no nullable optional fields; doctor + future forensic verbs can `jq` over `self_heal_history` reliably without optional-field shenanigans.
- [security] **No canary surface.** `selector_at_time` is a CSS selector (already in cache); `ts` is server-side time; `event` + `fail_count` are pure metadata. The recipe `cache-write-security.md` constraints continue to hold — entries are computed, not user-supplied.
- [internal] 5 new bats in `tests/memory.bats` (13 → 18 cases): 4th failure → 1 "disabled" entry with `fail_count:4` + `selector_at_time` · 1-3 failures → 0 entries (below threshold) · 5th/6th failures past threshold → still 1 entry (single-shot, no double-log) · `memory_record` on disabled → 1 "healed" entry appended + `fail_count` reset to 0 + `disabled:false` (D2 invariant preserved) · `memory_record` on NOT-disabled → 0 entries (no spurious heal events).

**Sub-scope (this PR):**
- **No new verb.** Storage-layer write-side only; no agent surface change. Reading `self_heal_history[]` happens via `jq` directly today; a future verb can wrap that if demand surfaces.
- **No design changes to disable/heal mechanics.** Both transitions stay exactly as 1-iii specified (4-failure threshold; D2 healing on re-record). Only the audit trail's write side is new.
- **No timestamp format change.** Uses existing `now_iso` (second-precision ISO 8601). If sub-second precision is needed later, `now_ms` is the upgrade path; not now.
- **No retention/pruning of `self_heal_history[]`.** Append-only; grows with every disable/heal cycle. A 50-cycle interaction would have ~50 entries — well below any realistic concern. Pruning would land as a separate maintenance pass if archetype JSONs ever balloon.
- **No emission of `self_heal_history` entries to `events.jsonl`.** PR #115's observation log is for cache-hit/miss; this audit trail lives in the archetype JSON. Two different scopes; do not conflate.

User-facing verb count unchanged (42). Interaction shape unchanged at the schema-version level (still v2; `self_heal_history` was reserved at v1, populated at v2).

### Pick D — README/SKILL.md refresh for `browser-migrate` + doctor n/a-message text fix

Tiny doc-only PR (with one source-text tweak). Closes a doc-debt item pending since Phase 10 closure (`browser-migrate` shipped 4 PRs ago but the SKILL.md verb table never gained the row).

- [docs] **SKILL.md gains a `Schema migration (browser-migrate)` verb table** with 5 sub-mode rows (`check`, `status`, `run`, `rollback`, `clean-backups`). Mirrors the existing `flow run` / `baseline save` row style — short sub-mode label, parent verb name in the section heading.
- [docs] **SKILL.md gains a `Migration & schema evolution` section** covering per-schema versioning invariants: MIG4 (doctor never auto-migrates) · atomic-swap + automatic backup · manual rollback · PID-tracked lock file. Pointers to the Phase 10 design doc for full contract.
- [docs] **SKILL.md intro:** "41 verbs" → "42 verbs"; intro list adds "per-schema state migration tooling".
- [docs] **README.md:** "41 verbs" → "42 verbs" (intro + Layout block); Status line refreshed (Phase 10 SHIPPED, Phase 11 v2 part 1 SHIPPED, end-to-end ROI loop closed); Roadmap line refreshed ("v1.0 work ✅ COMPLETE"); test count 899 → 941+; Layout adds `lib/migrators/`.
- [fix] **`scripts/browser-doctor.sh`:** stale `n/a` reason text fixed. Was "observation log not enabled — Phase 11 v2 pending" (accurate before PR #115); now "no events yet — run 'browser-do --intent' to generate cache observations" (accurate after PR #115 shipped the writer).
- [internal] new `tests/docs-coverage.bats` (4 cases): SKILL.md has `migrate check`/`migrate run` rows · SKILL.md has the `Migration & schema evolution` section · SKILL.md intro NOT "41 verbs" · README.md intro NOT "41 verbs". Pins hand-curated doc rows against silent drift the same way `regenerate-docs.bats` pins the autogen block. Future verbs that ship without doc-row updates fail this suite in CI.
- [internal] flipped 1 assertion in `tests/doctor.bats` (no-events case) — now also asserts the new accurate reason text + asserts the stale "Phase 11 v2 pending" string is GONE.

**Sub-scope (this PR):**
- **No `regenerate-docs.sh` changes.** SKILL.md verb tables are hand-curated, not autogen; the existing AUTOGEN block (tools table) is unchanged.
- **No README quickstart edits** for `browser-migrate`. Quickstart focuses on the everyday flow (open + snapshot + click); migration is a maintenance verb agents only invoke when doctor reports pending count.
- **No new recipe.** "Migration & schema evolution" lives in SKILL.md; Phase 10 design doc is the deep reference.
- **No verb count change.** 42 user-facing verbs total — same count HANDOFF declared after PR #110 (`browser-migrate` landed); just propagated the count into the docs.

User-facing verb count unchanged (42). Doctor's `n/a` message no longer claims Phase 11 v2 is pending.

### Phase 11 v2 part 1 — events.jsonl writer (Pick A1) — lights up doctor's cache-hit-rate read side

Closes the loop with PR #113. Doctor's read side has been waiting for a writer since the previous release; this PR adds it. Same forward-compat dependency landing pattern as Phase 7-1-v `meta.is_baseline:true` → Phase 9-1-v `baseline save`.

- [feat] **`scripts/browser-do.sh` now tees per-invocation observations to `${BROWSER_SKILL_HOME}/memory/events.jsonl`.** Three call sites (cache_hit:true, cache_hit:false reason:no_pattern_for_url, cache_hit:false reason:intent_not_cached) each append one line. After Phase 11 v2 part 1 ships, `browser-doctor.sh` reports a real cache-hit-rate percentage instead of `n/a (observation log not enabled — Phase 11 v2 pending)`.
- [feat] **New helper `_record_event JSON_STRING`** in `browser-do.sh`. Caller builds the per-event JSON (each call site has different fields); helper adds `{ts, verb:"do", mode:"intent"}` envelope + appends. Best-effort writer — failure emits `warn:` and continues; never taints the dispatched verb's exit code. **Mirrors the existing `memory_record` write-back contract** (best-effort; exit unchanged on cache-write failure).
- [security] **Intent strings are NEVER logged.** Doctor only reads `.cache_hit` (bool); other fields (`site`, `archetype_id`, `reason`, `dispatched_verb`, `dispatch_rc`) are best-effort context but **user-supplied intent text never reaches the log**. Defense-in-depth: even if a hostile intent somehow bypassed `_canary_check`, it cannot leak through `events.jsonl`.
- [feat] **File mode 0600 (rest); parent dir mode 0700.** Append-only via POSIX O_APPEND atomicity (jsonl lines well below PIPE_BUF 4KB). `chmod 600` post-write is idempotent.
- [feat] **Forward-compat shape:** each line is `{ts:ISO8601, verb:"do", mode:"intent", cache_hit:bool, site, archetype_id?, reason?, dispatched_verb?, dispatch_rc?}`. Phase 11 v2 part 2 may add window-filtering in doctor (`--window 7d`) once events.jsonl line counts grow; today's lifetime ratio is good enough.
- [internal] 6 new bats in `tests/browser-do.bats` (35 → 41 cases): cache_hit:true append + cache_hit:false (both reason variants) appends + mode 0600 + privacy defense-in-depth (intent string never leaks) + append-not-truncate across 3 invocations.

**Sub-scope (this PR):**
- **No `record` sub-mode logging.** Only `--intent` mode (the cache-lookup path) writes to events.jsonl. `record` is an explicit write-back from the agent; doctor's metric is about cache utilization, not user-driven recording.
- **No `propose` sub-mode logging.** Pure-compute mode (URL clustering); not a cache decision.
- **No time-window queries from doctor.** Doctor still reports lifetime ratio. When the log grows, doctor can filter; not yet.
- **No log rotation.** Append-only forever. Future: `clean-events` sub-mode on `browser-do` (or a new `browser-events` verb) for retention; deferred until events.jsonl growth becomes operational.
- **No structured access (jq query/stats) on events.jsonl from a verb.** Doctor reads it directly via `jq -s`; cli-side aggregation deferred.
- **No `_kind:cache_hit`/`_kind:cache_miss` shape divergence.** The same `summary_json verb=do mode=intent` shape doctor already counts is teed verbatim (modulo intent omission); no parallel event format.

User-facing verb count unchanged (42). Doctor's `cache hit rate: n/a` message will switch to a real percentage on first `browser-do --intent` invocation post-upgrade.

### Phase 10 follow-up + Phase 11 v2 forward-compat — `browser-doctor` migrate-warn + memory cache hit-rate

Single doctor refresh PR bundling two advisory checks. Both are read-only; neither changes doctor's exit code (still 0 on healthy adapters; still `EXIT_PREFLIGHT_FAILED` on real problems).

- [feat] **`browser-doctor.sh` now surfaces pending migrations.** Sources `lib/migrate.sh` and calls `migrate_check` (read-only by design — no lock acquired; MIG4 invariant preserved). Emits:
  - Machine: `{"check":"migrations","pending":N}` JSON line on stdout (mirrors the per-adapter `check:"adapter"` event pattern).
  - Human: `warn: N pending migration(s) — run 'browser-migrate check' for details` when N>0; `ok: no pending migrations` otherwise.
  - **Doctor never auto-migrates.** Surfacing only; user invokes `browser-migrate run` to apply.
- [feat] **`browser-doctor.sh` now reports memory cache hit-rate (read-side forward-compat).** Looks for `${BROWSER_SKILL_HOME}/memory/events.jsonl`. When present, counts `.cache_hit == true` vs `.cache_hit == false` lines and emits both a human-readable percent + JSON event. When absent, reports `n/a (observation log not enabled — Phase 11 v2 pending)`.
  - Machine: `{"check":"memory_cache","hits":H,"total":T,"hit_rate_pct":P}` (or `hit_rate_pct:null` when n/a).
  - Human: `ok: memory cache hit rate: 60% (3/5 events)` style.
- [feat] **Forward-compat dependency landing.** This PR ships the *read* side; Phase 11 v2 ships the *write* side (tee `verb=do mode=intent` summary lines into `events.jsonl` from `browser-do.sh`). When Phase 11 v2 lights up, doctor's line switches from `n/a` to a real percent with zero doctor changes — same pattern as PR-N-ships-skip-side then PR-N+1-lights-it-up (mirrors `BROWSER_DO_DISPATCH_OVERRIDE` precedent in 11-1-iii self-heal).
- [internal] 5 new bats in `tests/doctor.bats` (15 → 20 cases): zero-pending warn-line absence; identity migrator via `BROWSER_SKILL_MIGRATORS_DIR` → `pending:1` JSON + warn; events.jsonl absent → `hit_rate_pct:null`; events.jsonl with 3 hits / 2 misses → `60% (3/5 events)`; events.jsonl present-but-empty → `n/a (events log present but empty)`.

**Sub-scope (this PR):**
- **No `browser-do.sh` edits.** Phase 11 v2 ships the events.jsonl writer separately (Pick A from the v2 hardening list).
- **No new lib helper.** Doctor sources `lib/migrate.sh` directly and reads `events.jsonl` via plain `jq -s`.
- **No `bc` dependency.** Integer-only math: `(hits * 100) / total`. Loses fractional precision (60% not 60.0%); good enough for an advisory.
- **No time-window filter on cache hit rate.** Lifetime ratio over all events. When Phase 11 v2 timestamps events, doctor can add `--window 7d`; not now.
- **No data migration of `events.jsonl` shape.** Read side accepts the existing `summary_json verb=do mode=intent` shape; Phase 11 v2 just `tee`s without transformation.

User-facing verb count unchanged (42). All four adapter checks unchanged.

### Phase 10 part 1-iii — first real migrator (no-op v1_to_v2 for memory) — CLOSES Phase 10 part 1

- [feat] new `scripts/lib/migrators/memory/v1_to_v2.sh` defining `migrate_memory_v1_to_v2 <file_path>` — first real migrator. **No-op identity** (purely bumps `schema_version` from 1 to 2; no data shape change). Validates the registry + dispatch end-to-end against production code (not test fixtures).
- [feat] **F1 — Identity migrator only.** No data shape change. Migrator just ensures `.schema_version = 2`. Atomic-swap + backup + validation handled by `lib/migrate.sh::migrate_run` (10-1-i).
- [feat] **F2 — Memory archetype JSONs are the target.** Already-isolated state (Phase 11 1-i shape); single-file pattern; clean schema_version field; not user-facing data — corruption would only break cache hits, not credentials/sessions. Lowest-risk first migration target.
- [feat] **F5 — Migration scope: every `*.json` under `${BROWSER_SKILL_HOME}/memory/`** — both `patterns.json` AND archetype JSONs. Migrator is uniform (just bumps schema_version on whatever JSON it gets); lib's `find -type f -name '*.json'` walks both.
- [internal] new `tests/migrators-memory.bats` (3 cases): registry auto-loads memory v1_to_v2 + `migrate_check` emits `_kind:migration_needed schema:memory from:1 to:2` · `browser-migrate run --yes --schema memory` bumps versions.json + archetype JSON + creates backup mode 0600 · patterns.json AND archetype JSON both migrated (find walks both).

**Sub-scope (10-1-iii):**
- **No data shape change.** Identity migrator only.
- **No new lib helpers.** Reuses 10-1-i (lib/migrate.sh) + 10-1-ii (browser-migrate verb) entirely.
- **No `--auto-migrate` flag on doctor.** Migration stays opt-in.
- **No documentation of the v2 shape** — there isn't one beyond `schema_version: 2`. Real shape changes ship per future migrator.
- **No migration of existing user state.** Tests use fresh fixtures; production users on v1 will see "1 migration needed" on first `browser-migrate check` post-upgrade.

**Phase 10 part 1 ✅ CLOSED.** All 3 sub-parts shipped:
1. `lib/migrate.sh` foundation (10-1-i, PR #109) — pure read/write API
2. `browser-migrate` verb (10-1-ii, PR #110) — sub-mode dispatch + lock + typed-phrase
3. First real migrator (this PR — 10-1-iii) — no-op identity for memory

**Phase 10 ✅ COMPLETE for v1.** Future per-schema migrators ship case-by-case as schema bumps land (~30 LOC + ~3 bats per new migrator). No Phase 10 part 2 planned.

User-facing verb count unchanged (browser-migrate landed in 10-1-ii). Memory schema is the only real-migrated schema today.

### Phase 10 part 1-ii — `browser-migrate` verb (sub-mode dispatch + lock + typed-phrase confirmation)

- [feat] new `scripts/browser-migrate.sh` — agent + user surface over `lib/migrate.sh` (10-1-i). Five sub-modes: `check` · `status` · `run [--yes] [--schema NAME]` · `rollback --schema NAME [--yes]` · `clean-backups [--keep N] [--yes]`.
- [feat] **Destructive sub-modes (`run`, `rollback`, `clean-backups`) require confirmation:** `--yes` flag for scripted use; otherwise interactive TTY typed-phrase prompt (`migrate now` for run, `migrate rollback <schema>` for rollback, `clean backups` for clean-backups). Mismatch → `EXIT_USAGE_ERROR`. Non-TTY without `--yes` → `EXIT_TTY_REQUIRED (27)`.
- [feat] **PID-tracked lock file** at `${BROWSER_SKILL_HOME}/.migrate.lock` (mode 0600). Prevents concurrent migrations: if lock exists + PID alive → die `EXIT_USAGE_ERROR` ("another migration in progress; wait or kill it"). Stale lock (PID dead) auto-cleared with `warn:` line + overwrite. `trap _release_migrate_lock EXIT` ensures cleanup on success or failure. **`check` and `status` are read-only — they don't acquire the lock.**
- [feat] **`--schema NAME` filter** — applies to `run` (limits scope to one schema) and is required for `rollback`. `check`/`status`/`clean-backups` always full-scope.
- [feat] **Sub-mode dispatch shape mirrors `browser-history.sh` (PR #86 precedent)** — single bash file ~190 LOC; case-statement at the top routes to per-sub-mode flag-parsing blocks; sub-modes call into `lib/migrate.sh` API directly.
- [fix] `scripts/lib/migrate.sh::migrate_clean_backups` — refactored to use newline-separated find pipelines (find→sed→sort) instead of space-joined values in associative array. **Bug discovered during 10-1-ii bats:** verb sets `IFS=$'\n\t'` (per common.sh convention), which prevented unquoted-array word-splitting on space — `printf '%s\n' ${by_key[X]}` produced one big string instead of one line per version. Newline-separated streams work under any IFS. Lib bats now exercises the fix in 10-1-i + 10-1-ii.
- [internal] new `tests/browser-migrate.bats` (12 cases): `check` empty pending:0 · `status` echoes versions.json · `run --yes` empty migrated:0 · `run` no --yes no TTY → exit 27 · `run --yes --schema test` with identity migrator → version bumped + backup · `rollback --schema test --yes` restores · `rollback` missing --schema → exit 2 · `clean-backups --keep 1 --yes` keeps newest only · lock test: alive PID refuses · lock test: dead PID stale-cleared + proceeds · unknown sub-mode → exit 2 · missing sub-mode → exit 2.
- [docs] `docs/superpowers/plans/2026-05-11-phase-10-part-1-ii-browser-migrate.md` — phase plan with locked decisions Q3 (typed-phrase) + Q4 (lock file).

**Sub-scope (10-1-ii):**
- **No real migrators registered.** 10-1-iii ships first (no-op `v1_to_v2` for memory archetype JSONs).
- **No verb-router promotion.** `browser-migrate` invoked directly (skill-internal state operation; no adapter routing).
- **No `--all` flag** — `migrate run` defaults to all schemas; `--schema` narrows.
- **No JSON-formatted prompt** — typed-phrase prompts to stderr; only the JSON event stream goes to stdout.
- **Lock helper inline in browser-migrate.sh** — not promoted to `lib/lock.sh` until a second verb needs file-locking. Defer until demand.

User-facing verb count: 41 → **42** (`browser-migrate` is a new parent row; skill-internal verb counted alongside `doctor`).

### Phase 10 part 1-i — `lib/migrate.sh` foundation

- [feat] new `scripts/lib/migrate.sh` — pure read/write API for schema-version detection + migration dispatch + atomic-swap with backup + manual rollback. No verb integration yet (10-1-ii ships `browser-migrate`); no real migrators registered (10-1-iii ships first identity migrator).
- [feat] **MIG1 — Per-schema versions:** `${BROWSER_SKILL_HOME}/versions.json` (mode 0600, lazy-created) carries `{schema_version:1, schema_versions:{sites:1,sessions:1,credentials:1,captures:1,baselines:1,memory:1,config:1}, skill_version:"v0.56.0"}`. Legacy `version` file (single integer) seeds versions.json on first init.
- [feat] **MIG2 — Registry directory:** `scripts/lib/migrators/<schema>/v<from>_to_<to>.sh` pattern. Auto-loaded by `_migrate_load_registry`; each file defines a fn `migrate_<schema>_v<from>_to_v<to>` per filename convention. Empty in 10-1-i (only `README.md` placeholder); real migrators ship in 10-1-iii.
- [feat] **MIG3 — Atomic write + automatic backup:** `migrate_run` backs up each migrated file to `${BROWSER_SKILL_HOME}/backups/<schema>/<basename>.bak.v<prior_version>` (mode 0700 dir, 0600 file) BEFORE running the migrator. Validates post-migration JSON via `jq -e .`; refuses to bump schema version on validation failure (file restored from backup).
- [feat] **MIG5 — Pure bash + jq:** no Node dependency in lib/migrate.sh. Per-migrator unit-testable with fixture file + expected output.
- [feat] **`BROWSER_SKILL_MIGRATORS_DIR` env override** — test-only seam (mirrors `BROWSER_DO_DISPATCH_OVERRIDE` from 11-1-iii self-heal). Production code never sets this; tests use it to inject fixture migrators without touching `scripts/lib/migrators/`.
- [feat] **Public API surface:** `migrate_init` · `migrate_get_version SCHEMA` · `migrate_set_version SCHEMA N` · `migrate_check` · `migrate_run [SCHEMA]` · `migrate_rollback SCHEMA` · `migrate_status` · `migrate_clean_backups [N]`.
- [internal] new `scripts/lib/migrators/README.md` — directory scaffold + convention doc explaining the `migrate_<schema>_v<from>_to_v<to>` fn naming + filename-parsing auto-load.
- [internal] new `tests/migrate.bats` (12 cases): init creates mode 0600/0700 + idempotent · legacy version file seeds versions.json · get_version defaults to 1 · set_version round-trip · check empty registry pending:0 · check identity migrator emits `_kind:migration_needed` · run empty migrated:0 · run identity bumps version + creates backup mode 0600 · run validates JSON refuses bad output · rollback restores from backup · clean_backups keeps newest N · status echoes versions.json.
- [docs] `docs/superpowers/plans/2026-05-11-phase-10-part-1-i-migrate-foundation.md` — phase plan with locked decisions MIG1/MIG2/MIG3/MIG5 + open questions deferred to 10-1-ii.

**Sub-scope (10-1-i):**
- **No `browser-migrate` verb.** 10-1-ii.
- **No real migrators registered.** Empty registry; tests use fixture migrators via env override.
- **No typed-phrase confirmation.** Verb-layer concern; 10-1-ii.
- **No concurrent-migration lock file.** Lib doesn't enforce single-instance; 10-1-ii adds `${BROWSER_SKILL_HOME}/.migrate.lock`.
- **No multi-version chain rollback.** Single-step only; chains require multiple invocations.
- **No automatic migration trigger.** All migrations explicit via `migrate_run`.
- **No skill_version write to versions.json beyond initial value.** 10-1-ii's verb refreshes it.

User-facing verb count unchanged. Phase 10 part 1 in flight — 1/3 sub-parts shipped (foundation; verb + first migrator queued).

### Phase 10 design doc — schema migration tooling

Pure-design PR; no code yet. Locks decisions before implementation. Mirrors PR #57 (Phase 11 design) shape — design doc lands separately so implementation PRs can reference locked decisions instead of re-deriving them.

- [docs] new `docs/superpowers/specs/2026-05-11-phase-10-schema-migration-design.md` — Phase 10 design doc with locked decisions:
  - **MIG1:** Per-schema versions (not global) — each schema (sites/sessions/credentials/captures/baselines/memory/config) carries its own `schema_version`; migrating one doesn't touch the others. New `~/.browser-skill/versions.json` replaces single-integer `version` marker; old marker kept for compat.
  - **MIG2:** Migrators registered per schema — `lib/migrators/<schema>/v1_to_v2.sh` pattern (mirrors `lib/tool/` adapter registry precedent). Reviewer-friendly per-schema-per-version isolation; PR boundaries match plan-doc boundaries.
  - **MIG3:** Atomic write + automatic backup; manual rollback. `${file}.bak.v${prior_version}` retained for last 5 versions per file (default; configurable). Validation via `jq -e .` before atomic-swap. All-or-nothing per file.
  - **MIG4:** Verb shape `browser-migrate {check,run,rollback,status,clean-backups}`. `check` is read-only safe (callable on session start); `run` requires `--yes` flag OR typed-phrase confirmation. **Doctor never auto-migrates** — read-only invariant preserved.
  - **MIG5:** Pure bash + jq migrators; no Node dependency. No network calls; no env modifications; no cross-file state. Each migrator unit-testable with fixture file + expected output.
- [docs] **3-sub-part split:** 10-1-i `lib/migrate.sh` foundation + 10-1-ii `browser-migrate` verb + 10-1-iii first real migrator (no-op v1_to_v2 for memory archetype JSONs to validate registry+dispatch end-to-end).
- [docs] Storage shape evolution: new `~/.browser-skill/versions.json` (mode 0600) + `~/.browser-skill/backups/<schema>/<file>.bak.v<N>` (mode 0700 dir, 0600 files). Mirrors capture pipeline path-security pattern.
- [docs] Recipe applicability: `path-security.md` + `privacy-canary.md` + `cache-write-security.md` all apply to migrators. `body-bytes-not-body.md` + `model-routing.md` n/a.
- [docs] **Sequencing locked:** Phase 11 (✅) → Phase 10 (this design + impl) → future per-schema migrators ship case-by-case as schema bumps land.

**Sub-scope (this PR):**
- **No implementation** — design only. PRs 10-1-i/ii/iii implement.
- **No `versions.json` schema bump** — frozen at v1 by this design.
- **No migration of existing schemas** — first real migrator (10-1-iii) is no-op identity.
- **No auto-migrate** — opt-in via `browser-migrate run` (MIG4).
- **No cross-version chained downgrade** — each rollback is single-step.

**Phase 10 sequencing:** implementation PRs (10-1-i/ii/iii) ship as ~3 separate PRs after this design doc lands. Estimated ~5 PRs total to close Phase 10 (3 substantive + 2 HANDOFF refresh PRs).

### v1-polish — Stage 1 bundle (README + SKILL.md refresh + macOS flake fix + press deferral codification + adapter install guidance)

Cohesive "v1.0 polish" pass. Five small related changes shipped in one PR — none alone justifies its own ship; together they unblock adoption + close one open deferral.

- [docs] `README.md` rewritten — was stale ("Status: Phase 1, the verb that ships in this phase is `doctor`"); reality is 41 verbs across 11 shipped phases. New README accurately lists status (Phase 1-9 SHIPPED + Phase 11 ✅ FEATURE-COMPLETE for v1 + selector-mode plumbing 3/4); per-category verb summaries (site/session/credential, navigation/interaction, capture/extract/audit, flow runner, memory cache); install requirements split into "always required" vs "for real browser flows (install at least one)"; quickstart with cache record + dispatch example; output contract; layout; remaining v1.0 work pointer.
- [docs] `SKILL.md` refreshed — header status flipped from "Phase 2 — site & session core" to feature-complete description (41 verbs, 4 routed adapters, memory cache); verb table reorganized into 5 sections (site/session/cred · navigation/interaction · capture/extract/audit · flow runner · memory cache `browser-do`); previously-missing verbs added (hover · press · select · drag · wait · upload · route · tab-list/switch/close · assert · flow run/record · replay · history · baseline · do --intent/record/propose). Storage layout updated (memory/ + baselines.json + config.json + captures/ tree).
- [fix] `tests/helpers.bash::assert_output_contains` + `assert_output_not_contains` — replaced `printf | grep -qF` with bash native substring matching (`case "${output}" in *"${needle}"*)`). Eliminates the macOS pipe-race SIGPIPE flake (printf trips on broken pipe under bats' `set -euo pipefail` when `grep -q` exits early). Faster too — no subprocess. Pre-existing flake hit PR #89's macOS CI.
- [docs] `references/recipes/cache-write-security.md` — codifies SS5 press deferral as a permanent decision. New "Don't add `press` to cache-dispatch whitelist" rule explaining the bridge target-less design + recommending compose-with-click+press composition. New "Codified deferrals" table tracking press (option c) + hover/select on playwright-lib (no demand). Closes one open question while context is fresh.
- [feat] `install.sh` — added explicit adapter install guidance when no adapters installed. Previously: install completed silently; first-time users had to decode doctor JSON. Now: when `adapters_ok == 0`, prints a `warn:` block listing the three install options (chrome-devtools-mcp / playwright-cli / obscura) + clarifies which verb categories work without an adapter (site/session/cred + cache record + propose all work standalone). Also bumped step (2) to show the actual flag form (`--name NAME --url URL`) and added step (3) for `use --set`.

**Sub-scope (this PR):**
- **No code beyond install.sh + tests/helpers.bash** — README + SKILL.md + recipe are pure docs.
- **No tag bump beyond v0.56.0** — bundle is a polish patch, not a feature ship. Future v1.0 tag waits for Phase 10 + remaining hardening.
- **No CI matrix expansion** (deferred; Stage 4 work).
- **No cross-platform packaging** (deferred; Windows requires bash 5+ via WSL2 + `stat`/`sed` cross-platform fixes).

**Why bundled:** each item is small, related, and shipping together signals "v1.0 polish pass" cohesively. Splitting would have produced 5 micro-PRs with 5 HANDOFF refresh PRs (10 total). Following user preference for bundled small-related changes (memory `feedback_design_time_oss_survey.md` precedent: "yeah the single bundled PR was the right call here, splitting this one would've just been churn").

### playwright-lib `--selector` driver plumbing (closes selector-mode-fill S2 deferral)

- [feat] `scripts/lib/node/playwright-driver.mjs::runFill` + `runClick` accept `--selector CSS` (mutually exclusive with `--ref eN`; one required). Closes the gap noted in selector-mode-fill (PR #99 S2): "playwright-lib `--selector` deferred — driver IPC schema bump; coordinate with click in its own PR."
- [feat] **PL1 — Backwards-compatible IPC schema (no version bump).** Extends `{verb, ref}` → `{verb, ref?, selector?}` with mutual-exclusion + at-least-one validation. Existing `--ref` path unchanged; new IPC messages with `selector` use locator-based resolution. Old senders (sending only `ref`) work as before; new senders (sending `selector`) work too. Cleaner deprecation path; no parallel-message-shape window.
- [feat] **PL2 — Coordinated fill + click in one PR.** Driver IPC schema changes for fill ship alongside click since both use the same locator path; shipping separately would create a brief window where IPC accepts `selector` for one but not the other (more confusing to debug).
- [feat] **PL3 — `page.locator(selector).first()` for selector path.** Mirrors `locatorFor()`'s `.first()` semantics for refMap entries. First match wins; same precedence rule as ref path. **Selector path skips refMap precondition** — locators don't require snapshot.
- [feat] **PL4 — Hover NOT in scope.** Hover doesn't have a playwright-lib driver path today (routes only to chrome-devtools-mcp). If hover routing ever expands to playwright-lib, that's a separate sub-PR.
- [feat] **PL5 — Adapter unchanged.** `scripts/lib/tool/playwright-lib.sh::tool_fill` and `tool_click` are already `_drive fill "$@"` / `_drive click "$@"` — they pass argv verbatim; driver flag-parser already accepts arbitrary `--key value` pairs.
- [feat] **Secret-scrub semantics preserved on selector path.** IPC `case 'fill':` selector branch wraps `page.locator(selector).first().fill(text)` in the same try/catch + secret-scrub pattern as the ref path; never leaks the fill value through error messages.
- [internal] `tests/playwright-lib_adapter.bats` gains 4 cases (total 21): `runFill` rejects mutex (`--selector` + `--ref`) → exit 2 + "mutually exclusive" · `runFill` rejects neither → exit 2 + "selector" · same 2 for `runClick`. Tests run in **real mode** (no `BROWSER_SKILL_LIB_STUB`) because parse-validation happens BEFORE chromium import + ipcCall — validation failures exit 2 without touching playwright.
- [docs] `docs/superpowers/plans/2026-05-11-playwright-lib-selector.md` — phase plan with locked decisions PL1–PL5.

**Sub-scope (this PR):**
- **No hover plumbing** (PL4).
- **No IPC schema version bump** (PL1; backwards-compatible additive).
- **No daemon e2e tests** for selector path — covered by parse-layer + code review; e2e is its own session-scoped surface.
- **No adapter changes** (PL5).
- **No `browser-do` whitelist changes** — fill + click already in whitelist; this PR widens the dispatch surface for them, doesn't change which verbs are dispatchable.

**End-to-end Phase 11 cache dispatch now works through playwright-lib too** — previously, `browser-do --verb fill` (with `BROWSER_SKILL_STORAGE_STATE` set) would route to playwright-lib and die at the driver's "--ref required" validation. Now it accepts `--selector $cached`, dispatches via `page.locator(...)`, and returns the click/fill result. Selector-mode plumbing for fill + click is now adapter-complete (playwright-cli + chrome-devtools-mcp + playwright-lib).

### Selector-mode plumbing for `select` (3/4 of "expand `browser-do --verb` whitelist beyond `[click]`"; press deferred)

- [feat] `scripts/browser-select.sh` gains `--selector CSS` flag — mutually exclusive with `--ref eN`. Mirrors `browser-click.sh` + `browser-fill.sh` (PR #99) + `browser-hover.sh` (PR #101) precedent. Required for Phase 11 cache to dispatch select.
- [feat] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_select` accepts `--ref|--selector` as target alias.
- [feat] `scripts/browser-do.sh` whitelist grows: `[click fill hover]` → `[click fill hover select]`. End-to-end Phase 11 cache dispatch now works for `--verb select --intent "..."` against chrome-devtools-mcp.
- [feat] **SS2 — Adapter coverage = chrome-devtools-mcp only.** Other adapters don't define `tool_select`; router routes select exclusively to chrome-devtools-mcp.
- [feat] **SS3 — Bridge unchanged.** Same target-string handling as click/fill/hover.
- [feat] **SS4 — Mode flags (`--value`/`--label`/`--index`) unchanged.** Selector-mode select still requires exactly one of the three (mutual-exclusion + at-least-one preserved). Only the target axis gains a new flag.
- **SS5 — PIVOT FROM PRESS (deferred).** Survey discovered `tool_press` accepts only `--key`; chrome-devtools-bridge.mjs `case 'press':` (line 488) takes only `key`, no target ("Stateless w.r.t. refMap — acts on the focused element or page" — line 1098). Adding selector-targeting requires new "focus then press" semantic at the bridge level — bigger surface than the per-verb mechanical pattern. Deferred to a separate decision: (a) new `--focus-selector` flag on press, (b) keep press out of cache scope entirely, or (c) compose: agent calls `browser-do --verb click --intent "focus input"` followed by `browser-press --key Enter` (no cache for press; relies on existing focus state). Option (c) recommended as no-op-for-cache.
- [internal] `tests/browser-select.bats` gains 3 cases (total 10): `--dry-run --selector` accepts selector + summary carries it · `--selector` + `--ref` mutually exclusive → exit 2 · neither `--selector` nor `--ref` → exit 2 with "selector" in message.
- [internal] `tests/browser-do.bats` gains 1 case (total 35): `--verb select` whitelist accepted; cache hit dispatches via `BROWSER_DO_DISPATCH_OVERRIDE` mock with `-- --value US` forwarded.
- [docs] `docs/superpowers/plans/2026-05-11-selector-mode-select.md` — phase plan with locked decisions SS1–SS5 (including SS5 press deferral rationale).

**Sub-scope (this PR):**
- **No additional adapter coverage** (SS2; only chrome-devtools-mcp defines `tool_select`).
- **No press selector-mode plumbing** (SS5; deferred — needs bridge schema bump or design decision).
- **No mode-flag changes** (SS4; `--value`/`--label`/`--index` semantics unchanged).
- **No new privacy canary** — select doesn't ingest secrets; no AP-7 surface.
- **No route-rule changes**.

`browser-do --verb` whitelist now `[click fill hover select]`. **3 of 4 selector-mode-plumbing per-verb sub-PRs done** (fill #99, hover #101, select this PR). Press = formally deferred per SS5; tracked as separate decision.

### Selector-mode plumbing for `hover` (2/4 of "expand `browser-do --verb` whitelist beyond `[click]`")

- [feat] `scripts/browser-hover.sh` gains `--selector CSS` flag — mutually exclusive with `--ref eN`. Mirrors `browser-click.sh` + `browser-fill.sh` (PR #99) precedent. Required for Phase 11 cache to dispatch hover (cache stores selectors, not snapshot-relative refs).
- [feat] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_hover` accepts `--ref|--selector` as target alias (mirrors its `tool_click` + `tool_fill` already-shipped patterns).
- [feat] `scripts/browser-do.sh` whitelist grows: `[click fill]` → `[click fill hover]`. End-to-end Phase 11 cache dispatch now works for `--verb hover --intent "..."` against chrome-devtools-mcp.
- [feat] **H2 — Adapter coverage = chrome-devtools-mcp only.** Other adapters (playwright-cli, playwright-lib, obscura) don't define `tool_hover` — `lib/router.sh::rule_hover_default` routes hover exclusively to chrome-devtools-mcp ("only cdt-mcp declares hover today"). Smaller scope than fill (2 adapters) — only one to update.
- [feat] **H3 — Bridge unchanged.** chrome-devtools-mcp's `_drive hover "${target}"` shells the target string to the bridge; bridge already accepts target strings for click without modification (PR #99 didn't require bridge changes). Same handling expected for hover.
- [internal] `tests/browser-hover.bats` gains 3 cases (total 8): `--dry-run --selector` accepts selector + summary carries it · `--selector` + `--ref` mutually exclusive → exit 2 · neither `--selector` nor `--ref` → exit 2 with "selector" in message.
- [internal] `tests/browser-do.bats` gains 1 case (total 34): `--verb hover` whitelist accepted; cache hit dispatches via `BROWSER_DO_DISPATCH_OVERRIDE` mock (avoids depending on chrome-devtools-mcp daemon stub for verb-acceptance test).
- [docs] `docs/superpowers/plans/2026-05-10-selector-mode-hover.md` — phase plan with locked decisions H1–H3.

**Sub-scope (this PR):**
- **No additional adapter coverage** (H2; only chrome-devtools-mcp defines `tool_hover` — other adapters' addition is a separate follow-up if hover routing ever expands).
- **No press/select selector-mode plumbing** — separate sub-PRs of the same parent task. This PR is just `hover`.
- **No new privacy canary** — hover doesn't ingest secrets; no AP-7 surface.
- **No route-rule changes**.

`browser-do --verb` whitelist now `[click fill hover]`; expands further as press/select gain selector-mode plumbing in follow-up PRs (2 of 4 verbs done).

### Selector-mode plumbing for `fill` (1/4 of "expand `browser-do --verb` whitelist beyond `[click]`")

- [feat] `scripts/browser-fill.sh` gains `--selector CSS` flag — mutually exclusive with `--ref eN`. Mirrors `browser-click.sh`'s precedent. Required for Phase 11 cache to dispatch fill (cache stores selectors, not snapshot-relative refs).
- [feat] `scripts/lib/tool/playwright-cli.sh::tool_fill` accepts `--ref|--selector` as target alias (mirrors `tool_click`'s already-shipped pattern).
- [feat] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_fill` same — `--ref|--selector` alias.
- [feat] `scripts/browser-do.sh` whitelist grows: `[click]` → `[click fill]`. End-to-end Phase 11 cache dispatch now works for `--verb fill --intent "..."` against playwright-cli + chrome-devtools-mcp adapters.
- [feat] `--text` and `--secret-stdin` semantics unchanged. Privacy invariants from AP-7 (secret-not-on-argv via `--secret-stdin`) preserved.
- [internal] `tests/browser-fill.bats` gains 3 cases (total 9): `--selector` passes selector to adapter as target · `--selector` + `--ref` mutually exclusive → exit 2 · neither `--selector` nor `--ref` → exit 2 with "selector" in message.
- [internal] `tests/browser-do.bats` gains 1 case (total 33): `--verb fill --intent` cache hit dispatches stub-fill with `--selector $cached --text VALUE`.
- [internal] new `tests/fixtures/playwright-cli/3b7305b0…json` — argv-hash fixture for `["fill","input.email","alice@example.com"]`.
- [docs] `docs/superpowers/plans/2026-05-10-selector-mode-fill.md` — phase plan with locked decisions S1–S5.

**Sub-scope (this PR):**
- **No playwright-lib `--selector` plumbing** (S2). The driver's `runFill` + IPC `case 'fill':` handler currently do refMap lookups only; adding `--selector` requires IPC schema changes + parallel updates to click for symmetry. Independent PR; coordinate fill + click together to keep IPC schema bumps coherent. **playwright-lib doesn't currently support `--selector` for click either** — this PR doesn't make it worse.
- **No hover/press/select selector-mode plumbing** — separate sub-PRs of the same parent task. This PR is just `fill`.
- **No new privacy canary** — fill's existing AP-7 canary covers `--secret-stdin`; `--selector` is structural (CSS string), not a credential channel.
- **No route-rule changes** — routing picks adapter same as before; flag parsing happens after pick. If routing picks playwright-lib (e.g. with `BROWSER_SKILL_STORAGE_STATE` set), `--selector` falls through to the driver and exits 2 ("--ref required"). Workaround: `--tool=playwright-cli` explicitly.

User-facing verb count unchanged. `browser-do --verb` whitelist now `[click fill]`; expands further as hover/press/select gain selector-mode plumbing in follow-up PRs.

### Phase 11 part 2-ii — `browser-do propose` (CLOSES Phase 11 part 2)

- [feat] new `browser-do propose [--site NAME] [--threshold N] [--url URL ...]` sub-mode — auto-cluster URL pattern detection. Reads URLs from `--url` args + stdin (one per line; `^#` comments + blanks ignored); clusters by templated pathname; emits `_kind:proposal` events for clusters meeting threshold AND not already in `patterns.json`.
- [feat] **C1 — Pure compute, no new persistence.** Agent owns URL collection. NO `recent_urls.jsonl` or other observation log. Composable with shell pipes (`tac history.log | propose`); active observation deferred to a future enhancement.
- [feat] **C2 — Heuristic scope = numeric + UUID only for v1.** Numeric segment (`^[0-9]+$`) → `:id`. UUID segment (8-4-4-4-12 hex) → `:uuid`. Slug heuristic deferred (too high-entropy → false-positive prone).
- [feat] **C3 — Threshold default `N=3`** (smallest count justifying generalization); configurable via `--threshold N`. Lower = more proposals + noise; higher = miss real patterns.
- [feat] **C4 — Suppress already-known patterns.** Skip proposing URL patterns that are already in `<site>/patterns.json` (any archetype). Prevents re-emitting patterns the user already accepted; keeps the verb pipe-friendly. Pattern-equivalence canonicalization (`/devices/:id` vs `/devices/:deviceId`) deferred.
- [feat] **C5 — Always emit proposal events; never auto-record.** Agent decides whether to call `record --pattern X --archetype Y` to land the proposal. Avoids surprise pattern landings + reviewable agent behavior.
- [feat] **C6 — Always exits 0.** Proposing zero clusters is not an error — it's a valid result ("no patterns worth proposing yet"). Exit 0 + summary `proposals:0`. Agents pipe through `jq` to act on `_kind:proposal` events.
- [feat] **C7 — Site context resolution** mirrors existing verbs: `--site NAME` flag wins → `current_get` fallback → empty current dies `EXIT_USAGE_ERROR`.
- [feat] new `scripts/lib/node/url-pattern-cluster.mjs` — pure-compute URL templating helper (mirrors 1-i `url-pattern-resolver.mjs` precedent — keeps URL parsing in node, not bash regex). Reads `{urls:[...]}` from stdin; writes `{clusters:[{templated, urls, count}]}` to stdout. Emits clusters only where templated form differs from at least one constituent URL's pathname (filters single-segment-no-template noise).
- [internal] `tests/browser-do.bats` gains 8 cases (total 32): 3 numeric URLs → `/:id` proposal · 3 UUID URLs → `/:uuid` proposal · below threshold (2 URLs) → 0 proposals · mixed unrelated → 0 proposals · already-known pattern → suppressed · `--threshold 5` override · stdin input · slugs don't cluster (negative case).
- [docs] `docs/superpowers/plans/2026-05-10-phase-11-part-2-ii-propose.md` — phase plan with locked decisions C1–C7.

**Sub-scope (11-2-ii):**
- **No persistent observation log** — agent owns URL collection (C1).
- **No slug heuristic** — too high-entropy for v1 (C2).
- **No auto-record on proposal** — agent must explicitly call `record` (C5).
- **No pattern-equivalence canonicalization** — distinct `:id` vs `:itemId` are separate (C4 future refinement).
- **No cross-site clustering** — strict per-site boundary (parent design doc §12).
- **No proposal ranking by frequency** — emitted in cluster-discovery order; agents that want ranking can `jq sort_by(.count)`.
- **No `--auto-record` flag** — defer.
- **No new lib helpers in `memory.sh`** — propose is self-contained in browser-do.sh + the node-helper.

**Phase 11 part 2 ✅ CLOSED.** Both sub-parts shipped:
1. Manual `--pattern` / `--archetype` flags in `--intent` mode (2-i)
2. Auto-cluster `propose` sub-mode (this PR — 2-ii)

**Phase 11 ✅ feature-complete for v1.** Future Phase 11 work is hardening (slug heuristic, auto-record, pattern-equivalence canonicalization, active observation) — all post-v1 backlog items.

### Phase 11 part 2-i — `--pattern` / `--archetype` flags in `browser-do --intent` mode

- [feat] `scripts/browser-do.sh --intent` gains two new optional flags:
  - `--pattern '/devices/:id'` — explicit URL pattern; archetype-id derived via `_derive_archetype_id` (reuses 1-ii helper). Skips URL→archetype lookup.
  - `--archetype devices-id` — explicit archetype-id; bypasses both URL lookup and pattern derivation. Most-explicit-wins.
- [feat] **R1 — Resolution priority (most-explicit-wins):** `--archetype NAME` > `--pattern PAT` > `--url URL` > none → existing `cache_miss reason:no_pattern_for_url` (backwards-compat preserved). All three flags optional + independently overrideable.
- [feat] **R2 — `--archetype` honors `assert_safe_name`** (constrained to `^[A-Za-z0-9_-]+$`); mirrors `record --archetype` 1-ii behavior. Consistent treatment across sub-modes.
- [feat] **R3 — `--pattern` is read-side only** — does NOT call `memory_record_pattern`. Decouples explicit-pattern lookup from cache persistence; `record` remains the sole pattern-writing path.
- [feat] **R4/R5 — No new `cache_miss` reason variants.** Nonexistent `--archetype NAME` → falls through to `cache_miss reason:intent_not_cached` (matches 1-iii D3 disabled-vs-never-cached precedent: agent response identical → no behavior gain from distinguishing).
- [feat] Symmetry with `record` sub-mode: `record --pattern` + `record --archetype` already shipped in 1-ii. This PR makes `--intent` accept the same flags.
- [internal] `tests/browser-do.bats` gains 5 cases (total 24): `--intent --pattern` works without `--url` · `--intent --archetype` direct lookup · `--archetype` wins over `--pattern` (most-explicit) · `--pattern` wins over `--url` (skips `memory_resolve_archetype`) · missing all three preserves `cache_miss reason:no_pattern_for_url` (backwards-compat).
- [docs] `docs/superpowers/plans/2026-05-10-phase-11-part-2-i-pattern-flag.md` — phase plan with locked decisions R1–R5.

**Sub-scope (11-2-i):**
- **No auto-cluster pattern detection** — that's 11-2-ii.
- **No `--pattern` write-side change** — `record --pattern` already supported (1-ii); this PR is read-side only (R3).
- **No new `cache_miss` reason variants** (R4).
- **No selector-mode plumbing for fill/hover/press/select** — independent prerequisite; tracked as separate follow-up.
- **No multi-pattern fallback** — caller passes ONE pattern; if it doesn't match, no auto-fallback to URL-derive. Single-path resolution per call.
- **No opportunistic `memory_record_pattern` from `--intent --pattern`** (R3); revisit if explicit-pattern users find themselves calling `record` redundantly.

User-facing verb count unchanged. Phase 11 part 2 in flight — 1/2 sub-parts shipped (manual flag; auto-cluster queued).

### Recipe — `cache-write-security.md` (codifies Phase 11 part 1 cache-write contract)

- [docs] new `references/recipes/cache-write-security.md` — codifies the five cache-write rules established across Phase 11 part 1's three substantive PRs (1-i lib + 1-ii verb + 1-iii self-heal):
  1. **Whitelist the cache-write surface** — never accept caller-supplied verb names without an explicit constant whitelist; defends against typo-dispatch + accidental dispatch of credential-handling verbs.
  2. **Refuse cache writes containing credential sentinels** — fast-fail with `EXIT_BLOCKLIST_REJECTED (28)` when intent/selector contains `PASSWORD-CANARY`; not a real secret detector but enforces a refusal codepath + gives bats a regression-safety net.
  3. **Cache writes are best-effort** — never let cache-write failure taint the action's exit code; `warn:` to stderr only. Cache freshness < action correctness.
  4. **Self-heal failure-counting needs an exit-code whitelist** — only `EXIT_EMPTY_RESULT (11)` + `EXIT_ASSERTION_FAILED (13)` increment fail_count. Network/tool/timeout codes are environmental; counting them poisons the cache.
  5. **Lock the cache schema; don't store action-type** — keep `(intent, selector)` as the storage shape; caller passes `--verb` per call. Storing `verb` couples cache to verb-set evolution.
- Documents what to test (8-case template citing already-shipped bats placements at `tests/browser-do.bats::4,12,13,29,30,31,32` + `tests/memory.bats::2,13`), why a per-recipe contract beats per-PR vigilance, and "Don't" anti-patterns (no verbatim user values; no widening self-heal whitelist without rationale; no cross-site memory; no silent sentinel-strip).
- Cross-references `privacy-canary.md`, `path-security.md`, `anti-patterns-tool-extension.md` (AP-7), Phase 11 design doc §6/§12/§3, Phase 11 part 1 plan-docs.

**No code changes.** Pure-docs PR; bridges 1-iii closure to a permanent reference. Per Phase 11 design doc §6 ("ships AFTER Phase 11 part 1, not with it") — now unblocked since part 1 closed at PR #92.

### Phase 11 part 1-iii — self-heal loop (CLOSES Phase 11 part 1)

- [feat] `scripts/browser-do.sh --intent` gains **post-dispatch failure trigger.** When the dispatched verb exits with `EXIT_EMPTY_RESULT (11)` or `EXIT_ASSERTION_FAILED (13)`, `memory_record_failure` is invoked → `fail_count++` → `disabled:true` once `fail_count > 3` (H1 threshold from design doc). On the next invocation with the same intent, `memory_lookup` transparently skips the disabled entry → `cache_miss reason:intent_not_cached` → agent re-resolves + calls `record` → entry heals (selector overwritten + `fail_count:0` + `disabled:false`).
- [feat] **D1 — exit-code trigger whitelist:** only `EXIT_EMPTY_RESULT (11)` + `EXIT_ASSERTION_FAILED (13)` drive the failure counter. Network errors (30), tool crashes (42), timeouts (43) are **environmental** — they shouldn't poison the cache when the selector itself is fine. Likewise codes 0 (success), 2 (usage), 22 (session expired) are out of scope.
- [feat] `scripts/lib/memory.sh` `memory_record` gains **D2 — re-record heals disabled.** Existing-intent upsert path now resets `fail_count:0` + `disabled:false` (in addition to bumping `success_count` + `last_used`). Closes the self-heal loop at the storage layer; without this, a successfully re-resolved selector couldn't overwrite the prior disabled state.
- [feat] **D5 — best-effort failure recording.** Mirrors 1-ii's best-effort write-back. If `memory_record_failure` itself fails (disk full, perms), `warn:` to stderr; dispatched verb's exit code is forwarded unchanged. Cache-state freshness < action correctness.
- [feat] `summary_json` for `browser-do --intent` cache-hit path gains `self_heal_triggered:true|false` field for agent observability.
- [internal] `BROWSER_DO_DISPATCH_OVERRIDE` env hook (test-only; documented inline in `browser-do.sh`) — lets bats mock the dispatched verb's exit code by overriding the `scripts/browser-${verb}.sh` path resolution. Production callers never set it; invisible default.
- [internal] `tests/browser-do.bats` gains 4 cases (total 19): dispatched verb exits 11 → fail_count++; exits 13 → fail_count++; exits 30 (network) → fail_count NOT incremented; **end-to-end:** 4 dispatch failures → disabled → next lookup miss → record heals (selector new + fail_count:0 + disabled:false).
- [internal] `tests/memory.bats` gains 1 case (total 13): `memory_record` on existing disabled intent resets `fail_count:0` + `disabled:false` + bumps `success_count`. Tests the D2 contract directly at the lib layer.
- [docs] `docs/superpowers/plans/2026-05-10-phase-11-part-1-iii-self-heal.md` — phase plan with locked decisions D1–D5.

**Sub-scope (11-1-iii):**
- **No `reason:disabled` distinction in `cache_miss` event.** D3 — disabled is indistinguishable from "never cached" at the verb layer; agent response is identical (snapshot+pick+record).
- **No `--no-self-heal` opt-out flag.** Self-heal is the design intent.
- **No backoff between retries.** Each invocation independent.
- **No `self_heal_history[]` population.** Schema field exists; future audit-trail use case.
- **No automated re-resolution.** Skill stays model-agnostic — agent does the snapshot+pick+record cycle (same as 1-ii Q1).
- **No effect on cache-miss paths.** `memory_record_failure` only fires after a confirmed cache-hit-then-dispatch-failed sequence (D4).

**Phase 11 part 1 ✅ CLOSED.** All 3 sub-parts shipped:
1. `lib/memory.sh` foundation (1-i)
2. `browser-do` verb (1-ii)
3. Self-heal loop (this PR — 1-iii)

User-facing verb count unchanged (lib + verb tweaks; no new shell entry point). Phase 11 part 2 unblocked.

### Phase 11 part 1-ii — `browser-do` verb (cache lookup + dispatch + explicit write-back)

- [feat] new `scripts/browser-do.sh` — first user-visible memory feature. Two sub-modes:
  - `browser-do --verb VERB --intent "..." [--site NAME] [--url URL] [-- VERB_ARG ...]` — resolves archetype via `memory_resolve_archetype`; calls `memory_lookup` for cached selector. **Hit:** dispatches `bash scripts/browser-VERB.sh --selector "$cached" $extra_args` (forwards exit code; bumps `success_count` + `hit_count` best-effort). **Miss:** emits `_kind:cache_miss` event with `intent`, `archetype_id`, `reason`, `suggestion:"snapshot+pick+record"`; exits `EXIT_EMPTY_RESULT (11)` so agents can branch on it.
  - `browser-do record --intent "..." --selector "..." --url "..." [--site NAME] [--pattern PAT] [--archetype NAME]` — explicit write-back through `memory_record_pattern` + `memory_record`. Auto-derives `--pattern` from URL pathname (`s|/[0-9]+|/:id|g`); auto-derives `--archetype` from pattern (`devices/:id` → `devices-id`).
- [feat] **Skill stays model-agnostic:** no LLM call inside the verb. On miss, parent agent picks ref via its own snapshot+reasoning, then calls `record` to fill the cache.
- [security] **Privacy canary:** verb refuses to record if `--intent` OR `--selector` contains the literal sentinel `PASSWORD-CANARY`; exits `EXIT_BLOCKLIST_REJECTED (28)`. Backs the recipe-pattern privacy-canary tests; not a real secret-detector (entropy scanning is a future hardening pass).
- [feat] **`--verb` whitelist (defensive):** v1 = `[click]` only. Other selector-target verbs (`fill`, `hover`, `press`, `select`) currently take only `--ref eN` — refs are snapshot-relative and can't be cached across snapshots. They get added to the whitelist when adapter ABI gains selector-mode plumbing (a follow-up sub-part). Whitelist also blocks accidental dispatch of credential-handling verbs (`extract`, `audit`) and verbs that don't fit the lookup-by-intent model (`open`, `snapshot`, `assert`).
- [feat] **Best-effort cache write-back:** if `memory_record` / `memory_record_pattern` fails post-dispatch, the dispatched verb's exit code is forwarded unchanged; cache failure is logged via `warn:` to stderr only. Action correctness > cache freshness.
- [feat] **Site context resolution:** `--site NAME` flag wins; falls back to `current_get` (Phase 1); empty current → `EXIT_USAGE_ERROR`. Mirrors existing verbs.
- [feat] **No `memory_record_failure` invocation:** the storage primitive is in place from 11-1-i, but 11-1-ii does NOT wire it into the dispatch failure path — that's 11-1-iii's job (self-heal orchestration loop).
- [internal] new `tests/browser-do.bats` (15 cases) — cache-hit dispatch + `success_count` bump · cache-miss `no_pattern_for_url` · cache-miss `intent_not_cached` · `--verb` whitelist enforcement · `--site` required when no current · `--site` overrides current · record writes mode 0600 · record auto-derives pattern · `--pattern` override · `--archetype` override · canary in intent + selector (both refused) · missing `--intent` / `--selector` / `--url`.
- [internal] new `tests/fixtures/playwright-cli/6b0bbf75…json` — argv-hash fixture for `["click","button.delete"]`; reused by tests 1 + 6.
- [docs] `docs/superpowers/plans/2026-05-10-phase-11-part-1-ii-browser-do.md` — phase plan with locked decisions Q1–Q8.

**Sub-scope (11-1-ii):**
- **No self-heal loop** — `memory_record_failure` is not invoked from `browser-do`. Verb dispatch failure forwards the verb's exit code unmodified. 11-1-iii wires the failure path.
- **No LLM call** — skill stays model-agnostic.
- **No multi-verb intent dispatch** — `--verb VERB` is required and singular.
- **No `--auto-record` flag** — agent must explicitly call `record` after a successful manual resolution. Reduces accidental cache pollution.
- **No UUID/slug pattern derivation** — only `/[0-9]+/` segments. UUID detection in 11-2-ii.
- **No cache invalidation by age / TTL** — design doc §12 open-question; not for v1.
- **No cross-site memory consultation** — strict per-site boundary (design doc §12).
- **No `--verb fill/hover/press/select`** — these don't accept `--selector` yet; selector-mode plumbing is a follow-up sub-part.
- **No extra-args forwarding test** — implemented but not exercised in v1 because click takes no useful forwardable args. Test lands when fill/hover/press get `--selector` support.

User-facing verb count: 40 → **41** (`browser-do` is a new parent row).

### Phase 11 part 1-i — `lib/memory.sh` foundation (URL→archetype + interaction cache I/O)

- [feat] new `scripts/lib/memory.sh` — pure read/write API for the per-archetype selector cache (no verb integration yet — that's 11-1-ii). Public functions:
  - `memory_init_dir` — lazy-creates `${BROWSER_SKILL_HOME}/memory/` mode 0700; idempotent (mirrors Phase 7's captures/ + Phase 9-1-v's baselines.json precedent).
  - `memory_load_archetype <site> <archetype_id>` — echoes archetype JSON or empty.
  - `memory_save_archetype <site> <archetype_id> <json>` — atomic write mode 0600; per-site dir mode 0700 (mirror `lib/site.sh`).
  - `memory_lookup <site> <archetype_id> <intent>` — echoes cached selector or empty; skips `disabled:true` interactions.
  - `memory_record <site> <archetype_id> <intent> <selector>` — upsert: new intent → first_used+last_used+success_count:1; existing intent → success_count++ + last_used advances + first_used preserved.
  - `memory_record_failure <site> <archetype_id> <intent>` — increments fail_count; `fail_count > 3` sets `disabled:true` (H1 self-heal threshold; orchestration loop deferred to 11-1-iii).
  - `memory_record_pattern <site> <url_pattern> <archetype_id>` — upserts into `<site>/patterns.json`; idempotent on same `(pattern, archetype)` pair.
  - `memory_resolve_archetype <site> <url>` — first-match-wins archetype lookup via hand-rolled regex matcher; empty on miss.
- [feat] new `scripts/lib/node/url-pattern-resolver.mjs` — pathname-pattern → RegExp compiler (`:name` → `[^/]+`, `*` → `.*`). Reads `{patterns, url}` JSON on stdin; writes `{matched_pattern, archetype_id}` or `null` on stdout. **Deviation from design doc §3 U1 (URLPattern web standard):** the global `URLPattern` is only stable in Node 23.8+, and CI runners default to Node 20 until June 2026. The hand-rolled matcher keeps behavior deterministic across all Node versions and avoids the npm-polyfill cost; native `URLPattern` can replace it when CI baseline lifts.
- [feat] **Storage shape (frozen at v1, per design doc §4):**
  - `${BROWSER_SKILL_HOME}/memory/` mode 0700 (lazy-created)
  - `<site>/patterns.json` mode 0600 — `{schema_version:1, patterns:[{url_pattern, archetype_id, first_seen, last_seen, hit_count}]}`
  - `<site>/archetypes/<id>.json` mode 0600 — `{schema_version:1, archetype_id, url_pattern, first_seen, last_seen, use_count, interactions:[{intent, selector, first_used, last_used, success_count, fail_count, disabled, self_heal_history:[]}]}`
  - `[PERSONAL]` per parent spec §3.4 (selectors reveal user flows).
- [internal] new `tests/memory.bats` (12 cases) — init_dir mode 0700 + idempotent · save+load round-trip + per-site dir mode 0700 + archetype mode 0600 · lookup hit + miss + missing-archetype empty · record new + record existing-intent (success_count++ + first_used preserved) · record_failure under-threshold + at-threshold (disabled:true) · record_pattern mode 0600 + idempotent · resolve_archetype `/devices/:id` matches `/devices/123` + non-matching empty.
- [docs] `docs/superpowers/plans/2026-05-10-phase-11-part-1-i-memory-foundation.md` — phase plan with locked decisions M1+U1+E1+H1, storage shape v1, and acceptance criteria.

**Sub-scope (11-1-i):**
- **No `browser-do` verb integration** — that's 11-1-ii. This PR ships only the lib API; nothing executes against the cache yet.
- **No self-heal orchestration loop** (resolve → execute → mark-fail → re-resolve). Deferred to 11-1-iii. The `memory_record_failure` storage primitive lands here so 11-1-iii has the threshold mechanic in place.
- **No `_index.json` writes** — per design doc §4 ("best-effort/coalesced"). Lands when `browser-do` knows the cross-site picture.
- **No manual `--pattern` flag** (11-2-i) or auto-cluster pattern detection (11-2-ii).
- **No `cache-write-security.md` recipe** — per design doc §6, ships AFTER Phase 11 part 1.
- **No verb-level privacy canary** — wrong surface for the lib layer; lands with 11-1-ii.

User-facing verb count unchanged (lib-only PR; no new shell entry point).

### Phase 9 part 1-v — `history` + `baseline` (CLOSES Phase 9)

- [feat] new `scripts/browser-history.sh` — single verb with sub-modes (per locked decision H1):
  - `history list [--limit N]` — enumerate captures (newest-first by capture-id); emit one `history_row` event per capture + summary line with `total:N`.
  - `history show <capture-id>` — emit meta.json content (compacted via `jq -c`) + steps.jsonl per-step events. Nonexistent capture-id → `EXIT_USAGE_ERROR` with helpful message.
  - `history diff <id1> <id2>` — pair-wise per-step replay_diff events. **Reuses `flow_diff_steps` from 9-1-iv** (composition-over-ABI-extension pattern).
  - `history clear [--keep N] [--days D] [--not-baseline]` — manual prune. Folds in HANDOFF's "browser-clean.sh" follow-up (Phase 7 carry-over). **Always honors `meta.is_baseline:true` skip-rule** (per Phase 7 prune contract). `--keep N` keeps newest N; `--days D` keeps captures younger than D days; `--not-baseline` enables purging-only-non-baselines mode.
- [feat] new `scripts/browser-baseline.sh` — single verb with sub-modes (per locked decision H1):
  - `baseline save <capture-id> --as NAME` — sets `meta.is_baseline:true` on the capture (Phase 7's prune skip-rule already honors this; landed in 7-1-v as forward-compat for Phase 9; no new prune logic). Appends entry to `${BROWSER_SKILL_HOME}/baselines.json`.
  - `baseline list` — emit one `baseline_row` event per entry + summary line with `total:N`.
  - `baseline remove <NAME>` — clears `meta.is_baseline:false` AND splices the entry from baselines.json. **Does NOT delete the capture dir** (use `history clear` for that).
- [feat] **`baselines.json` schema (frozen at v1, per locked decision B1):**
  ```json
  {
    "schema_version": 1,
    "baselines": [
      {"name": "after-redesign", "capture_id": "042", "saved_at": "2026-05-10T12:34:56Z",
       "summary": {"verb": "flow", "flow_name": "create-user", "step_count": 5}}
    ]
  }
  ```
  Mode 0600; lazy-creation on first `baseline save` (mirrors Phase 7's `_index.json` + Phase 11's planned `memory/_index.json`). `[PERSONAL]` per parent spec §3.4.
- [internal] new `tests/history.bats` (8 cases) — `list` empty + 3-captures + --limit 2; `show` happy + nonexistent; `diff` two-identical-captures (all status_match:true); `clear` --keep 1 + --not-baseline (verifies Phase 7's prune skip-rule honors flag).
- [internal] new `tests/baseline.bats` (6 cases) — `save` writes mode 0600 + sets is_baseline:true; `save` missing --as → USAGE_ERROR; `save` nonexistent → USAGE_ERROR; `list` empty + 2-baselines; `remove` clears is_baseline + splices baselines.json + capture dir UNTOUCHED.
- [docs] `docs/superpowers/plans/2026-05-10-phase-09-part-1-v-history-and-baseline.md` — phase plan with locked decisions H1+H2+H3+B1+O1.

**Sub-scope (9-1-v):**
- **No `report --since "yesterday" --format markdown`** (parent spec verb 35) — defer to Phase 10+.
- **No `history diff` for non-flow captures** (only flow/replay captures have steps.jsonl).
- **No baseline-rename** — `baseline remove` + `baseline save` round-trip is the workaround.
- **No baseline-with-tags / baseline-with-notes** — v1 schema is name + capture_id + saved_at + summary only.
- **No history pagination beyond `--limit N`** — `--since DATE` flag accepted but not yet implemented (placeholder for Phase 10+).

**Phase 9 ✅ COMPLETE.** All 5 sub-parts shipped:
1. Declarative composition (9-1-i `flow run`)
2. Templating + assertion (9-1-ii `${refs.NAME}` + `assert`)
3. Recording (9-1-iii `flow record` + password canary)
4. Replay + structured diff (9-1-iv)
5. History + baseline management (this PR — 9-1-v)

User-facing verb count: 38 → 40 (`history` + `baseline` are new parent rows). Phase 9 closure note: `references/recipes/flow-record-secrets.md` recipe-doc remains as a tiny pure-docs follow-up.

Next phases per sequencing:
- Phase 10 — schema migration tooling
- Phase 11 — memory (per-archetype selector/action cache; design doc shipped, implementation queued AFTER Phase 9 — now unblocked)

### Phase 9 part 1-iv — `replay <id>` (re-execute capture's steps + structured diff)

- [feat] new `scripts/browser-replay.sh` — verb `replay <capture-id> [--strict] [--session NAME] [--dry-run]`. Loads `${CAPTURES_DIR}/<id>/meta.json` + `steps.jsonl`; re-dispatches each step via `flow_dispatch` (composes 9-1-i); writes a NEW capture with `replay_of` + `replay_match` fields. Per design doc §3 F5.
- [feat] `scripts/lib/flow.sh::flow_diff_steps` — new helper. Compares two step-event JSON lines from `steps.jsonl`; emits one `event:replay_diff` JSON on stdout. Returns 0 if both `.status` AND `.summary` match; 1 if either diverges. **Strips `.summary.duration_ms` before comparison** — timing always varies between runs and isn't a semantic difference. Per locked decision D4.
- [feat] **Per-step diff event shape:** `{event:"replay_diff", step_index, verb, status_match, old_status, new_status, output_match, output_diff}`. `output_diff` populated only when `output_match=false` — carries `{old, new}` summary objects.
- [feat] **Aggregate diff summary line:** `{event:"replay_diff_summary", old_capture_id, new_capture_id, total_steps, matched_steps, diverged_steps, replay_match}`. Emitted once per replay, after all per-step diff lines.
- [feat] **Status mapping (per locked decision D3):**
  - All steps match → `status:ok / replay_match:true / exit 0`
  - Mixed match/diverge → `status:partial / replay_match:false / exit 0`
  - All steps diverged → `status:error / exit non-zero`
  - **`--strict` flag**: ANY divergence → exit 13 (`EXIT_ASSERTION_FAILED`), matching `assert` verb's exit code (composability — CI scripts can grep for 13 across both verbs).
- [feat] **`replay_of` capture-chain (forward-only per locked decision D2)** — new capture's `meta.json` carries `replay_of: <original-capture-id>`. No two-way back-reference (the original capture is NOT mutated). Reverse lookup via grep when needed.
- [feat] `meta.json` schema additions: `replay_of`, `replay_match`, `total_steps`, `matched_steps`, `diverged_steps`. **All non-breaking** — no `schema_version` bump.
- [feat] **Mid-flow ref-harvest semantics also apply during replay** — `flow_dispatch` extracts `step.refs` from snapshot steps; replay's main loop populates FLOW_REFS for subsequent steps' `${refs.NAME}` resolution. Same code path as `flow run`.
- [feat] **Rejects non-flow captures** (e.g. `verb:snapshot`, `verb:inspect`) — only `verb:flow` and `verb:replay` captures carry `steps.jsonl`. Helpful error message.
- [feat] **`--dry-run` mode** — loads + prints planned step list (the original `steps.jsonl`); no execution; no new capture written.
- [feat] **`--session NAME`** — overrides original capture's session for the replay (e.g. replay against a fresh login). Optional.
- [internal] new `tests/replay.bats` (10 cases) — `flow_diff_steps` 3 cases (identical / status divergence / output divergence); `browser-replay.sh` 7 cases (missing-id / nonexistent-id / end-to-end happy-path with replay_of+replay_match / `--strict` divergence exit 13 / `--dry-run` no-side-effect / non-flow-capture rejection / per-step replay_diff event count).
- [docs] `docs/superpowers/plans/2026-05-10-phase-09-part-1-iv-replay.md` — phase plan with locked decisions D1+D2+D3+D4+R1.

**Sub-scope (9-1-iv):**
- **No per-aspect file diff** (console.json, network.har, screenshots). Deferred — needs per-file-type decisions (jq-diff for JSON/HAR; sha256 for screenshots) AND most flow runs don't have per-aspect files attached.
- **No two-way capture chain** (forward-only `replay_of`; no `replayed_by` back-reference).
- **No replay-of-replay-of-replay tracking** (each replay's `replay_of` points back one level only).
- **No `--diff-format` flag** (v1 emits one fixed shape; future iteration if user demand surfaces).
- **No replay-of-non-flow captures** — only consumes `verb:flow` / `verb:replay` captures (steps.jsonl is the input; non-flow captures don't have it).
- **No `history` / `baseline`** (9-1-v).

**Phase 9 progress: 4 of 5 sub-parts shipped.** Remaining: 9-1-v (history + baseline → CLOSES Phase 9). Phase 9 closure ~1-2 PRs away.

### Phase 9 part 1-iii — `flow record` (codegen wrapper + JS→YAML transformer + password canary)

- [feat] `scripts/browser-flow.sh::record` — new sub-mode alongside existing `run`. Usage: `bash scripts/browser-flow.sh record --url URL --out FILE [--name NAME] [--tool TOOL]`. Spawns `playwright codegen --target javascript <URL>`; captures emitted JS; transforms to flow YAML; writes `${OUT}` mode 0600. Per locked decisions:
  - **W1 — recorder rejects `--tool obscura`** (codegen targets Playwright/Chrome; obscura's stateless one-shot model has no interactive recording surface). Helpful error message.
  - **O1 — `--out FILE` REQUIRED** (no default location; recorded flows are personal artifacts; user opting-in is friction-by-design per `creds-show --reveal` precedent).
  - **Path security** — realpath canonicalize on `--out`; sensitive-pattern reject (`/.ssh/`, `/.aws/`, `/.gnupg/`, `/.netrc`, `/private_key*`, `/id_rsa*`, `/id_ed25519*`). Mirrors `references/recipes/path-security.md`.
- [feat] new `scripts/lib/flow_record.sh` — three-fn library:
  - `flow_record_transform <out-name>` — pure function: reads codegen JS on stdin; emits flow YAML on stdout. Per locked decision F6-a, regex-based mapper for 6 codegen patterns (`page.goto` / `getByRole(...).click()` / `getByRole(...).fill()` / `getByLabel(...).click()` / `getByLabel(...).fill()` / `locator(CSS).click()` / `locator(CSS).fill()`). Auto-inserts `- snapshot: {}` step before any step that uses `${refs.X}`, deduplicating consecutive snapshots.
  - `flow_record_detect_password <name>` — case-insensitive substring match on `password`. Returns 0 if match. Per locked decision S1: any name containing "password" (case-insensitive) is treated as a password field.
  - `flow_record_emit_step <verb> <inline-args-yaml>` — helper that prints `  - <verb>: <args>` step lines.
- [security] **Privacy canary on recorder write side.** When the transformer encounters `getByRole(... name: 'X' ...).fill('VAL')` AND `X` matches `/password/i`, it writes `${secrets.password}` placeholder INSTEAD of `VAL`. The literal value is **dropped entirely** — never written to disk. Stderr audit line per redaction: `flow record: redacted password field "X" → ${secrets.password} placeholder`. Per locked decision S1; rejected: S2 (strict `input[type=password]` only — codegen rarely emits underlying input type), S3 (no detection — security regression).
- [security] **Privacy canary test** (bats case 7): fixture `with-password.codegen.js` carries literal "PWD-CANARY-9-1-iii"; transformer output MUST NOT contain that string. Belt-and-suspenders: any "PWD-CANARY" substring leak fails the test. Same enforcement shape as Phase 7's `--unsanitized` audit canaries.
- [feat] `flow_record_transform` exposes globals `FLOW_RECORD_PASSWORD_REDACTIONS` + `FLOW_RECORD_STEP_COUNT` for callers to surface in summary lines. `browser-flow.sh::record` emits both in the summary line: `password_redactions: N / step_count: M`.
- [feat] **Out-of-scope codegen patterns gracefully skipped** — XPath selectors emit `# TODO(flow record): unsupported xpath selector — <line>` comment and skip; `waitForLoadState` and `storageState` (codegen's session-save) silently dropped (the latter is replaced by flow.yaml's `session: NAME` field).
- [internal] new `tests/flow-record.bats` (12 cases) — `flow_record_detect_password` 4 cases (Email no-match / Password match / lowercase match / substring match); `flow_record_transform` 5 cases (simple-fixture shape + password-placeholder + privacy canary + xpath skip + audit line); `browser-flow.sh record` 3 cases (--tool obscura rejected / missing --out USAGE_ERROR / mock-codegen wrapper writes file mode 0600 + correct summary).
- [internal] new `tests/fixtures/flow-record/` — 3 fixtures: `simple.codegen.js` (3 actions: goto + fill + click); `with-password.codegen.js` (includes literal canary "PWD-CANARY-9-1-iii"); `with-xpath.codegen.js` (XPath selector to test skip-with-comment).
- [internal] new `tests/stubs/playwright-codegen-mock` — minimal stub binary that emits a fixed codegen-style JS payload on stdout. Wired via `PLAYWRIGHT_CODEGEN_BIN` env var so the wrapper-smoke test doesn't need real Playwright.
- [docs] `docs/superpowers/plans/2026-05-10-phase-09-part-1-iii-flow-record.md` — phase plan with locked decisions F6-a + S1 + W1 + O1 + the 6 codegen patterns + out-of-scope mappings + the 4 sub-scope categories.

**Sub-scope (9-1-iii):**
- **No AST-based parser** — regex mapper only. Limits documented in plan-doc + cheatsheet (future).
- **No support for codegen `--target` other than `javascript`** — Python/Java/etc. emit different JS-like syntax. v1 is JS-only.
- **No secrets-management UI** — `${secrets.password}` is a literal placeholder; user wires up resolution via `--var password=X` at flow-run time. (Future iteration: pull from `~/.browser-skill/credentials/`.)
- **No round-trip validation** — recorder writes; user can run. v1 doesn't auto-run the recorded flow to verify correctness. (Future iteration: `flow record --validate` flag.)
- **No re-recording / merge** — if the user wants to extend an existing flow, they must hand-edit. v1 is greenfield-only.
- **No env-var → ${secrets.X} pull-through** — users who want session-token recording have to manually craft.
- **No `--site SITE` resolution** — `--url URL` is required (or `--site` is accepted but ignored in v1). Site-base-URL resolution deferred.

**Phase 9 progress: 3 of 5 sub-parts shipped.** Remaining: 9-1-iv (replay + diff), 9-1-v (history + baseline → CLOSES Phase 9). New recipe candidate post-9-1-iii: `references/recipes/flow-record-secrets.md` — codifies the password-detection + ${secrets.X} placeholder pattern (per design doc §8).

### Phase 9 part 1-ii — `${refs.NAME}` resolution + `assert` step

- [feat] `scripts/lib/flow.sh::flow_apply_vars` — `${refs.NAME}` no longer literal-pass-through (was the deferred behavior in 9-1-i). Resolves via global `FLOW_REFS` assoc array (text → ref). Missing ref → `EXIT_USAGE_ERROR` with helpful message ("no snapshot has surfaced \"X\" — add a snapshot step first OR check the accessible name"). Per design doc §3 F3 fail-loud contract.
- [feat] `flow_apply_vars` gains second arg `refs-mode` (default `strict`; alternative `skip`). `--dry-run` mode passes `skip` since no snapshot has actually run; `${refs.X}` stays literal in dry-run output. Real-run uses `strict`.
- [feat] `scripts/lib/flow.sh::flow_dispatch` — for `verb: snapshot` steps, scans captured stdout for `event:snapshot` line carrying `refs[]` array; attaches as `refs` field on the step-event JSON. Other verbs: `refs: null`. Per locked decision R1 (parse the snapshot verb's stdout; rejected R2 read-from-capture-file).
- [feat] `scripts/browser-flow.sh` main loop — restructured to substitute per-step at execution time (was upfront accumulation in 9-1-i). After each step-event, harvests `step.refs` into global `FLOW_REFS` (latest-snapshot-wins per locked decision R3 — replaces FLOW_REFS wholesale; rejected accumulate-mode). Substitution failures abort the flow; surface as a step-event with `var/ref substitution failed` error.
- [feat] new `scripts/browser-assert.sh` — verify-style assertion verb. Usage: `bash scripts/browser-assert.sh --selector CSS --text-contains TEXT [--site NAME] [--tool NAME] [--dry-run]`. Thin wrapper over `bash scripts/browser-extract.sh --selector CSS` (subprocess; routes through router). Bash-side compares the extracted text against `--text-contains` predicate. Returns 0 (ok) / 13 `EXIT_ASSERTION_FAILED` (predicate failed; emits `expected` + `got` fields) / 2 (`EXIT_USAGE_ERROR`) / 1 (extract subprocess failed). **NO new tool_assert function on adapters** per locked decision A1 — composition over ABI extension.
- [internal] `tests/flow-runner.bats` (+5 cases, total 17) — `flow_apply_vars` resolves ref via FLOW_REFS; missing ref errors loudly; `flow_dispatch` extracts refs[] from snapshot event line into step.refs; end-to-end with-refs flow resolves `${refs.Sign in}` to `e2` via the stub fixture; two-snapshots flow demonstrates latest-wins semantics; missing-ref flow exits non-zero with helpful message.
- [internal] new `tests/browser-assert.bats` (5 cases) — missing `--selector` USAGE_ERROR; missing `--text-contains` USAGE_ERROR; `--dry-run` plan + exit 0; predicate matches stub fixture (`Welcome` / `Hello`) → status:ok exit 0; predicate fails → status:error exit 13 + `expected:`/`got:` fields.
- [internal] new fixtures: `tests/fixtures/flows/with-refs.flow.yaml` (snapshot + fill ${refs.Sign in}); `tests/fixtures/flows/two-snapshots.flow.yaml` (latest-wins exercise); `tests/fixtures/flows/missing-ref.flow.yaml` (fail-loud exercise).
- [internal] removed `tests/fixtures/flows/refs-passthrough.flow.yaml` — tested the now-obsolete literal-pass-through behavior from 9-1-i.
- [docs] `docs/superpowers/plans/2026-05-10-phase-09-part-1-ii-refs-and-assert.md` — phase plan with locked decisions R1+R2+R3+R4+A1.

**Behavior change from 9-1-i:** flows that previously relied on `${refs.NAME}` passing through as literal strings will now either resolve via FLOW_REFS or fail-loud. No backward-compat shim — the literal-pass-through was explicitly documented as 9-1-i deferred behavior.

**Sub-scope (9-1-ii):**
- **No `--text-regex` or `--text-equals` predicate** — only `--text-contains` in v1. Future iteration if user demand surfaces.
- **No `--selector-count-eq N` predicate.**
- **No multi-snapshot accumulate mode** — latest-snapshot-wins per R3.
- **No name-match-with-fuzzy-toleration** — exact match per R2.
- **No `flow record`** (9-1-iii).
- **No `replay <id>`** (9-1-iv).
- **No `history` / `baseline` operations** (9-1-v).

**Phase 9 progress: 2 of 5 sub-parts shipped.** Remaining: 9-1-iii (flow record), 9-1-iv (replay + diff), 9-1-v (history + baseline → CLOSES Phase 9).

### Phase 9 part 1-i — `flow run <file>` foundation (declarative YAML composition; first runnable end-to-end)

- [feat] new `scripts/browser-flow.sh` — entry point with `run` sub-mode. Usage: `bash scripts/browser-flow.sh run <flow-file> [--var key=val ...] [--dry-run]`. Path security: realpath canonicalization + sensitive-pattern reject (mirrors `references/recipes/path-security.md` shape from Phase 6 part 6 upload). `<flow-file>` resolves relative to CWD first, then `${BROWSER_SKILL_HOME}/flows/`.
- [feat] new `scripts/lib/flow.sh` — three-fn library API:
  - `flow_parse <file>` — parses the v1 YAML subset (flat top-level + flow-style step bodies); emits one `{_kind: "meta", name, session, vars}` line followed by per-step `{_kind: "step", step_index, verb, args}` lines on stdout. The `_kind`-tagged shape is **subshell-survivable** — callers can do `parsed="$(flow_parse FILE)"` and re-parse meta from the captured output, vs. the rejected pattern of relying on globals propagating across subshell boundaries.
  - `flow_apply_vars <step-json>` — substitutes `${var}` in step.args.* string values via global `FLOW_VARS` assoc array. **`${refs.NAME}` passes through literal** (resolution is 9-1-ii). Missing var → `EXIT_USAGE_ERROR`.
  - `flow_dispatch <step-json>` — translates `step.args` map → `bash scripts/browser-<verb>.sh --key val ...` invocation. Boolean `true` → bare flag (e.g. `dry-run: true` → `--dry-run`). Captures the verb's summary line + wraps in step-event JSON `{step_index, verb, args, status, duration_ms, exit_code, summary}`. **flow_dispatch returns 0 always** — failure surfaces in the step-event payload, not the return code, so flow execution can continue partially.
- [feat] **Capture composition (per design doc §3 F4):** one capture per flow run. `meta.json` carries `verb=flow / flow_name / step_count / successful_steps / failed_steps`. New `steps.jsonl` (mode 0600) is the chronological per-step event stream. Status mapping: ok (all steps OK) / partial (mixed) / error (all steps failed).
- [feat] `--var key=val` CLI flag — repeatable; overrides `vars:` defaults from the flow file. Late-binding (after parse, before substitution) so file-level defaults are reachable by users not passing CLI overrides.
- [feat] `--dry-run` mode — parses + validates + prints planned step list; does NOT execute or create captures.
- [internal] new `tests/flow-runner.bats` (12 cases) — `flow_parse` shape (3-step + missing fields + vars block); `flow_apply_vars` (substitute + missing-var + refs-passthrough); `flow_dispatch` (snapshot success path + unknown-verb 41-stub); `browser-flow.sh` end-to-end (dry-run / 3-step happy-path with capture writes / `--var` override).
- [internal] new `tests/fixtures/flows/` — 5 fixture flows: `simple.flow.yaml` (3 always-passing steps via `dry-run: true`), `with-vars.flow.yaml` (vars block + `${var}` substitution), `missing-name.flow.yaml` (parse-error case), `missing-steps.flow.yaml` (parse-error case), `refs-passthrough.flow.yaml` (`${refs.NAME}` literal pass-through).
- [docs] `docs/superpowers/plans/2026-05-10-phase-09-part-1-i-flow-run-foundation.md` — phase plan with v1 YAML subset constraints + sub-scope bounds + cross-references to design doc §3 F1-F4.

**Design choice — bash-side YAML parser (not node-helper).** Design doc §3 F1 mentioned "node helper with js-yaml" but that adds an npm dep ergonomically (Playwright is the only existing node dep). Bash-side parser handles the v1 subset (~80 LOC of pure shell) without new dependencies. Future iteration: if users hit the v1 subset's limits (multi-line strings, nested maps, list values in step bodies), swap in a node-helper or vendored YAML lib in a follow-up. Documented as a deliberate trade-off.

**Design choice — hyphenated YAML keys handled via indexed jq variables + bracket-string field accessors.** YAML keys can contain hyphens (e.g. `dry-run: true`); jq variable names cannot. Solution: emit `--argjson _k0`, `--argjson _k1`, ... (indexed) for values; build the filter with bracket notation `.["dry-run"] = $_k0` instead of `.dry-run = $_k0` (which jq parses as subtraction). Same root-cause class as the PR #73 jq-reserved-keyword fix — **decouple two name spaces that look the same but aren't**. Mirrors the `_v_` prefix trick from `summary_json`.

**Sub-scope (9-1-i):**
- **No `${refs.NAME}` resolution.** Literal pass-through. 9-1-ii adds resolution.
- **No `assert` step.** 9-1-ii adds the verb.
- **No `flow record`.** 9-1-iii.
- **No `replay <id>`.** 9-1-iv.
- **No `history` / `baseline` operations.** 9-1-v.
- **No nested-map step bodies.** Flow-style `{...}` inline only; multi-line block-style step bodies NOT supported in v1.
- **No multi-line strings or block scalars.** Single-line scalars only.
- **No env-var pull-through** in `${var}` syntax. Future enhancement if user-asked.

**Phase 9 progress: 1 of 5 sub-parts shipped.** Remaining: 9-1-ii (refs + assert), 9-1-iii (flow record), 9-1-iv (replay + diff), 9-1-v (history + baseline → CLOSES Phase 9).

### Phase 9 — flow runner design doc (declarative composition + record + replay + history; queued AFTER Phase 8)

- [docs] new `docs/superpowers/specs/2026-05-10-phase-09-flow-runner-design.md` — full design for the flow runner phase. Locks decisions F1+F2+F3+F4+F5+F6+F7+F8 (YAML format; single-key-map step shape; `${var}` + `${refs.NAME}` templating; one-capture-per-flow-run with `steps.jsonl`; structured replay diff; codegen-wrapped recorder; pure-read history; baseline as thin wrapper over Phase 7's `meta.is_baseline`). Five-sub-part split: 9-1-i (flow run foundation), 9-1-ii (refs + assert), 9-1-iii (flow record), 9-1-iv (replay + diff), 9-1-v (history + baseline → CLOSES Phase 9). Storage shape frozen at Phase 9 ship — adds `~/.browser-skill/flows/<name>.flow.yaml` + `baselines.json` + per-capture `steps.jsonl`. Schema additions to `meta.json` are non-breaking (no version bump).
- [docs] State-of-the-art (May 2026) check: parent spec §4.3 commits to YAML format; Playwright codegen is the practical recording mechanism; Phase 7's prune skip-rule on `is_baseline:true` already pre-allocates the baseline contract. New verbs counted: `flow run / record`, `assert`, `replay`, `history list/show/diff/clear`, `baseline save/list/remove` (~5 parent rows; user-facing verb count 34 → ~40).
- [docs] `docs/superpowers/HANDOFF.md` — Phase 9 sub-part table + storage shape + sequencing note (Phase 11 implementation comes AFTER Phase 9 per memory design doc §13). Workflow-expectations gain a "Design-doc-first-at-phase-boundary" pattern note (proven 3 times now: Phase 11 design PR #58, Phase 9 design this PR; pre-Phase-7 also followed by parent spec authorship).

**Why now (design only, no code):** Phase 9 implementation is queued as the next coding effort. Design doc ships first to lock decisions before code lands — same "design before code" cadence as Phase 11 design (`2026-05-08-phase-11-memory-design.md`) and the parent spec (`2026-04-27-browser-automation-skill-design.md`). HANDOFF + CHANGELOG updates fold into this PR per the pure-docs-fold exception to the alternation pattern (PRs #55, #58, this one).

**Cost compounding once shipped.** Saved flows are the third leg of the cost-reduction trio:
1. Model routing (skill → Sonnet) — ~3× cheaper per turn (already shipped).
2. Memory (Phase 11) — ~70% turns skipped on repeat actions; ~3× cheaper compounding (queued).
3. Saved flows (Phase 9, this design) — ~50× cheaper for any multi-step pattern that fits a flow.

Memory + flows compose: memory remembers individual action mappings; flows compose them into runnable sequences. After both ship, a returning user's typical session shrinks from N×LLM turns to 1×LLM turn (`flow run` invocation) + zero memory misses.

**Open follow-ups documented (decided during Phase 9 implementation, not now):** `assert` verb predicate set (text-equality / regex / JSON-path); recorder password detection by name pattern (in addition to `input[type=password]`); replay capture chain (one-way vs two-way back-reference); `history diff` support matrix for non-flow captures; `baselines.json` migration semantics for orphaned references; `flow record` against obscura adapter (rejected by recorder; documented limitation). All deferred until Phase 9 implementation surfaces a concrete need.

### Phase 8 part 2-i — router promotion for `--scrape` / `--stealth` (Path B → CLOSES Phase 8)

- [feat] `scripts/lib/router.sh` — two new precedence rules placed BEFORE `rule_extract_default`:
  - `rule_scrape_flag`: `--scrape` set → obscura (`--scrape requested (only obscura declares scrape backend)`).
  - `rule_stealth_flag`: `--stealth` set → obscura (`--stealth requested (only obscura declares stealth backend)`).
- [feat] **Auto-routing now works** — `bash scripts/browser-extract.sh --scrape --eval EXPR url1 url2` resolves to obscura without `--tool obscura`. Same for `--stealth`. `--tool obscura` still works as an explicit override.
- [internal] **Capability filter handles mismatched verbs cleanly** — e.g. `open --scrape` triggers `rule_scrape_flag` which picks obscura, but obscura doesn't declare `open` in `tool_capabilities`; capability filter rejects; router emits `warn: rule_scrape_flag picked obscura but it doesn't support verb=open; falling through` and walks to `rule_default_navigation` → playwright-cli. Documented in a dedicated bats case (`open --scrape falls through to playwright-cli`).
- [internal] Stale routing-comment cleanup in `scripts/lib/router.sh::rule_extract_default` and `scripts/browser-extract.sh` header — removed the "should route to obscura when it lands (Phase 8)" placeholder; now references the actual `rule_scrape_flag` / `rule_stealth_flag` rules.
- [internal] `tests/router.bats` (+5 cases) — `extract --scrape` → obscura; `extract --stealth` → obscura; `extract` (no flags) → cdt-mcp (default unchanged); `extract --selector .title` → cdt-mcp (no scrape/stealth in argv); `open --scrape` falls through to playwright-cli (capability-filter safety).
- [internal] `tests/routing-capability-sync.bats` (+3 cases) — drift checks: obscura declares `extract` in `tool_capabilities` (so `rule_scrape_flag` / `rule_stealth_flag` don't silently fail-over); `pick_tool extract --scrape` resolves cleanly; `pick_tool extract --stealth` resolves cleanly.
- [internal] `tests/browser-extract.bats` (+2 cases) — end-to-end auto-routing without `--tool obscura`: `--scrape --eval EXPR url1 url2` → ok summary with `tool:obscura / mode:scrape`; same for `--stealth`.
- [docs] `references/obscura-cheatsheet.md` — "When the router picks this adapter" table flipped both rows from "planned 8-2-i — pass `--tool obscura`" to "yes (default) — `rule_scrape_flag` / `rule_stealth_flag`". Override section reframed as "explicit override" rather than the only entry point.
- [docs] `docs/superpowers/plans/2026-05-10-phase-08-part-2-i-router-promotion.md` — phase plan with surface-change diff + capability-filter-safety reasoning.

**Sub-scope (8-2-i):**
- **No new verb-dispatch backend.** Only routing-rule changes; obscura's `tool_extract` already handles both modes (8-1-ii / 8-1-iii).
- **No `--site` support for `--scrape` / `--stealth`.** Same deferral as before.
- **No multi-URL stealth.** Still requires upstream support or adapter-side fan-out; deferred indefinitely.
- **No daemon-mode wiring** (`obscura serve --port 9222`). Still routed via future `playwright-lib --cdp-endpoint`, NOT this adapter.

**Phase 8 closure** ✅ **COMPLETE.** All 4 sub-parts shipped:
- 8-1-i: obscura adapter shell (Path A)
- 8-1-ii: `tool_extract --scrape` real-mode (`obscura scrape`)
- 8-1-iii: `tool_extract --stealth` real-mode (`obscura fetch --stealth --eval`)
- 8-2-i: router promotion (Path B; auto-routing for `--scrape` / `--stealth`)

**Adapter inventory after Phase 8:** chrome-devtools-mcp ✅ + playwright-cli ✅ + playwright-lib ✅ + obscura ✅ (4 of 4 real-mode where applicable; obscura's other 7 verb-dispatch fns remain 41-stub by design — one-shot extract-only).

Next phase: Phase 9 (flow runner — `flow record` / `flow run` / `replay` / `history`).

### `summary_json` — fix jq reserved-keyword collision (label, def, or, and, not, …)

- [fix] `scripts/lib/common.sh::summary_json` — internal jq variable names now prefixed with `_v_` so JSON field names that collide with jq's reserved keyword set (e.g. `label`, `def`, `or`, `and`, `not`, `if`, `then`, `else`, `end`, `as`, `reduce`, `foreach`, `try`, `catch`, `import`, `include`, `module`, `true`, `false`, `null`, `break`) no longer trigger `syntax error, unexpected label, expecting IDENT or __loc__` at the `--arg <key> X` → `$<key>` parser stage. **Output JSON shape unchanged** — the prefix lives only in the internal jq variable namespace; emitted field names stay caller-supplied.
- [internal] `tests/common.bats` (+1 case) — regression: `summary_json verb=test status=ok label=Big def=alpha or=beta and=gamma not=delta` returns valid JSON with all fields preserved.
- [fix] `tests/browser-select.bats:6` — pre-existing local-only failure (`--dry-run prints planned action and skips adapter`) now passes locally as a side effect. The test was tracked as "jq-version-dependent" since Phase 6; root cause turned out to be jq reserved-keyword collision, not version-specific behavior. The collision triggers on jq 1.6 (Ubuntu 22.04 apt + macOS Homebrew); the CI-vs-local divergence remains a curiosity (CI runs the same jq 1.6 but somehow tolerated the failing filter — possibly a build-flag / oniguruma-linkage difference between distros). Either way, the lib-level fix is robust across all jq builds.

**Why now:** the failing test sat quarantined-local since Phase 6. User asked to address it; the root cause turned out to be a one-line library fix, not a test-level workaround. Lands as its own PR (no Phase 8 alternation impact) so reviewers see a focused single-concern diff.

### Phase 8 part 1-iii — `tool_extract --stealth` real-mode (single-URL via `obscura fetch`)

- [feat] `scripts/lib/tool/obscura.sh::tool_extract` — second mode branch alongside the existing `--scrape` (8-1-ii). `--stealth` mode wraps `obscura fetch <url> --stealth --eval EXPR`; single URL; `--eval` required (without it `obscura fetch` dumps full HTML — too large for the streaming-event contract). Emits one `extract_stealth` event: `{event, url, eval}`. The `eval` field is **always a string** in this PR (obscura's `run_fetch` prints raw evaluated result on stdout — string unquoted, other JSON-encoded; disambiguating via heuristic parsing deferred). Callers needing typed results should `JSON.stringify` inside their `--eval` expression and parse downstream.
- [feat] `scripts/lib/tool/obscura.sh` — refactor: `tool_extract` is now a thin mode-dispatcher; the per-mode logic moved to internal helpers `_tool_extract_scrape` (existing) and `_tool_extract_stealth` (new). Mode mutual exclusion enforced (`--scrape + --stealth` returns 41).
- [feat] `scripts/browser-extract.sh` — new `--stealth` mode flag + single-URL validation + `--eval` requirement check. Mutually-exclusive with `--scrape` (verb script enforces). Status mapping: ok (adapter rc=0 + non-empty stdout) / empty (adapter rc=0 + empty stdout) / error (adapter rc≠0). New `--dry-run --stealth` plan path emits `mode:stealth / url:... / dry_run:true`.
- [internal] `tests/fixtures/obscura/8c83562f...json` — fixture for `fetch <url> --stealth --eval document.title` argv. Single-line raw payload (`Example Domain\n`) — NOT a wrapped JSON object, matching obscura `fetch --eval`'s actual output shape.
- [internal] `tests/obscura_adapter.bats` (+5 cases, total 29) — `tool_extract --stealth` event shape (`url`, `eval`); empty URL → exit 2; missing `--eval` → exit 2; `--scrape + --stealth` → exit 41 (mutually-exclusive); argv shape via STUB_LOG_FILE grep (`fetch + url + --stealth + --eval`; rejects spurious `--format` flag from `--scrape` mode).
- [internal] `tests/browser-extract.bats` (+5 cases, total 15) — end-to-end `--tool obscura --stealth --eval EXPR <url>` reaches adapter + emits 1 event + `status:ok / mode:stealth / url:...` summary; missing URL → `EXIT_USAGE_ERROR` with "--stealth requires exactly one URL"; missing `--eval` → `EXIT_USAGE_ERROR` with "--stealth requires --eval"; `--scrape + --stealth` → `EXIT_USAGE_ERROR` with "mutually exclusive"; `--stealth --dry-run` → plan with `mode:stealth / url:... / dry_run:true`.
- [docs] `references/obscura-cheatsheet.md` — "Stealth mode" section updated to reflect real-mode landing in 8-1-iii. New cheatsheet examples for string-eval and typed-eval (`JSON.stringify(...)`) usage. "When the router picks this adapter" table notes both `--scrape` and `--stealth` are real-mode-after-1-iii but still require `--tool obscura` until 8-2-i.
- [docs] `docs/superpowers/plans/2026-05-10-phase-08-part-1-iii-extract-stealth.md` — phase plan with upstream `run_fetch` shape divergence note (raw eval result on stdout, NOT wrapped JSON like `scrape`) + sub-scope bounds.

**Sub-scope (8-1-iii):**
- **No router promotion.** `--stealth` doesn't auto-route to obscura yet; user must pass `--tool obscura`. Promotion is 8-2-i (Path B).
- **No typed-eval parsing.** `eval` field always a string in this PR. Heuristic JSON-parse deferred.
- **No `--site` support for `--stealth`.** Same constraint as `--scrape`.
- **No `obscura fetch --dump html|text|links` modes.** Only `--eval`-based extraction supported.
- **No multi-URL stealth.** `obscura scrape` doesn't accept `--stealth` upstream (scrape uses worker subprocesses; stealth is a serve/fetch flag). Adapter-side fan-out via parallel `obscura fetch --stealth` calls deferred.
- **No `time_ms` field in the event.** Obscura `fetch` doesn't report timing; the verb-script's summary already carries end-to-end `duration_ms`. Adapter is a leaf — doesn't source `common.sh::now_ms`; doesn't fabricate timing.

**Adapter inventory after 8-1-iii:** chrome-devtools-mcp ✅ + playwright-cli ✅ + playwright-lib ✅ + **obscura** ⚠️ partial (1 verb-dispatch fn now real-mode for **two** modes — `tool_extract` handles both `--scrape` and `--stealth`; remaining 7 verb-dispatch fns are 41-stubs by design).

**Phase 8 progress: 3 of (3+) sub-parts shipped.** Remaining: 8-2-i (router promotion / Path B). Phase 8 closure ~1 PR away.

### Phase 8 part 1-ii — `tool_extract --scrape` real-mode (obscura backend; first real verb on the new adapter)

- [feat] `scripts/lib/tool/obscura.sh::tool_extract` — first real-mode verb backend on the obscura adapter. Wraps `obscura scrape u1 u2 ... [--eval EXPR] [--concurrency N] --format json`. Parses obscura's pretty-printed aggregate JSON dump (`{total_urls, concurrency, total_time_ms, avg_time_ms, results: [...]}` per `crates/obscura-cli/src/main.rs::run_parallel_scrape`); reshapes per-URL `.results[]` into one streaming `scrape_url` event line per URL. Per-result shape divergence handled by jq branching: success → `{event,url,title,eval,time_ms}`; error → `{event,url,error,time_ms}`. The `worker` field is internal (process index) and dropped from the event surface. **Direct jq emit** for events (bypasses `emit_event`) preserves the `eval` field's JSON typing — eval is `serde_json::Value` upstream, so it can be string/number/array/null/object; `emit_event`'s `key=value` shape can't carry arbitrary JSON values.
- [feat] `scripts/browser-extract.sh` — new `--scrape` mode flag + URL-list collection + `--concurrency N` pass-through. URLs are positional after `--scrape`; mode bypasses the require-selector-or-eval check. **Path A still:** `--scrape` requires `--tool obscura` in 8-1-ii; router promotion to default for `--scrape` is 8-2-i. Summary line emits `mode=scrape`, `total_urls`, `successful`, `failed`; status mapping = ok (all OK) / partial (mixed) / error (all failed or adapter rc≠0). New `--dry-run --scrape` plan path emits the planned action with URL count; skips the adapter.
- [feat] `tests/stubs/obscura` upgrade — promoted from `--version`-only mock to fixture-based stub mirroring `tests/stubs/playwright-cli`. Behavior: `--version` short-circuits (preserves doctor + install tests landed in 8-1-i); other invocations sha256-hash argv, look up `tests/fixtures/obscura/<sha>.json`, dump file to stdout + exit 0; missing-fixture emits an error line + exits 41. **`--version` short-circuit happens BEFORE STUB_LOG_FILE write** — doctor probes won't pollute argv-shape assertion logs in unrelated tests.
- [internal] new `tests/fixtures/obscura/` — three fixtures: `54234ff7...json` (3-URL success + eval); `e263bd9f...json` (3-URL mixed: 2 ok + 1 error); `7dc46f78...json` (2-URL no-eval; null eval values).
- [internal] `tests/obscura_adapter.bats` (+6 cases, total 24) — `tool_extract --scrape` with 3 URLs + eval emits 3 events with correct shape; mixed-results split into success/error events; empty URL list → exit 2; `--scrape` without `--eval` → events with `eval:null`; argv-shape via STUB_LOG_FILE grep (scrape subcommand + URLs + `--eval` + `--format json` all present); stub `--version` short-circuit doesn't touch STUB_LOG_FILE.
- [internal] `tests/browser-extract.bats` (+4 cases, total 10) — end-to-end `--tool obscura --scrape --eval EXPR u1 u2 u3` reaches adapter + emits 3 events + summary `status:ok / mode:scrape / total_urls:3 / successful:3 / failed:0`; mixed-results → `status:partial / successful:2 / failed:1`; `--scrape` with no URLs → `EXIT_USAGE_ERROR` with "--scrape requires at least one URL"; `--scrape --dry-run` → plan with `mode:scrape / total_urls:N / dry_run:true`.
- [docs] `docs/superpowers/plans/2026-05-10-phase-08-part-1-ii-extract-scrape.md` — phase plan with upstream JSON shape research (obscura `serde_json::to_string_pretty` output; per-result shape divergence; eval typing constraints) + skill output contract + sub-scope bounds.

**Sub-scope (8-1-ii):**
- **No `--stealth` mode.** That's 8-1-iii (wraps `obscura fetch <url> --stealth --eval EXPR`).
- **No router promotion.** `--scrape` doesn't auto-route to obscura yet; user must pass `--tool obscura`. Promotion is 8-2-i (Path B).
- **No `--selector` for `--scrape`.** Obscura's scrape command takes `--eval` only. `--selector` + `--scrape` combination not exercised; rejected naturally by the adapter.
- **No `--site` support for `--scrape`.** Scrape mode doesn't apply per-URL session storageState. Documented as a limitation.
- **No retention/capture-write integration.** Phase 7 capture pipeline composes with `inspect`; combining with `extract --scrape` deferred.

**Adapter inventory after 8-1-ii:** chrome-devtools-mcp ✅ + playwright-cli ✅ + playwright-lib ✅ + **obscura** ⚠️ partial (1 of 8 verb-dispatch fns now real-mode — `tool_extract --scrape`; remaining 7 are 41-stubs by design — obscura is intentionally one-shot extract-only).

**Phase 8 progress: 2 of (3+) sub-parts shipped.** Remaining: 8-1-iii (`--stealth`), 8-2-i (router promotion / Path B).

### Phase 8 part 1-i — obscura adapter shell (Path A "ship-without-promotion")

- [adapter] new `scripts/lib/tool/obscura.sh` — fourth tool adapter shell. Implements the Tool Adapter Extension Model contract from `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` §2: `tool_metadata` (name=`obscura`, abi_version=1, version_pin=`0.x`, cheatsheet_path), `tool_capabilities` (only `extract` declared with advisory flags `--scrape` / `--stealth` / `--eval` / `--selector`), `tool_doctor_check` (binary discovery + install hint), 8 verb-dispatch functions all returning `EXIT_TOOL_UNSUPPORTED_OP` (41). `tool_extract` is a stub in 8-1-i — real-mode `--scrape` lands in 8-1-ii, real-mode `--stealth` lands in 8-1-iii.
- [adapter] **Path A "ship-without-promotion"** per spec 2026-04-30 §4.4. **Zero edits to `scripts/lib/router.sh`.** Reachable via `--tool obscura` only. Promotion to default for `--scrape` / `--stealth` lives in a follow-up PR (8-2-i, Path B).
- [adapter] **One-shot lane only.** Obscura's two upstream modes are stateless `obscura fetch` / `obscura scrape` (mode 1) and CDP-server `obscura serve --port 9222` (mode 2). Mode 2 overlaps with `playwright-lib`'s CDP transport — adapter targets mode 1 exclusively. Mode 2 reaches users via a future `playwright-lib --cdp-endpoint` flag, NOT a separate adapter mode. Single-responsibility per adapter; no contributor mental-model split.
- [docs] new `references/obscura-cheatsheet.md` — when-router-picks / capabilities-declared / doctor / version-pin / override / modes / limitations / stealth-mode. Mirrors `playwright-cli-cheatsheet.md` shape.
- [docs] `references/tool-versions.md` + `SKILL.md` tools-table — both autogenerated by `scripts/regenerate-docs.sh all`. New `obscura` row at top of each (alphabetical sort).
- [docs] `docs/superpowers/plans/2026-05-09-phase-08-part-1-i-obscura-adapter-shell.md` — phase plan with research summary (obscura's two modes, the "mode 2 lives on playwright-lib" decision, Path A rationale).
- [internal] new `tests/obscura_adapter.bats` (18 cases) — file/readability; `tool_metadata` valid JSON + name-matches-filename + abi_version-matches-framework + version_pin/cheatsheet_path present; `tool_capabilities` valid JSON with `.verbs` + declares `extract` + does NOT declare `open`/`click`/`fill`/`snapshot` (lane boundary at the capability layer); `tool_doctor_check` valid JSON with `.ok` boolean; all 8 verb-dispatch functions defined; each verb returns 41 (8 cases). Mirrors `playwright-cli_adapter.bats` shape.
- [internal] **Lint passes at all three tiers** (static / dynamic / drift). Static lint validates required-function presence + no `cd` at file scope. Dynamic lint validates `tool_metadata.name` matches filename + `abi_version` matches framework. Drift lint validates regenerated docs are in sync + every adapter sources `scripts/lib/output.sh`.
- [internal] **`tests/routing-capability-sync.bats` unchanged + still green** — obscura is not referenced by any routing rule in 8-1-i, so the cap-sync drift check (every rule's named tool declares the verb it targets) is unaffected.
- [internal] `bash scripts/browser-doctor.sh` enumerates 4 adapters now (was 3). `adapters_ok:4` in summary line.

**Sub-scope (8-1-i):**
- **No real `tool_extract` backend.** That's 8-1-ii (`obscura scrape`) and 8-1-iii (`obscura fetch --stealth`).
- **No router.sh edit.** Promotion to default for `--scrape` / `--stealth` is 8-2-i (Path B).
- **No `obscura serve` daemon mode.** Reachable via future `playwright-lib --cdp-endpoint` flag, not this adapter.
- **No `--scrape` / `--stealth` flag plumbing in `browser-extract.sh`.** Adapter-level only this PR.
- **No fixtures / stub binary** under `tests/fixtures/obscura/` or `tests/stubs/obscura`. 8-1-ii adds them when the real verb backend lands.

**Phase 8 progress: 1 of (3+) sub-parts shipped.** Remaining: 8-1-ii (`tool_extract --scrape`), 8-1-iii (`tool_extract --stealth`), 8-2-i (router promotion / Path B). Adapter inventory now: chrome-devtools-mcp ✅ + playwright-cli ✅ + playwright-lib ✅ + obscura ⚠️ (shell-only — verb backend in 8-1-ii / 8-1-iii).

### Phase 7 part 1-v — `capture_prune` retention/prune (Phase 7 COMPLETE — 5/5)

- [feat] new `scripts/lib/capture.sh::capture_prune` — auto-prune by count + age thresholds. Reads `${CONFIG_FILE}` (defaults `retention_count: 500`, `retention_days: 14` per parent spec §4.5). Walks `${CAPTURES_DIR}/*/meta.json`; computes age + count via `_capture_iso_to_epoch` (cross-platform GNU + BSD date parsing). Splices oldest-first while EITHER threshold exceeded. **Skip rules**: `meta.is_baseline:true` (Phase 8 forward-compat — never prune); `meta.status:"in_progress"` (in-flight; never prune). After prune: recomputes `_index.json` (count, latest, total_bytes); `next_id` stays monotonic (never decremented). Emits one `warn` line per pruned capture.
- [feat] `scripts/lib/capture.sh::capture_finish` — calls `capture_prune` at end. Auto-prune on every successful capture finalize. Idempotent.
- [feat] `scripts/lib/common.sh::init_paths` — exports `CONFIG_FILE="${BROWSER_SKILL_HOME}/config.json"` alongside existing path exports.
- [feat] `install.sh::create_state_dir` — seeds default `config.json` (mode 0600) on fresh install if absent. **Idempotent — never overwrites an existing user-edited config.**
- [security] **Baseline-protection lands now** even though Phase 8 ships baselines. `meta.is_baseline:true` entries skipped during prune. Logic dormant until Phase 8 sets the flag; lands here to avoid retroactive contract changes when baselines arrive.
- [security] **In-flight protection** — captures with `meta.status:"in_progress"` (mid-finalize) never pruned. Defends against the rare race where a long-running capture sits in flight while another verb completes + auto-prunes.
- [security] **Cross-platform age parsing.** `_capture_iso_to_epoch` tries GNU `date -d ...` first (Linux + coreutils-on-Mac), falls back to BSD `date -j -f '%Y-%m-%dT%H:%M:%SZ' ...`, defaults to epoch 0 on parse failure. Same precedent as `stat -c '%a' || stat -f '%Lp'` already in capture.sh.
- [internal] `tests/capture.bats` (+8 cases) — prune-by-count threshold; prune-by-age threshold; no-op-under-threshold; idempotent (two consecutive calls); baseline-skip (oldest-but-baseline preserved, oldest non-baseline pruned); in-flight-skip (in_progress preserved); `_index.json` correctness post-prune (count + latest recomputed; next_id monotonic); missing-config defaults applied. Test helpers `_seed_config` + `_seed_capture` author meta.json directly to drive deterministic age/baseline/status fixtures.
- [docs] `docs/superpowers/plans/2026-05-09-phase-07-part-1-v-capture-prune.md` — phase plan.

**Sub-scope (7-1-v):**
- **No `browser-clean.sh` verb.** Auto-prune covers the common case; manual force-prune (parent spec §3 verb #29) deferred as a follow-up.
- **No `warn_at_pct` near-threshold warning.** Field is read+written for forward-compat but no warn-on-90% logic. Lands as a follow-up if user demand surfaces.
- **No interactive prune confirmation.** Auto-prune is silent (just emits warn line per pruned capture). User can disable via `retention_count: 999999` if never-prune is preferred.
- **No prune-by-bytes.** Threshold is count + age only; `total_bytes` is informational.

**Phase 7 progress: 5 of 5 sub-parts shipped.** ✅ **Phase 7 COMPLETE.**

The capture pipeline now ships:
- 7-1-i: `lib/capture.sh` foundation — capture_init_dir / capture_start / capture_finish.
- 7-1-ii: `lib/sanitize.sh` — pure jq-function library (sanitize_har, sanitize_console).
- 7-1-iii: `inspect --capture` wire-up — first composition test for capture + sanitize; defense-in-depth (stdout sanitized too); 6-canary privacy regression suite.
- 7-1-iv: `--unsanitized` typed-phrase opt-out + `meta.sanitized` audit flag + doctor counter.
- 7-1-v: `capture_prune` retention/prune + baseline-protection forward-compat + cross-platform age parsing.

Next phase: Phase 8 (obscura adapter — first non-bridge tool implementation; ships a real backend behind the existing 4-adapter routing model).

### Phase 7 part 1-iv — `--unsanitized` typed-phrase opt-out + `meta.sanitized` audit flag + doctor counter

- [feat] `scripts/browser-inspect.sh` — accepts `--unsanitized` flag. **Strict typed-phrase confirmation required**: user must pipe (or type) `I want raw network/console data including auth tokens` (verbatim per parent spec §8.3) via stdin. Mismatch → `EXIT_USAGE_ERROR` with "confirmation mismatch"; capture aborted; no files written. Match → `sanitize_inspect_reply` skipped; raw console.json + network.har persisted; stdout output ALSO raw (consistent with disk).
- [feat] `scripts/lib/capture.sh::capture_finish` — accepts optional 2nd arg `sanitized` ∈ `{true, false}`. Default `true`. Writes `meta.json::sanitized` field (always present in v1+ schema). Field addition is non-breaking (default `true` matches sanitized-by-default contract); does not bump `schema_version`.
- [feat] `scripts/browser-doctor.sh` — captures sanitization counter. Walks `${CAPTURES_DIR}/*/meta.json`; reads `.sanitized` field; counts total + `sanitized:false`. Emits `captures: N total (sanitized:false: M)`. When M > 0: emits `warn` line listing capture IDs ("M capture(s) with sanitization disabled — review captures/004/, captures/009/"). Never increments `problems` (informational only).
- [security] **Strict equality on typed phrase** — no whitespace strip, no case-fold. Mirrors `creds-show --reveal` precedent. Friction-by-design; cannot be bypassed by `-y`/`--yes` shortcuts. Bats case asserts leading-whitespace mismatch fails (`" I want raw..."` ≠ `"I want raw..."`).
- [security] **Prompt to stderr, read from stdin.** Stdout stays JSON-contract-clean. Scripted use: `printf '%s\n' '<phrase>' | bash inspect.sh ... --unsanitized`. Interactive use: prompt visible on terminal, user types phrase, hits enter.
- [security] Default behavior unchanged — `--unsanitized` opt-in only. Existing 7-1-iii canary tests still green: sanitization-by-default contract preserved.
- [security] **`jq // operator gotcha avoided in doctor counter.** `// true` would have masked legit `sanitized:false` reads (jq's `//` fires on null OR false). Reads `.sanitized` raw and string-compares to `"false"`; missing field surfaces as `"null"` which correctly does NOT match. One-line gotcha; would have silently undermined the audit counter.
- [internal] `tests/browser-inspect.bats` (+5 cases) — typed-phrase mismatch error; correct phrase + canary preserved on disk; correct phrase + canary preserved on stdout; default `meta.sanitized=true`; leading-whitespace strict-equality mismatch.
- [internal] `tests/capture.bats` (+3 cases) — `capture_finish ok true` writes `sanitized=true`; `capture_finish ok false` writes `sanitized=false`; `capture_finish` (no args) defaults to `sanitized=true`.
- [internal] `tests/doctor.bats` (+2 cases) — doctor reports zero sanitized:false correctly (no warn); doctor warns when sanitized:false count > 0.
- [docs] `docs/superpowers/plans/2026-05-09-phase-07-part-1-iv-unsanitized-flag.md` — phase plan.

**Sub-scope (7-1-iv):**
- **No retention/prune.** That's 7-1-v (last Phase 7 sub-part).
- **No env var bypass for typed phrase.** Scripted use pipes via stdin; mirrors `creds-show --reveal`.
- **No `--unsanitized` on snapshot.** Snapshot's data isn't sanitization-relevant (refs only, no headers/cookies/URL params). Out of scope.
- **No retroactive backfill** for captures created pre-7-1-iv. Doctor reads missing `.sanitized` as `null` and treats null as sanitized=true (no warn).

**Phase 7 progress: 4 of 5 sub-parts shipped.** Remaining: 7-1-v (`capture_prune` + `_index.json` recompute + `~/.browser-skill/config.json` retention thresholds). Phase 7 closure ~1 PR away.

### Phase 7 part 1-iii — `inspect --capture` wire-up (capture + sanitize composition)

- [feat] `scripts/browser-inspect.sh` — opt-in `--capture` flag. When set, sandwiches `capture_start` / sanitize / per-aspect-file persistence / `capture_finish` around the adapter call. Persists `${CAPTURES_DIR}/NNN/console.json` (sanitized via `sanitize_console`) + `${CAPTURES_DIR}/NNN/network.har` (sanitized via `sanitize_har`, wrapped in HAR envelope) + `${CAPTURES_DIR}/NNN/meta.json`. `capture_id` joins the summary line. **Defense in depth: stdout output is ALSO sanitized** — single transformation, both sinks (stdout = agent transcript surface; same leak vector as disk).
- [feat] `scripts/lib/sanitize.sh::sanitize_inspect_reply` — new helper. Reads bridge's combined inspect reply on stdin; emits same shape with `.console_messages` + `.network_requests` sanitized in place. Non-sanitized fields (verb, tool, why, status, matches, screenshot_path, etc.) pass through untouched. Single function used for both stdout-side and disk-side sanitization.
- [security] **Privacy canary on the wire-up itself.** Test fixture (`tests/fixtures/chrome-devtools-mcp/d0fcae...json`) carries five distinct canary tokens — `HEADER-CANARY-7-1-iii`, `URL-CANARY-7-1-iii`, `SESS-CANARY-7-1-iii`, `NEW-CANARY-7-1-iii`, `PWD-CANARY-7-1-iii`, `TOK-CANARY-7-1-iii` — across Authorization header / URL api_key param / Cookie / Set-Cookie / console password / console token. Three new bats test cases assert NONE of these literal canaries appear in the persisted `console.json`/`network.har` on disk OR in stdout. Layered defense over the unit-tested `sanitize.sh`.
- [security] **Sanitize stdout, not just disk.** Parent spec §4.1 emphasizes disk sanitization (`captures/NNN/network.har`); 7-1-iii extends to stdout for the same content. Reasoning: streaming output is the agent's transcript and (potentially) `tee log.txt` / `script(1)` capture. Same leak vector as disk; same defense applied. `--unsanitized` opt-out arrives in 7-1-iv if/when users need raw debugging.
- [internal] new `tests/browser-inspect.bats` (+5 cases) — `--capture` writes 3 files + capture_id in summary; perms (700/600); privacy canary HEADER (Authorization + Cookie + Set-Cookie redacted); privacy canary URL (api_key=*** + raw value gone); privacy canary console (password + token field-value masked); without `--capture` no captures dir created.
- [internal] `tests/sanitize.bats` (+3 cases) — `sanitize_inspect_reply` direct unit tests: combined console + network sanitization in one pass; non-sanitized field passthrough; clean-input shape preservation.
- [internal] new `tests/fixtures/chrome-devtools-mcp/d0fcae777fd32c21edd55fca4e04d2b3130ea15124eac7f0de79613c080d1733.json` — bridge fixture for `inspect --capture-console --capture-network` argv. Contains rich content with sensitive headers + URL params + console messages (privacy-canary fodder).
- [docs] `docs/superpowers/plans/2026-05-08-phase-07-part-1-iii-inspect-capture-wireup.md` — phase plan.

**Sub-scope (7-1-iii):**
- **No `--unsanitized` flag.** Typed-phrase opt-out is 7-1-iv.
- **No `meta.sanitized:false` audit field.** 7-1-iv.
- **No retention/prune.** 7-1-v.
- **No screenshot persistence.** Existing `--screenshot` flag is orthogonal in this PR; revisit if user demand surfaces.
- **No HAR-shape adapter** for the bridge's flat `network_requests` array. Test fixture authors HAR-shape entries directly (Authorization headers + Set-Cookie response headers + api_key URL params). Real CDT-MCP shape may need adaptation; binding-hardening track.

**Phase 7 progress: 3 of 5 sub-parts shipped.** Remaining: 7-1-iv (--unsanitized + audit flag + doctor counter), 7-1-v (retention/prune + _index.json recompute + config.json thresholds).

### Phase 7 part 1-ii — `lib/sanitize.sh` (jq-function library; unit-tested in isolation)

- [feat] new `scripts/lib/sanitize.sh` — pure jq-function library. Two functions: `sanitize_har` (redacts Authorization / Cookie / X-API-Key / X-Auth-Token request headers + Set-Cookie / Authorization response headers + api_key / token / access_token / client_secret URL params per parent spec §8.3) and `sanitize_console` (masks password / secret / token field values inline in console message text). Header sentinel `***REDACTED***`; URL-param + console-field mask `***`. Pure stdin → stdout; no verb integration (that's 7-1-iii).
- [security] Header name match is case-insensitive (`ascii_downcase` in jq). URL-param sub() preserves the leading `?` or `&` separator + the param name; only the value is masked. Console field-value mask uses word-boundary regex `\\b<key>\\b\\s*[:=]\\s*\\S+` so neighbouring tokens like `mypassword: hunter2` only match the `password:` segment, not the prefix `my`.
- [security] Idempotent — running `sanitize_har` (or `sanitize_console`) twice returns the same output as running once. Important for layered pipelines that may apply sanitization at multiple stages without compounding redaction.
- [internal] new `tests/sanitize.bats` (15 cases) — Authorization / Cookie / X-API-Key / Set-Cookie / response-Authorization redaction; non-sensitive headers unchanged; api_key URL-param mask with name preserved; multi-param URL with all sensitive masked + others preserved + raw values gone; idempotency (HAR + console); clean-input passthrough (HAR + console); password / token / secret console field masking; non-sensitive console messages unchanged.
- [internal] new `tests/fixtures/sanitize/` — five synthetic JSON fixtures (har-with-auth, har-clean, har-multi-params, console-with-secrets, console-clean). Hand-authored for predictable tests; not derived from real Chrome captures.
- [docs] `docs/superpowers/plans/2026-05-08-phase-07-part-1-ii-sanitize-lib.md` — phase plan.

**Sub-scope (7-1-ii):**
- **No verb integration.** `inspect --capture-console --capture-network --capture` wire-up arrives in 7-1-iii.
- **No `--unsanitized` flag.** Typed-phrase opt-out lands in 7-1-iv.
- **No `meta.sanitized:false` audit field.** Also 7-1-iv.
- **No retention/prune.** That's 7-1-v.

**jq compatibility:** avoids named-capture-group regex (`(?<name>...)`) since older jq builds reject the syntax. Uses per-key sub() loop instead — portable across jq 1.6+. Verified on macOS Homebrew jq + Ubuntu apt jq via CI.

**Phase 7 progress: 2 of 5 sub-parts shipped.** Remaining: 7-1-iii (inspect wire-up — first composition test for capture + sanitize), 7-1-iv (--unsanitized + audit flag + doctor counter), 7-1-v (retention/prune + `_index.json` bookkeeping + `~/.browser-skill/config.json` thresholds).

### Phase 11 — memory design doc (auto-learned per-archetype selector/action cache; queued after Phase 9)

- [docs] new `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` — full design for the per-archetype selector/action cache. Locks decisions M1+U1+E1+H1 (cache key = `(site, url_pattern, intent_phrase)`; URL pattern via web-standard URLPattern API; engagement via new `browser-do --intent "..."` verb; self-healing via fail_count threshold + invalidation). Five sub-parts split: 11-1-i (lib foundation), 11-1-ii (verb wire-up), 11-1-iii (self-heal), 11-2-i (manual `--pattern` flag), 11-2-ii (auto-cluster). Storage at `~/.browser-skill/memory/<site>/archetypes/<archetype_id>.json` (mode 0700 dir, 0600 files). Schema frozen at v1.
- [docs] `docs/superpowers/HANDOFF.md` — Phase 11 sub-part table + storage shape + sequencing note (after Phase 9). Workflow-expectations section adds memory pattern entry; recipe-doc candidate `cache-write-security.md` queued for after Phase 11 part 1 ships.
- [docs] State-of-the-art (May 2026) confirms the user's instinct: Skyvern auto-caching + self-healing, Stagehand action caching that skips LLM inference after first interaction, Agent-E "Skill Harvesting" with 40% faster task completion after 20+ skills accumulated. URLPattern API (Node 20+ web standard) solves the `/devices/:id` URL-templating piece.

**Why now (design only, no code):** Phase 11 implementation is queued **after Phase 9** (flow runner) per user direction. Design doc ships first to lock decisions before code lands — same "design before code" cadence as parent spec (`2026-04-27-browser-automation-skill-design.md`). HANDOFF + CHANGELOG updates fold into this PR per the proven pure-docs-fold exception to the 5-of-5 alternation pattern (PRs #55, #58, this one).

**Cost compounding once shipped.** Memory hits = zero LLM tokens. Combined with the just-shipped `model: sonnet` + `effort: low` skill default + recommended `/model opusplan` parent session, memory is the **largest single cost lever in the roadmap** when fully realized. Target: ≥ 70% cache hit rate after 20+ similar actions per archetype (Agent-E benchmark threshold).

**Open follow-ups documented (decided during Phase 11 implementation, not now):** intent canonicalization (strip articles? embed-vector match?), cache TTL/decay, memory-as-input-to-flow-record (could `flow record` propose flows from clustered memory interactions?). All deferred until cache-hit-rate measurements warrant complexity.

### Skill model-routing — `model: sonnet` + `effort: low` default; new model-routing recipe

- [feat] `SKILL.md` frontmatter — adds `model: sonnet` + `effort: low`. Skill turns now drop to Sonnet 4.6 + low effort when invoked; parent session resumes its model on the next prompt (per [Claude Code skills docs](https://code.claude.com/docs/en/skills): "The override applies for the rest of the current turn and is not saved to settings"). Browser verb-driving is mechanical (chain snapshot → pick `eN` → fill/click) — Sonnet handles it reliably; Opus reasoning belongs in the parent session for plan-doc design / debugging session brainstorms. Estimated 3-5× cost reduction per skill turn vs running the whole turn on Opus.
- [docs] new `references/recipes/model-routing.md` — three-tier strategy (parent session, skill turn, per-verb-future). Parent session: recommends `/model opusplan` (Opus during plan mode, Sonnet in execution mode) as zero-risk starting point; documents `/advisor` toggle (experimental in v2.1.x; Sonnet executor + Opus advisor mid-generation) as next-level optimization. Documents override escape-hatch (`/model opus` before skill invocation when a session needs Opus reasoning during the skill turn). Cites authoritative sources (Claude Code docs, Advisor Tool API docs, pricing page).
- [docs] `docs/superpowers/HANDOFF.md` — model-routing pattern noted; recipe count → 4.

**Why now:** This is an orthogonal optimization — independent of Phase 7 capture-pipeline progress. One-line frontmatter edit + one new recipe-doc; fits between Phase 7 sub-parts without blocking them. The recipe lives next to the existing privacy-canary/path-security/body-bytes-not-body recipes so future agents extending the skill can apply the same routing pattern.

**Override escape-hatch.** Users who need Opus reasoning during a specific skill turn can run `/model opus` before invocation; the per-turn override only fires if the skill is loaded fresh. Permanent disable: change skill frontmatter to `model: inherit`.

**Open follow-up:** Per-verb model selection isn't supported by Claude Code's frontmatter today. If users report needing different models per verb (e.g. Opus for `login --interactive` form-shape detection; Haiku for `snapshot` raw screen-scrape), the workaround is splitting into N skills or using `Agent` tool from inside the skill body. Not worth structural complexity until demand surfaces.

### Phase 7 part 1-i — capture foundation (`lib/capture.sh` + `snapshot --capture`)

- [feat] new `scripts/lib/capture.sh` — three-function API: `capture_init_dir` (idempotent mkdir 0700), `capture_start <verb>` (atomic NNN allocation + meta.json `status:"in_progress"` + exports `CAPTURE_ID` + `CAPTURE_DIR`), `capture_finish [status]` (updates meta.json with `finished_at`/`status`/`total_bytes`/`files[]`; updates `_index.json` with `latest`/`count`/`total_bytes`/`next_id`).
- [feat] `scripts/browser-snapshot.sh` — opt-in `--capture` flag. When set, persists adapter stdout to `${CAPTURES_DIR}/NNN/snapshot.json` and writes meta.json. `capture_id` joins the summary line. `--capture` is **stripped before adapter dispatch** (verb-script-level flag, not for adapters). Without `--capture`, `~/.browser-skill/captures/` is not created — clean state preserved.
- [feat] **Atomic NNN allocation** via tmpfile + rename(2) per parent spec §4.5 ("tmpfile + mv, no flock"). Single-process per invocation expected; concurrent capture_starts race → documented as known limitation. Future hardening (mkdir without `-p` so the second loser fails fast) tracked.
- [feat] **Failure path:** when the adapter fails (`adapter_rc != 0`), `capture_finish error` still runs — meta.json is finalized with `status: "error"` so the artifact directory is never left in `in_progress` state. Test asserts this directly.
- [security] Dir mode 0700, all written files mode 0600. `meta.json` + `_index.json` permissions verified by bats.
- [fix] `scripts/lib/common.sh::summary_json` numeric autodetect rejects leading-zero integers (`001` → string, not `1`). Capture IDs are zero-padded 3-digit identifiers; the spec contract is "NNN string" not "integer". Future capture-id-style fields preserve their padding through the summary serializer.
- [internal] new `tests/capture.bats` (12 cases) — three-function contract: dir mode 0700, idempotent init, NNN=001 first run, zero-pad to 3 digits, bumps to 002 on second run, exports `CAPTURE_ID`+`CAPTURE_DIR`, meta.json shape (capture_id/verb/schema_version/started_at/status), dir+meta perms, capture_finish updates {finished_at/status/total_bytes/files[]}, status=ok/error round-trip, default status=ok, _index.json shape, two-capture cycle (latest=002, count=2, next_id=3).
- [internal] `tests/browser-snapshot.bats` (+5 cases) — `--capture` writes snapshot.json + meta.json + capture_id in summary; perms (700/600); _index.json updated; without `--capture` no captures dir created; adapter failure → meta.json status=error.
- [docs] `docs/superpowers/plans/2026-05-08-phase-07-part-1-i-capture-foundation.md` — phase plan.

**Sub-scope (7-i):**
- Wired only to `snapshot` — structurally safe (refs only, no headers/cookies, no leak surface). Console/HAR/screenshot wire-ups arrive when sanitization lands.
- `--capture` is **opt-in**, not default. Default-on policy waits for sanitization (capturing without sanitizing is a leak surface; capturing without writing is the safe stance for 7-i).
- `lib/capture.sh` does NOT call any adapter — pure filesystem helpers. Verbs sandwich their per-aspect file writes between `capture_start` and `capture_finish`.

**Deferred sub-parts (Phase 7 plan):**
- 7-ii: `lib/sanitize.sh` — pure jq-function library (sanitize_har, sanitize_console). Unit-tested in isolation.
- 7-iii: wire sanitizer into `inspect --capture-console --capture-network --capture` (writes console.json + network.har, sanitized by default).
- 7-iv: `--unsanitized` typed-phrase ack + `meta.json::sanitized:false` audit flag + `doctor` counter.
- 7-v: `capture_prune` (count>500 / age>14d) + retention thresholds in `~/.browser-skill/config.json`.

### Recipe-doc catch-up — three reusable patterns extracted (pre-Phase-7)

- [docs] `references/recipes/privacy-canary.md` — sentinel-byte regression test for any verb that ingests caller-supplied secrets via stdin. Layered bash + daemon coverage; canary-string discipline (unique per test, ASCII, ≥10 chars, distinct from injected payload); negative-grep + positive-shape combo (rejects "no output false-pass"); explicit "DON'T grep `${BROWSER_SKILL_HOME}`" rule (disk persistence is the credential-backend test's invariant, not the privacy canary's). Ten existing instances cited.
- [docs] `references/recipes/path-security.md` — four-step block (existence + regular-file → readable → sensitive-pattern reject → realpath canonicalize) for any verb taking `--path PATH`. Source of truth: `scripts/browser-upload.sh:74-103`. Documents resolve-then-check vs check-then-resolve ordering trade-off (browser-upload shipped check-then-resolve; resolve-first is paranoid form for new verbs). Cross-platform `realpath || readlink -f || printf` fallback chain explained.
- [docs] `references/recipes/body-bytes-not-body.md` — for caller-supplied content (HTTP bodies, blobs), reply ships `<thing>_bytes` (length), never `<thing>` (content). Source of truth: `scripts/lib/node/chrome-devtools-bridge.mjs::case 'route'` fulfill branch. `Buffer.byteLength` vs `.length` gotcha (utf-16 code-unit mismatch); bash `wc -c` analogue; defensive double-scrub idiom from fill verb (line ~432).
- [docs] `docs/superpowers/HANDOFF.md` — marks all three recipes shipped; removes "overdue" markers from workflow-expectations section; PR count 55.

**Why now (pre-Phase-7):** Phase 7 (capture pipeline + sanitization) will reuse path-security as a primitive (sanitization-write-to-file gate) and body-bytes-not-body for sanitizer-output replies. Cheaper to extract patterns now than mid-Phase-7. Pure-docs PR; near-zero risk.

### Phase 6 part 7-ii — `route` verb extension: `--action fulfill` (closes Phase 6)

- [feat] `scripts/browser-route.sh` — accept `--action fulfill` (block/allow/fulfill triad complete). Adds `--status N` (HTTP code, integer 100-599) + body transport (`--body STR` ⊕ `--body-stdin`, mutex). Bash-side validation: `--status` / `--body*` rejected when paired with `block`/`allow`; fulfill requires both status + body; status range + integer-shape enforced. Body-via-stdin uses the same passthrough pattern as `fill --secret-stdin` (browser-fill.sh:87) — bash forwards the `--body-stdin` flag and stdin inherits naturally to the bridge subprocess.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runRouteViaDaemon` — parses `--status` / `--body` / `--body-stdin`; reads stdin via existing `readAllStdin` helper on `--body-stdin`; passes status + body through IPC to daemon child.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` daemon-child `case 'route'` — `routeRules` slot extends from `{pattern, action}` to `{pattern, action: 'fulfill', status, body}` for fulfill rules; defensive validation re-checks status range + body presence (defense in depth — surface area for non-CLI callers); calls upstream MCP `route_url` with `{pattern, action, status?, body?}`. Reply adds `fulfill_status` + `body_bytes` (byte length, not the body itself — avoids re-emitting agent-supplied content; large bodies stay out of stdout).
- [feat] **Body verbatim policy.** Unlike `fill --secret-stdin` (which strips a trailing newline since secrets shouldn't carry one), `route fulfill` stores the body **as-is** including trailing bytes — HTTP bodies are content where round-trip fidelity matters. Daemon e2e test asserts roundtrip.
- [security] Body lives **in-memory only** in the daemon process (mirrors 7-i routeRules). Never written to disk; dies with the daemon. `body_bytes` (not `body`) ships in the reply by default — avoids accidental terminal/log capture.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_route` — no change required. Existing `rest=()` passthrough already forwards `--status` / `--body` / `--body-stdin` to the bridge.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `route_url` handler echoes `(status N, M bytes)` suffix on `action: 'fulfill'` so e2e can assert the call shape end-to-end.
- [internal] `tests/browser-route.bats` (+8 cases, 1 rewritten) — fulfill happy dry-run with `fulfill_status` + `body_bytes` in summary; missing-status; missing-body; body / body-stdin mutex; `--status 99` out of range (mentions "100-599"); `--status notanumber` non-integer; `--status` with `--action block` rejected; `--body` with `--action allow` rejected. Old "fulfill rejected with 7-ii hint" case rewritten as positive happy-path test.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3 cases) — fulfill via daemon registers extended rule + persists status + body length + observes `route_url` MCP call with `status` + `body` args; `--body-stdin` body roundtrips verbatim (byte length matches); out-of-range status arriving at the bridge (defensive) returns error event mentioning "100-599".
- [docs] `docs/superpowers/plans/2026-05-07-phase-06-part-7-ii-route-fulfill.md` — phase plan.

**Sub-scope (7-ii):**
- Three actions accepted: `block` | `allow` | `fulfill`. The fulfill-only flags (`--status`, `--body`, `--body-stdin`) are validated bash-side AND daemon-side (defense in depth). Bridge layer is the validating boundary if the IPC is exercised by a non-CLI caller.
- Body byte length is the contract surfaced in the reply (`body_bytes`); the body string itself is not re-emitted.
- Body-stdin transport: bash → bridge stdin (passthrough, no bash-side stdin read) → bridge `readAllStdin` → IPC `body` field → daemon-child store.

**Documented limitations:**
- Bash variables and JSON IPC strings can't carry the NUL byte itself. Multipart bodies legitimately containing NUL would need a different transport (file path? base64?). Not in scope for 7-ii.
- `readAllStdin` reads as utf-8. Non-utf8 binary bytes aren't a target use case for 7-ii (HTTP API mocking is the primary motivation).

**Phase 6 progress: 11 of 11 declared verbs.** ✅ **Phase 6 COMPLETE.**

### Phase 6 part 8-iii — `tab-close` verb (last tab-* verb; closes Phase 6 tab trilogy)

- [feat] new `scripts/browser-tab-close.sh` verb — mutex selectors `--tab-id N` ⊕ `--by-url-pattern STR`. Symmetric with tab-switch but uses canonical `--tab-id` (matches `tab_id` from tab-list output) instead of `--by-index` (positional). Reasoning: index drifts as the array shrinks during successive closes; canonical id is unambiguous. **Daemon-required.** Routes to chrome-devtools-mcp via new `rule_tab_close_default`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabCloseViaDaemon` (defensively re-validates the mutex). Dispatch case `'tab-close'`: auto-refreshes `tabs[]` if empty (mirrors tab-switch); resolves selector → tab object; calls upstream MCP `close_page` (best-effort name; real upstream may differ); splices the matching entry from `tabs[]`; nulls `currentTab` if it pointed at the closed tab. Returns `{closed_tab, current_tab_id, tab_count}`. **`tab_id` values stay stable on remaining entries** — agents holding a `tab_id` reference shouldn't see it silently rebound.
- [feat] `scripts/lib/router.sh::rule_tab_close_default` — verb=`tab-close` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-close` capability declared (`flags: ["--tab-id", "--by-url-pattern"]`); new `tool_tab-close` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `close_page` handler echoes `closed tab N (URL)`.
- [internal] new `tests/browser-tab-close.bats` (8 cases) — missing-both-flags, mutex, `--tab-id 0` (1-based), empty `--by-url-pattern`, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+7) — by-tab-id happy + `close_page` MCP call observed; by-url-pattern substring resolution; closing currentTab nulls `current_tab_id`; closing non-current preserves `current_tab_id`; out-of-range `--tab-id` error; no-match pattern error; no-daemon exit-41.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 18 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-iii-tab-close.md` — phase plan.

**Sub-scope (8-iii):**
- Mutex selectors only — exactly one of canonical id / pattern.
- `tab_id` stability across closes is an explicit contract (no renumbering).
- `currentTab` invalidation on close-match — agents see `current_tab_id: null` in subsequent `tab-list` output.
- No auto-fallback to a remaining tab on close — keeps the agent's mental model explicit.

**Phase 6 progress: 10 of 10 declared verbs.** All Phase 6 tab-* verbs done (tab-list / tab-switch / tab-close). Only route fulfill (7-ii) remains as an independent track within Phase 6 (deferred — body management adds stdin-mux + binary-safety + persistence in `routeRules`).

### Phase 6 part 8-ii — `tab-switch` verb (first state-mutation on `tabs[]`)

- [feat] new `scripts/browser-tab-switch.sh` verb — mutex selectors `--by-index N` (1-based) ⊕ `--by-url-pattern STR` (substring-contains, first-match-wins). **Daemon-required.** Routes to chrome-devtools-mcp via new `rule_tab_switch_default`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabSwitchViaDaemon` (defensively re-validates the mutex). Daemon child gains `currentTab` slot (number | null — the tab_id pointer; tab metadata stays in `tabs[]`). New `refreshTabs()` helper shared between `tab-list` and `tab-switch` (the latter auto-refreshes `tabs[]` when empty so agents needn't remember to call `tab-list` first). Dispatch case `'tab-switch'` resolves selector → tab object, calls upstream MCP `select_page` (best-effort name; real upstream may differ — binding hardening tracked downstream), updates `currentTab`, returns `{ current_tab: { tab_id, url, title }, ... }`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `tab-list` output now annotates `is_current: true` on the entry whose `tab_id` matches `currentTab`, plus `current_tab_id` field at top level. Was queued for 8-iii but folded in here since `currentTab` is introduced in this sub-part.
- [feat] `scripts/lib/router.sh::rule_tab_switch_default` — verb=`tab-switch` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-switch` capability declared (`flags: ["--by-index", "--by-url-pattern"]`); new `tool_tab-switch` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `select_page` handler echoes `selected tab N (URL)`.
- [internal] new `tests/browser-tab-switch.bats` (8 cases) — missing-both-flags, mutex, `--by-index 0` (1-based), empty `--by-url-pattern`, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+7) — by-index happy + `select_page` MCP call observed; by-url-pattern substring resolution; auto-refresh when `tabs[]` empty (no preceding tab-list); by-url-pattern no-match error; by-index out-of-range error; no-daemon exit-41; `is_current` annotation in `tab-list` output after switch.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 17 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-ii-tab-switch.md` — phase plan.

**Sub-scope (8-ii):**
- Mutex selectors only — exactly one of index / pattern.
- Substring-contains is intentionally simple. `--by-url-regex` / `--by-url-glob` deferred to follow-up.
- `currentTab` is just the `tab_id` (number) — single source of truth for tab metadata stays in `tabs[]`.

**Deferred to part 8-iii (`tab-close`):**
- `--tab-id N` ⊕ `--by-url-pattern STR` (mutex). Splice from `tabs[]` + close upstream page.
- `currentTab` invalidation when the closed tab matches.

Phase 6 progress: **9 of 10 declared verbs** (press / select / hover / wait / drag / upload / route / tab-list / tab-switch). Remaining: tab-close (8-iii); route fulfill (7-ii) is independent.

### Phase 6 part 8-i — `tab-list` verb foundation (multi-tab daemon-state slot)

- [feat] new `scripts/browser-tab-list.sh` verb — no required flags. Routes to chrome-devtools-mcp via new `rule_tab_list_default`. **Daemon-required** (mirrors route precedent — caches tabs in the daemon's new `tabs` slot so 8-ii / 8-iii can mutate the same shape). Without daemon → exit 41 with hint.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabListViaDaemon` (parallel to `runRouteViaDaemon`, no args). Daemon child gains `tabs` state slot (array of `{tab_id, url, title}`). Dispatch case `'tab-list'` calls upstream MCP `list_pages` (best-effort name; real upstream may use a different tool — binding hardening tracked in 8-ii / 8-iii), normalizes to `[{tab_id, url, title}]`, **replaces** (not appends) the cache, returns it with `tab_count`.
- [feat] `scripts/lib/router.sh::rule_tab_list_default` — verb=`tab-list` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-list` capability declared (`flags: []`); new `tool_tab-list` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `list_pages` handler returns canned 2-page array (`example.com/`, `example.org/news`).
- [internal] new `tests/browser-tab-list.bats` (5 cases) — ghost-tool, capability filter rejects (playwright-cli has no `tab-list`), dry-run shape, router routing, capability declaration.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy (`tab_count==2` + `tab_id`/`url`/`title` shape + `list_pages` MCP call observed), idempotent (second call replaces cache, doesn't accumulate), no-daemon exit-41.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 16 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-i-tab-list.md` — phase plan.

**Sub-scope (8-i — minimal):**
- Read-only enumeration. `tab_id` is bridge-assigned (1-based, stable per `list_pages` call). Upstream's CDP target id never escapes the bridge — agents only see the stable `tab_id` contract.
- Foundation: `tabs[]` daemon slot ships before any verb mutates it.

**Deferred to part 8-ii (`tab-switch`):**
- `--by-index N` ⊕ `--by-url-pattern STR` (mutex). Updates a new `currentTab` pointer in the daemon.
- Active-tab annotation in `tab-list` output.

**Deferred to part 8-iii (`tab-close`):**
- `--tab-id N` ⊕ `--by-url-pattern STR`. Splices the matching entry out of `tabs[]` + closes the page upstream.

**Deferred (part 7-ii is independent):**
- Real upstream binding (canonical MCP tool name; `list_pages` is the bridge's best-effort convention — upstream may use `pages.list`, `targets.list`, etc.).

Phase 6 progress: **8 of 8 verbs declared** (press / select / hover / wait / drag / upload / route / tab-list); tab-switch + tab-close (8-ii / 8-iii) and route fulfill (7-ii) remain as separate sub-PRs.

### Phase 6 part 7-i — `route` verb foundation (block + allow only; fulfill deferred)

- [feat] new `scripts/browser-route.sh` verb — `--pattern URL_PATTERN` + `--action allow|block` (required). Routes to chrome-devtools-mcp via new `rule_route_default`. **Daemon-state-mutating** (registers `{pattern, action}` in daemon's `routeRules` array). Daemon-required.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runRouteViaDaemon` dispatcher (parallel to `runStatefulViaDaemon` but no refMap dependency). Daemon child gains `routeRules` state slot (array of `{pattern, action}` entries). Dispatch case `'route'` validates action against `{block, allow}`, appends rule, best-effort calls MCP `route_url` (real upstream tool name may differ — binding hardening is part 7-ii), emits ack with `rule_count`.
- [feat] `scripts/lib/router.sh::rule_route_default` — verb=`route` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `route` capability declared (`flags: ["--pattern", "--action"]`); new `tool_route` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `route_url` handler echoes `routed <pattern> → <action>`.
- [internal] new `tests/browser-route.bats` (8 cases) — missing-pattern, missing-action, fulfill rejected with hint, invalid-action, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon block-action happy (rule registered, MCP ack), 2 calls accumulate (`rule_count == 2`), invalid-action error event, no-daemon exit-41.
- [docs] `SKILL.md` — `route` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-7-i-route.md` — phase plan.

**Sub-scope (7-i — minimal):**
- `block` and `allow` actions only.
- Foundation for daemon-side rule storage; runtime application of rules to actual network requests is upstream MCP's responsibility.

**Deferred to part 7-ii:**
- `--action fulfill` with `--status N` and `--body BODY` (synthetic responses). Body via stdin per AP-7 since bodies can be arbitrary content.
- Rule removal (`route remove --pattern X`) and listing (`route list`).
- Real upstream binding (correct MCP tool name + canonical action verbs). Current `route_url` is a stub-only convention.

Phase 6 progress: **7 of 8 verbs** (press / select / hover / wait / drag / upload / route). Remaining: tab-*.

### Phase 6 part 6 — `upload` verb (`<input type=file>` upload with path security)

- [feat] new `scripts/browser-upload.sh` verb — `--ref eN` + `--path PATH`. Routes to chrome-devtools-mcp via new `rule_upload_default`. Stateful (refMap precondition).
- [security] **Path security validation, bash-side BEFORE adapter dispatch:**
  1. Path must exist and be a regular file (not dir, not device).
  2. Path must be readable by the current user.
  3. Path must NOT match common sensitive patterns (`*.ssh/*`, `*/.aws/credentials`, `*.env`, `*credentials*`, `*/private_key*`, `*/id_rsa*`/`id_ed25519*`/`id_ecdsa*`).
  4. Override sensitive-pattern reject via `--allow-sensitive` ack flag (covers legit "upload my GPG key" use cases).
  5. Resolve to canonical path via `realpath`/`readlink -f` (eliminates symlink shenanigans) before forwarding to MCP.
- [feat] `scripts/lib/router.sh::rule_upload_default` — verb=`upload` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `upload` declared in capabilities (`flags: ["--ref", "--path"]`); new `tool_upload` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — `upload` early-return branch (parallel to drag's 2-arg shape) parses `<ref> <path>`. Daemon dispatch resolves ref → uid, calls MCP `upload_file` with `{uid, path}`. Path is forwarded as-is (already validated bash-side).
- [internal] `tests/stubs/mcp-server-stub.mjs` — `upload_file` handler echoes `uploaded <path> to <uid>`.
- [internal] new `tests/browser-upload.bats` (12 cases) — missing-ref, missing-path, nonexistent-path, dir-not-file, unreadable-file, SSH-key reject, .env reject, --allow-sensitive bypass, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+2) — daemon happy via uid translation, no-daemon exit-41.
- [docs] `SKILL.md` — `upload` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-6-upload.md` — phase plan.

After this PR, `bash scripts/browser-upload.sh --ref e3 --path ~/Downloads/file.pdf` works end-to-end (with daemon). Sensitive-path defense protects against agent-misdirection attacks where a webpage's instructions try to coerce uploading SSH keys / .env files / credentials.

Phase 6 progress: **6 of 8 verbs** (press / select / hover / wait / drag / upload). Remaining: route / tab-*.

### Phase 6 part 5 — `drag` verb (pointer drag from src → dst by refs)

- [feat] new `scripts/browser-drag.sh` verb — `--src-ref eA` + `--dst-ref eB` (both required). Routes to chrome-devtools-mcp via new `rule_drag_default`. Stateful — refMap precondition for **both** refs (mirrors click/select shape, with two-ref translation).
- [feat] `scripts/lib/router.sh::rule_drag_default` — verb=`drag` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `drag` declared in capabilities (`flags: ["--src-ref", "--dst-ref"]`); new `tool_drag` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — drag has 2-ref argv shape (`drag <src-ref> <dst-ref>`), special-cased above the single-ref shape used by click/fill/select/hover. Daemon dispatch `case 'drag'` resolves both refs → uids, calls MCP `drag` tool with `{src_uid, dst_uid}`.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `drag` handler echoes `dragged <src> → <dst>`.
- [internal] new `tests/browser-drag.bats` (6 cases) — missing-src-ref, missing-dst-ref, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon happy (both refs translated), no-daemon exit-41, unknown src ref error, unknown dst ref error.
- [docs] `SKILL.md` — `drag` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-5-drag.md` — phase plan.

After this PR, `bash scripts/browser-drag.sh --src-ref e3 --dst-ref e7` works end-to-end (with daemon). Phase 6 progress: 5 of 8 verbs (press / select / hover / wait / drag). Remaining: upload / route / tab-*.

Selector-based drag (`--src-selector`/`--dst-selector`) deferred to follow-up.

### Phase 6 part 4 — `wait` verb (explicit element-state wait)

- [feat] new `scripts/browser-wait.sh` verb — `--selector CSS` + `--state visible|hidden|attached|detached` (default visible) + `--timeout MS` (default: MCP server's default). Routes to chrome-devtools-mcp via new `rule_wait_default`. Stateless — works one-shot or daemon-routed (parallel to eval/audit).
- [feat] `scripts/lib/router.sh::rule_wait_default` — verb=`wait` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `wait` declared in capabilities (`flags: ["--selector", "--state", "--timeout"]`); new `tool_wait` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `translateVerb`/`shapeResponse`/`runStatelessViaDaemon`/daemon dispatch all gain `wait` cases. Passes `{selector, state?, timeout?}` to MCP `wait_for` tool.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `wait_for` handler echoes `waited for <selector> to be <state>`.
- [internal] new `tests/browser-wait.bats` (6 cases) — missing-selector, invalid-state, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot real-mode wait dispatches `wait_for`.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed wait emits `attached_to_daemon: true`.
- [docs] `SKILL.md` — `wait` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-4-wait.md` — phase plan.

After this PR, `bash scripts/browser-wait.sh --selector ".dashboard" --state visible --timeout 5000` works end-to-end. Phase 6 progress: 4 of 8 verbs (press / select / hover / wait). Remaining: drag / upload / route / tab-*.

### Phase 6 part 3 — `hover` verb (pointer hover by ref)

- [feat] new `scripts/browser-hover.sh` verb — `--ref eN`. Routes to chrome-devtools-mcp via new `rule_hover_default`. Stateful (refMap precondition; mirrors click/select).
- [feat] `scripts/lib/router.sh::rule_hover_default` — verb=`hover` → chrome-devtools-mcp. Slotted between `rule_select_default` and `rule_default_navigation`.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `hover` declared in capabilities (`flags: ["--ref"]`); new `tool_hover` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — extended for `hover` (parallel to click). Daemon dispatch `case 'hover'` resolves ref → uid, calls MCP `hover` tool.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `hover` handler echoes `hovered <uid>`.
- [internal] new `tests/browser-hover.bats` (5 cases) — missing-ref, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy path (uid translation), no-daemon exit-41, unknown-ref error.
- [docs] `SKILL.md` — `hover` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-3-hover.md` — phase plan.

`--selector` path deferred to follow-up if user demand surfaces (current shape is `--ref`-only mirroring click/select).

### Phase 6 part 2 — `select` verb (`<select>` option pick by ref)

- [feat] new `scripts/browser-select.sh` verb — `--ref eN` (required) + exactly one of `--value VAL` / `--label LABEL` / `--index N`. Mode-flag mutex enforced (uses-counter idiom).
- [feat] `scripts/lib/router.sh::rule_select_default` — verb=`select` → chrome-devtools-mcp. Slotted between `rule_press_default` and `rule_default_navigation`.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `select` declared in capabilities (`flags: ["--ref", "--value", "--label", "--index"]`); new `tool_select` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — extended to handle `select`. New daemon dispatch case translates `eN → uid` from refMap, calls MCP `select_option` with `uid` + value/label/index. Stateful — refMap precondition (mirrors click/fill).
- [internal] `tests/stubs/mcp-server-stub.mjs` — `select_option` handler echoes `selected <uid> by <mode>=<val>`.
- [internal] new `tests/browser-select.bats` (7 cases) — missing-ref, missing-mode, mode mutex, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — daemon-routed select via value / label / index, no-daemon exit-41, unknown-ref error.
- [docs] `SKILL.md` — `select` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-2-select.md` — phase plan.

After this PR, `bash scripts/browser-select.sh --ref e3 --value alpha` works end-to-end (with a running daemon) against a real upstream chrome-devtools-mcp server.

Untouched per scope discipline: every other adapter / verb / lib / test (only Phase 6 part 2 surface).

### Phase 6 part 1 — `press` verb (keyboard input via cdt-mcp)

Phase 6 begins. Bulk verbs (press / select / hover / wait / drag / upload / route / tab-*) round out the interaction surface per parent spec Appendix A. Smallest first: pure stateless keyboard input.

- [feat] new `scripts/browser-press.sh` verb — `--key KEY` (e.g. `Enter`, `Tab`, `Escape`, `ArrowDown`, `Cmd+S`). Routes to chrome-devtools-mcp by default via new `rule_press_default`.
- [feat] `scripts/lib/router.sh::rule_press_default` — verb=`press` → chrome-devtools-mcp. Slotted between `rule_extract_default` and `rule_default_navigation`. playwright-cli/lib don't declare press today (could be added later via their `keyboard.press` APIs).
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `press` declared in capabilities (`flags: ["--key"]`). New `tool_press` dispatcher shells to bridge.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — daemon dispatch + one-shot `press` translation → MCP `press_key` tool. Stateless w.r.t. refMap; works in both daemon and one-shot paths (mirrors `eval`/`audit`/`open`).
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::shapeResponse` — new `press` case emits `key` field alongside the standard summary.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `press_key` handler emits `pressed <key>` content.
- [internal] new `tests/browser-press.bats` (6 cases) — happy lib-stub path, missing-flag rejection, ghost-tool rejection, capability-filter rejection of `--tool=playwright-cli`, dry-run, router routing assertion.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot real-mode press dispatches `press_key`.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed press emits `attached_to_daemon: true`; stub log verifies key passthrough.
- [docs] `SKILL.md` — `press` row added (auto-regenerated by `scripts/regenerate-docs.sh`).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — auto-regenerated capability table now lists press.

After this PR, `bash scripts/browser-press.sh --key Enter` works end-to-end against a real upstream chrome-devtools-mcp server (one-shot) or via the daemon when running. Foundation for Phase 6's remaining verbs (select / hover / wait / drag / upload / route / tab-*).

Untouched per scope discipline: `scripts/lib/tool/playwright-{cli,lib}.sh` (could declare press in a follow-up if `keyboard.press` integration desired), `scripts/browser-{open,click,fill,snapshot,inspect,audit,extract,eval}.sh` (unchanged), all credentials/session libs.


### Phase 5 part 4-iv — `creds rotate-totp` verb (Phase 5 FEATURE-COMPLETE)

- [feat] new `scripts/browser-creds-rotate-totp.sh` — re-enroll TOTP shared secret for an existing totp_enabled credential. Use case: service forces a new TOTP secret (re-issued QR code during account recovery, security-incident rotation, etc.). Replaces the `<name>__totp` backend slot with a new value; metadata.totp_enabled stays true; password slot UNCHANGED.
- [security] **AP-7 strict** — new TOTP secret comes via stdin only (`--totp-secret-stdin` required). Refuses argv-based secrets.
- [security] **Typed-phrase confirmation** mirrors `creds-migrate` and `creds-remove` patterns. Default: prompts for cred name; `--yes-i-know` skips for scripted use.
- [security] Refuses non-totp_enabled creds (use `creds-add --enable-totp` for first-time enrollment).
- [security] Privacy invariant: new TOTP secret NEVER appears in stdout/stderr. Sentinel canary tested (`sekret-do-not-leak-rotate-totp`).
- [internal] new `tests/creds-rotate-totp.bats` (11 cases) — `--as` required, `--totp-secret-stdin` required (AP-7 enforcement), unknown cred → EXIT_SITE_NOT_FOUND, non-totp refusal, empty-stdin refusal, `--dry-run` skips mutation, confirmation mismatch aborts, `--yes-i-know` happy path overwrites, **privacy canary**, password slot regression guard (untouched), metadata regression guard (totp_enabled stays true).
- [docs] `SKILL.md` — new `creds totp` and `creds rotate-totp` rows.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-iv-rotate-totp.md` — phase plan.

**🎉 Phase 5 is FEATURE-COMPLETE.** All HANDOFF queue items shipped:
- Part 1 (cdt-mcp track): adapter + bridge + daemon + 8/8 verbs real-mode + Path B router + verb scripts + session loading.
- Part 2 (creds track): 5 verbs + 3 backends + smart auto-detect + masked reveal + first-use plaintext gate.
- Part 3 (auth track): login --auto + transparent verb-retry + auth-flow declaration + 2FA detection.
- Part 4 (TOTP track): foundation flag + codegen + auto-replay + rotation. **End-to-end auto-relogin for 2FA-protected sites.**

Next phases (per parent spec): 6 (bulk verbs), 7 (capture pipeline), 8 (obscura adapter), 9 (flow runner), 10 (schema migration tooling).

Untouched per scope discipline: every other verb script, all adapters, router rules, common.sh, all session/site/credential libs (uses existing `credential_set_totp_secret` API from part 4-ii).

### Phase 5 part 4-iii — `login --auto` TOTP auto-replay (closes auth track)

- [feat] `scripts/lib/node/totp-core.mjs` — extracted from `totp.mjs` so other modules can import the same `totpAt` / `base32Decode` primitives. CLI `totp.mjs` is now a thin shim. Both share zero-dep RFC 6238 logic; existing 8 RFC test vectors still pass.
- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — when stdin includes a 3rd NUL-separated chunk (TOTP shared secret), and `detect2FA(page)` fires after the username+password submit, the driver imports `totpAt` from `totp-core.mjs`, generates the current code, fills the OTP field via best-effort selectors (`input[autocomplete="one-time-code"]`, `input[name*="otp" i]`, etc.), submits, awaits navigation, then captures `storageState` (the normal happy path). When TOTP secret absent: existing exit-25 path.
- [feat] `scripts/browser-login.sh::--auto` — when cred metadata `totp_enabled: true`, appends `\0` + TOTP secret to the stdin pipe. Fully transparent — non-totp creds preserve the 2-chunk stdin protocol unchanged.
- [feat] **End-to-end auto-relogin for 2FA-protected sites.** Agent registers a TOTP-enabled cred once (`creds-add --enable-totp --yes-i-know-totp --totp-secret-stdin`). On any session-aware verb that hits `EXIT_SESSION_EXPIRED`, the verb's transparent retry (part 3-ii) → `login --auto` → driver detects 2FA → driver auto-replays TOTP → captures fresh storageState → verb retries successfully. **Zero agent intervention** for sites with TOTP-only 2FA.
- [internal] Driver test-mode hook `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` short-circuits to a "totp-replayed" path that exercises the totp-core import + emits an `auto-relogin-totp-replayed` event without launching a real Chrome. Lets bats verify the bash-side stdin-mux + totp-core wiring.
- [internal] `tests/login.bats` (+2 cases) — `_seed_totp_cred` helper creates a totp_enabled cred via `credential_set_totp_secret`. Test 1: totp_enabled cred → driver receives 3rd stdin chunk + emits totp-replayed event. Test 2: non-totp cred → 2 chunks (regression dry-run path).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-iii-totp-auto-replay.md` — phase plan.

After this PR, the **auth track is fully end-to-end**: passwords-only sites work via part 3 + 3-ii; 2FA sites with stored TOTP work via 4-iii. The only remaining auth-track item is `creds rotate-totp` (part 4-iv) for service-forced TOTP re-enrollment.

Untouched per scope discipline: `scripts/lib/credential.sh` (already had `credential_get_totp_secret` from part 4-ii), `scripts/lib/secret/*.sh`, every other verb script, all adapters, router rules.

### Phase 5 part 4-ii — TOTP code generation + secret persistence

- [feat] new `scripts/lib/node/totp.mjs` — pure-node RFC 6238 TOTP code generator. Uses node's `crypto.createHmac` (no external deps). Reads base32-encoded shared secret from stdin; emits 6-digit code on stdout for the current 30s window. Supports env-var overrides for tests: `TOTP_TIME_T` (override "now"), `TOTP_DIGITS`, `TOTP_PERIOD`, `TOTP_ALG`. **Validated against all 5 RFC 6238 §A test vectors** for SHA1.
- [feat] `scripts/lib/credential.sh` — new `credential_set_totp_secret NAME` + `credential_get_totp_secret NAME` API. TOTP shared secret stored in the same backend as the password but under a sibling slot named `<NAME>__totp` (double-underscore suffix is allowed by `assert_safe_name`'s regex `^[A-Za-z0-9_-]+$` so backends validate the slot name through their normal path). Each cred's metadata still has only one entry; the backend has two secret slots (password + TOTP).
- [feat] `scripts/browser-creds-add.sh` — new `--totp-secret-stdin` flag. Reads `password\0totp_secret` from stdin (NUL-separated, AP-7: secrets never on argv). Requires `--enable-totp`. Uses `read -r -d ''` because `$(cat)` strips embedded NUL bytes ("warning: ignored null byte"). Stores TOTP secret via `credential_set_totp_secret` after the regular password write.
- [feat] new `scripts/browser-creds-totp.sh` verb — `--as CRED_NAME` reads stored TOTP secret, pipes it to `totp.mjs`, emits 6-digit code on stdout. Refuses if cred is not totp_enabled. Refuses unknown cred (EXIT_SITE_NOT_FOUND). Privacy invariant: shared secret never appears in stdout. `--dry-run` skips code generation.
- [security] Edge collision guard: `creds-add` rejects user-facing names matching `*__totp` to prevent collision with the internal slot naming convention. (E.g. user can't create a cred named `prod--admin__totp` because it would alias `prod--admin`'s TOTP slot.)
- [internal] new `tests/totp-codegen.bats` (8 cases) — 5 RFC 6238 §A test vectors, default 6-digit length, empty-stdin rejection, invalid-base32 rejection.
- [internal] new `tests/creds-totp.bats` (9 cases) — `--totp-secret-stdin` mutex with `--enable-totp`; missing-NUL-chunk rejection; happy-path stores in keychain stub at `<name>__totp` slot; `creds-totp` produces 6-digit code; refuses non-totp creds; `--as` required; unknown cred → EXIT_SITE_NOT_FOUND; `--dry-run` skips; **privacy canary** — shared secret never appears in stdout.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-ii-totp-codegen.md` — phase plan.

After this PR, an agent with a TOTP-enabled credential can run `bash scripts/browser-creds-totp.sh --as prod--admin` and get a current 6-digit code, then type/fill it into a 2FA challenge field. Auto-replay (login --auto generates the code automatically when 2FA detected) is **part 4-iii** — the final auth-track sub-part.

**Out of scope (deferred):**
- Auto-replay in `login --auto` after 2FA detection — part 4-iii. Wires `credential_get_totp_secret` + `totp.mjs` into the playwright-driver after `detect2FA` triggers.
- `creds rotate-totp` verb — part 4-iv. Re-enrollment when service forces a new TOTP secret.
- TTY-only / `--allow-non-tty` gate on `creds-totp` stdout — codes are short-lived (30s) but could leak via shell history. Could land as a 4-ii cont.

Untouched per scope discipline: `scripts/browser-login.sh` (auto-replay is part 4-iii), every other verb script, all adapters, router rules.

### Phase 5 part 4-i — TOTP foundation: `--enable-totp` flag at `creds add` time

- [feat] `scripts/browser-creds-add.sh` — new `--enable-totp` flag persists `totp_enabled: true` in cred metadata. Required co-flags: `--yes-i-know-totp` (typed acknowledgment that TOTP shared secrets are highly sensitive). Refuses `--backend plaintext` (TOTP secrets must go through OS keychain / libsecret per parent spec §1 — plaintext on-disk storage of a TOTP shared secret means anyone with read access can generate auth codes for the lifetime of the secret).
- [security] Even gated, the plaintext refusal stands: TOTP shared secrets are categorically more sensitive than passwords because they don't expire/rotate (typical service issues one secret valid until manually re-enrolled). Plaintext storage of such secrets violates parent spec §1 in spirit even if the password gate were satisfied.
- [internal] `tests/creds-add.bats` (+4 cases) — `--enable-totp` requires `--yes-i-know-totp`; refuses plaintext; happy path persists `totp_enabled=true`; regression — no `--enable-totp` defaults to false.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-i-totp-plumbing.md` — phase plan.

**Sub-scope (4-i — plumbing only):**
- Marks the cred as TOTP-enabled in metadata.
- Forbids plaintext backend for TOTP creds.
- Doesn't yet store TOTP shared secret, generate codes, or replay during login.

**Deferred to follow-up sub-parts of part 4:**
- **4-ii (codegen)** — `creds totp` verb produces a current code via `oathtool` (or node port). Manual replay path: user reads code, types into browser.
- **4-iii (auto-replay)** — `login --auto` reads TOTP secret + generates code + fills 2FA field after detecting the challenge page. Closes the loop.
- **4-iv (rotation)** — `creds rotate-totp` verb for re-enrollment when service forces a new TOTP secret.

After this PR, the TOTP track has its declaration foundation. Codegen and replay can layer on top without metadata-schema churn — part 4-ii's TOTP secret-storage uses the existing `credential.sh` backend dispatcher with a name-suffix convention (e.g. `<name>:totp` for the second slot).

Untouched per scope discipline: `scripts/lib/credential.sh` (no schema changes — `totp_enabled` field already in metadata template since part 2d), `scripts/lib/secret/*.sh` (no backend ABI changes), every other verb script, all adapters.

### Phase 5 part 3-iv — 2FA detection in `login --auto` → exit 25

- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — new `detect2FA(page)` heuristic runs after the submit-form-and-wait sequence. Checks (in order): `input[autocomplete="one-time-code"]`, common OTP/code field name attributes (`input[name*="otp" i]`, etc.), and page text for 2FA keywords (`two-factor`, `verification code`, `authenticator app`, etc.). On match: closes the browser, emits `auto-relogin-2fa-required` JSON, exits 25 (matches bash `EXIT_AUTH_INTERACTIVE_REQUIRED`).
- [feat] `scripts/browser-login.sh::--auto` — propagates driver exit 25 as `EXIT_AUTH_INTERACTIVE_REQUIRED` with hint `"site requires 2FA / interactive challenge — re-run with --interactive (or wait for phase-5 part 4 TOTP)"`. Other non-zero exit codes from the driver still propagate as `EXIT_TOOL_CRASHED`.
- [internal] `scripts/lib/node/playwright-driver.mjs` — test-mode env var `BROWSER_SKILL_DRIVER_TEST_2FA=1` short-circuits the driver to exit 25 immediately (no browser launch). Lets bats verify the bash-side propagation without a real Chrome + 2FA challenge page. Production callers never set this.
- [internal] `tests/login.bats` (+1 case) — driver returning 25 propagates as `EXIT_AUTH_INTERACTIVE_REQUIRED` with the hint mentioning "2FA" and "interactive".
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-iv-2fa-detection.md` — phase plan.

**Heuristic limitations (out of scope):**
- Push-notification 2FA flows (no input field, just a "waiting" UI) — won't be caught by selectors. The driver will time out at the navigate-after-submit wait and capture an unauthenticated session. User sees the failure later when verbs return EXIT_SESSION_EXPIRED.
- SMS-prompt fallbacks where the page asks "did you receive a code?" before showing the input — depends on text-keyword match; coverage varies.
- Real-world detection coverage validated by users; the heuristic is best-effort.

After this PR, an agent that triggers `login --auto` against a 2FA-protected site sees a clean `EXIT_AUTH_INTERACTIVE_REQUIRED` (25) within seconds rather than a 15s timeout + cryptic "no matching submit button" error. TOTP-driven 2FA (where the agent itself can produce the code) is part 4.

Untouched per scope discipline: every other adapter, router rules, common.sh exit codes (already had `EXIT_AUTH_INTERACTIVE_REQUIRED=25`), `scripts/browser-creds-*.sh`, all verb scripts other than `browser-login.sh`.

### Phase 5 part 3-iii — `--auth-flow` declaration at `creds add` time

- [feat] `scripts/browser-creds-add.sh` — new `--auth-flow STR` flag. Allowed values: `single-step-username-password` (default — backwards compatible), `multi-step-username-password`, `username-only`, `custom`. Persisted in cred metadata. Pre-3-iii the field was hardcoded to `single-step-username-password` regardless of the actual site flow.
- [feat] `scripts/browser-login.sh` — `--auto` reads `cred_meta.auth_flow` and refuses any value other than `single-step-username-password` with a clear hint pointing at `--interactive`. Pre-3-iii, `--auto` would attempt single-step selectors against any auth flow → fail mid-flight on the password field selector. Now the refusal is up-front + actionable.
- [internal] `tests/creds-add.bats` (+5 cases) — default flow, 3 valid values persisted, invalid value rejected with EXIT_USAGE_ERROR.
- [internal] `tests/login.bats` (+4 cases) — 3 refuse-on-non-standard cases (multi-step, username-only, custom), 1 regression test for single-step still working via dry-run path. `_seed_auto_cred` helper extended with optional 5th arg for auth_flow.
- [docs] `SKILL.md` — `creds add` row mentions `--auth-flow STR` flag.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-iii-auth-flow-detection.md` — phase plan.

**Out of scope (deferred):**
- **Auto-observation at add time** — open the site's login URL, scrape DOM, infer the flow shape. Substantial: needs a headless browser dispatch + heuristics. Could land as a 3-iii follow-up if user demand surfaces.
- **Multi-step / username-only auto-relogin support in playwright-driver** — needs different selector strategies in `runAutoRelogin`. Substantial enough to warrant its own sub-part (call it 3-iii-ii: multi-step support).

After this PR, `login --auto` fails fast on credentials whose `auth_flow` declares a non-standard shape — preserving the agent's time and emitting a clear hint instead of cryptic Playwright selector errors. The harness is ready when 3-iii-ii lands the actual multi-step replay logic.

Untouched per scope discipline: `scripts/lib/credential.sh` (schema unchanged — auth_flow field already in metadata), `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` (selector strategies unchanged), all other verb scripts, all adapters.

### Phase 5 part 3-ii (cont.) — Wire `invoke_with_retry` into all remaining session-aware verbs

- [feat] `scripts/browser-open.sh` / `browser-click.sh` / `browser-fill.sh` / `browser-inspect.sh` / `browser-audit.sh` / `browser-extract.sh` — all 6 swap their `tool_${verb}` adapter call for `invoke_with_retry ${verb}`. Mechanical churn replicating the pattern shipped for `browser-snapshot.sh` in the previous sub-PR. Now session expiry → silent re-login → retry is uniform across the verb surface.
- [security] No new exit code paths; no new privacy boundaries. The retry helper's gate (`_can_auto_relogin`: requires ARG_SITE + cred metadata `auto_relogin: true`) means non-session invocations are no-ops — preserving the existing behavior of every verb when invoked without `--site`.
- [internal] No new tests — `tests/verb-retry.bats` already exercises the helper logic. Per-verb integration would require adapter-side runtime expiry detection (which still doesn't ship — adapters don't yet emit 22 mid-flight). When that lands, integration tests follow.

`browser-login.sh` deliberately NOT wired: login IS the relogin mechanism. Wrapping it in retry would risk infinite recursion (login fails → retry → login --auto → calls login → …). Login's own error handling is the right boundary.

After this PR, any verb invoked with `--site` (and a cred backing the resolved cred name) gets transparent session-expiry recovery for free. The harness is complete; adapter-side detection is the next layered concern.

Untouched per scope discipline: `scripts/browser-snapshot.sh` (already wired in part 3-ii's helper PR), `scripts/browser-login.sh` (intentionally unwired), `scripts/browser-doctor.sh` + every other non-session verb, all adapters, router rules.

### Phase 5 part 3-ii — Transparent verb-retry on EXIT_SESSION_EXPIRED (helper + snapshot wired)

- [feat] new `scripts/lib/verb_helpers.sh::invoke_with_retry VERB ARGS...` — wraps `tool_${VERB} ARGS`, returning its stdout + exit code. On `EXIT_SESSION_EXPIRED` (22), if a credential with `auto_relogin: true` exists for the resolved `--site` / `--as`, runs `bash browser-login.sh --auto` silently then retries the verb EXACTLY ONCE. Per parent spec §4.4 — every verb call → silent re-login → retry, exactly one attempt. Caller sees a single stdout + final rc.
- [feat] new gating helpers: `_can_auto_relogin` (checks ARG_SITE + cred metadata.auto_relogin: true), `_resolve_relogin_cred_name` (mirrors session resolution: ARG_AS → site.default_session), `_silent_relogin` (shells to login --auto for the resolved cred). All composed inside `invoke_with_retry` so the call site is one line.
- [feat] `scripts/browser-snapshot.sh` — wired into `invoke_with_retry` as exemplar. Other verbs (open / click / fill / inspect / audit / extract / login) deferred to follow-up sub-PR (mechanical churn, easier to review separately).
- [internal] new `tests/verb-retry.bats` (6 cases) — unit-tests the helper via bash function mocking + counter file: tool returning 0 (no retry), tool returning rc≠22 (no retry), tool returning 22 + no auto-relogin context (no retry), tool returning 22 + relogin OK + retry succeeds (final rc=0), tool returning 22 + relogin fails (no retry, original error propagated), tool returning 22 twice (final rc=22 — no triple-call).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-ii-verb-retry.md` — phase plan.

After this PR, session expiry on `bash scripts/browser-snapshot.sh --site app` is invisible to the agent: cookie revoked → adapter exits 22 → verb re-logins via stored cred → retry succeeds → user sees the snapshot result. The pattern is now ready to replicate across the other 7 verbs.

**Out of scope (deferred to 3-ii follow-ups):**
- Wiring `invoke_with_retry` into `open` / `click` / `fill` / `inspect` / `audit` / `extract` / `login` — mechanical replication of the snapshot edit. Will land as a single PR.
- End-to-end integration test (real adapter that detects expiry + real login --auto + real cred). Adapter-side detection logic (e.g. checking landed-on-login-page after navigate) is itself a separate concern; the helper is harness-ready when adapters start emitting 22.

Untouched per scope discipline: adapters, router rules, common.sh, credential.sh (already had auto_relogin field default-true from part 2d), session/site libs, every verb script except snapshot.

### Phase 5 part 1f — Chrome `--user-data-dir` passthrough for cdt-mcp

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `mcpSpawnArgs()` helper. When `CHROME_USER_DATA_DIR` env var is set, the bridge forwards `--user-data-dir DIR` to the spawned upstream MCP child. Used at all 3 spawn sites: `runStatelessOneShot`, `withMcpClient` (one-shot multi-call), and `daemonChildMain`. Without the env var: no flag is added (current behavior preserved).
- [feat] **Session loading for cdt-mcp.** Chrome's native session mechanism is `--user-data-dir` (a profile directory containing cookies, localStorage, extensions), not playwright-lib's `storageState` JSON. Users now have a path to use logged-in profiles with cdt-mcp: log in once with real Chrome at a known directory, then `export CHROME_USER_DATA_DIR=/path/to/profile` before running verb scripts.
- [internal] `tests/stubs/mcp-server-stub.mjs` — logs `process.argv.slice(2)` to MCP_STUB_LOG_FILE on startup, so bats can verify the bridge's spawn-arg forwarding.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+2 cases) — `CHROME_USER_DATA_DIR` forwards `--user-data-dir DIR`; absence → no flag in spawn (regression guard).
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1 case) — daemon child also receives the forwarded flag.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — new "Session loading" subsection with copy-paste recipe; `CHROME_USER_DATA_DIR` row added to env-var table.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1f-user-data-dir.md` — phase plan.

**Out of scope (1f-i minimal — passthrough only):**
- `bash scripts/browser-login.sh --user-data-dir-mode` (capture a profile dir via cdt-mcp). User provides the directory themselves.
- Session resolver hooks (`resolve_session_user_data_dir`) for verb scripts to auto-export the env var per `--site` / `--as`. Could land in a follow-up if user demand surfaces.

After this PR, **Phase 5 part 1 (cdt-mcp track) is feature-complete**: 8/8 verbs real-mode, router promotion (Path B), verb scripts, daemon dispatch, session loading. The HANDOFF queue's remaining items are the auth track (parts 3-ii through 4: transparent verb-retry on session expiry, auth-flow detection, 2FA detection, TOTP).

Untouched per scope discipline: all adapters' capability declarations (env var is bridge-internal), all verb scripts (no flag changes — env var is the surface), router rules, login flow, session/credential libs.

### Phase 5 part 1e-ii — Bridge dispatch for `inspect` + `extract` real-mode (8/8 cdt-mcp verbs)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `inspect` and `extract` work real-mode end-to-end. Pre-1e-ii both verbs exited 41 with hint pointing at part 1e. Now they route through the daemon when one is running, or one-shot via the new `withMcpClient(fn)` helper otherwise. Both paths share `dispatchInspect(mcpCall, msg)` and `dispatchExtract(mcpCall, msg)`.
- [feat] **Inspect = multi-tool composition.** Per-flag MCP-call mapping: `--capture-console` → `list_console_messages` → `console_messages` field; `--capture-network` → `list_network_requests` → `network_requests`; `--screenshot` → `take_screenshot` → `screenshot_path`; `--selector CSS` → `evaluate_script` (with `document.querySelectorAll`) → `matches`. Multi-flag = sequential MCP calls aggregated into one summary JSON.
- [feat] **Extract = single `evaluate_script` call.** `--selector CSS` wraps in `querySelectorAll` → `textContent.trim()` → joined; `--eval JS` passes the raw script through. Both flags acceptable (eval can use the selector via DOM API).
- [feat] **Refactor: `makeMcpCall(child, reader, startId)` factory** extracted to top level. The daemon's previously-inline `mcpCall` closure now uses the factory; the new one-shot `withMcpClient(fn)` helper also uses it. One id-tracking implementation; two callers.
- [feat] cdt-mcp adapter now real-mode for **all 8 declared verbs**: `open`, `snapshot`, `eval`, `audit`, `inspect`, `extract` work one-shot or daemon-routed; `click`, `fill` require a running daemon (refMap precondition).
- [internal] `tests/stubs/mcp-server-stub.mjs` — added `list_console_messages` (2 canned messages), `list_network_requests` (1 canned request), `take_screenshot` (canned path) tool handlers. evaluate_script handler unchanged.
- [internal] `tests/chrome-devtools-bridge_real.bats` — replaced 2 exit-41 tests for inspect/extract with 6 happy-path real-mode tests (one-shot path).
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` — added 5 cases covering inspect (capture-console / multi-flag / screenshot) and extract (selector / eval) via daemon. `attached_to_daemon: true` asserted on inspect to verify daemon-routing.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — per-verb table reflects real-mode for all 8 verbs; multi-flag aggregation documented.
- [docs] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_doctor_check` — note bumped: 8/8 verbs.
- [docs] `SKILL.md` — inspect/extract rows simplified (no longer "deferred").
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1e-ii-bridge-inspect-extract.md` — phase plan.

After this PR, the cdt-mcp adapter's full surface is real. The remaining HANDOFF queue items are Path B routing extensions (already shipped via 1d's rules) + Phase 5 parts 1f / 3-ii / 3-iii / 3-iv / 4. CI green on macos+ubuntu (499 tests; +9 over 1e-i's 490 — 11 new tests minus 2 deleted exit-41 tests).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged — already declared inspect/extract), `scripts/lib/common.sh`, every credentials/session/site lib, every verb script (`scripts/browser-inspect.sh` and `scripts/browser-extract.sh` from 1e-i pass argv through unchanged — bridge changes are transparent).

### Phase 5 part 1e-i — Verb scripts: browser-audit + browser-extract (un-skip browser-inspect.bats)

- [feat] new `scripts/browser-audit.sh` — `audit` verb script. Flags: `--lighthouse` (default when no flag given), `--perf-trace`. Routes to chrome-devtools-mcp by default per 1d's `rule_audit_or_perf`. **Ships real-mode end-to-end** because the bridge already supports `audit` → `lighthouse_audit` (part 1c). Bare `bash scripts/browser-audit.sh` runs the default lighthouse path.
- [feat] new `scripts/browser-extract.sh` — `extract` verb script. Flags: `--selector CSS`, `--eval JS` (one required, both acceptable). Routes to chrome-devtools-mcp by default per 1d's `rule_extract_default`. Real-mode dispatch (no `BROWSER_SKILL_LIB_STUB=1`) still exits 41 — bridge daemon dispatch for `extract` lands in **part 1e-ii**.
- [feat] `scripts/browser-inspect.sh` — flag set updated to match cdt-mcp's declared `inspect` capabilities: `--capture-console`, `--capture-network`, `--screenshot`, `--selector CSS`. At least one is required. Pre-1e-i, the script required `--selector` (a Phase-2 assumption from when only playwright-cli existed). Real-mode dispatch still exits 41 — also part 1e-ii.
- [internal] new `tests/browser-audit.bats` (5 cases) — lib-stub mode coverage via existing `audit --lighthouse` fixture. Covers happy path, summary shape, ghost-tool rejection, dry-run, capability-filter rejection of `--tool=playwright-cli` for audit.
- [internal] new `tests/browser-extract.bats` (6 cases) — same shape via existing `extract --selector .title` fixture. Adds the missing-flag (`extract` with neither `--selector` nor `--eval`) usage error.
- [internal] `tests/browser-inspect.bats` un-skipped (was skipped pre-Phase-5 with comment "no adapter until Phase 5"). Re-aimed at cdt-mcp lib-stub mode using existing `inspect --capture-console` fixture. 4 cases: happy path, summary shape, ghost-tool rejection, dry-run.
- [docs] `SKILL.md` — new `audit` + `extract` rows; `inspect` row updated to reflect the broader flag set.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1e-i-audit-extract-scripts.md` — phase plan.

After this PR, the CLI surface for `audit` / `extract` / `inspect` is first-class — no `--tool=` needed. Audit works real-mode end-to-end (lighthouse via the bridge's existing one-shot path); extract and inspect work in lib-stub mode (existing fixtures); their real-mode dispatch lands in part 1e-ii where the bridge daemon gains `inspect` and `extract` handlers. CI green on macos+ubuntu (490 tests; +11 over 1d's 479).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/tool/*.sh` (no capability changes — adapter already declared all three verbs), `scripts/lib/node/chrome-devtools-bridge.mjs` (deferred to 1e-ii), `scripts/lib/common.sh`, every credentials/session/site lib, every existing verb script.

### Phase 5 part 1d — Router promotion (chrome-devtools-mcp Path B)

- [feat] `scripts/lib/router.sh` — four new routing rules promote chrome-devtools-mcp from "opt-in via `--tool=`" to a router default per parent spec Appendix B:
  - `rule_capture_flags` — `--capture-console` / `--capture-network` on any verb routes to chrome-devtools-mcp.
  - `rule_audit_or_perf` — verb=`audit` OR `--lighthouse` / `--perf-trace` flags route to chrome-devtools-mcp.
  - `rule_inspect_default` — verb=`inspect` routes to chrome-devtools-mcp.
  - `rule_extract_default` — verb=`extract` routes to chrome-devtools-mcp. (`--scrape <urls...>` → obscura when it lands in Phase 8 — prepend a higher-precedence rule above; no edits needed here.)
- [feat] `ROUTING_RULES` reordered: session_required → capture_flags → audit_or_perf → inspect_default → extract_default → default_navigation. session_required still wins above the capture rules (preserves existing playwright-lib behavior for site/session use); the new rules slot above `default_navigation` so capture-flag combos on `open` / `click` / `fill` / `snapshot` route to chrome-devtools-mcp instead of playwright-cli.
- [internal] `tests/router.bats` (+10 cases) — capture-console / capture-network on snapshot, audit no-flag, --lighthouse and --perf-trace on snapshot, inspect default, extract default, capture wins over default-navigation, plain `open` regression guard, session-required wins over capture-flag, --tool=playwright-cli for inspect still rejected by capability filter.
- [internal] `tests/routing-capability-sync.bats` — drift guard extended to cover `audit` / `inspect` / `extract` (was: open / click / fill / snapshot only). Catches future regressions where a rule routes to a tool that doesn't declare the verb.
- [internal] Existing test "pick_tool audit (no --tool) falls through, dies EXIT_TOOL_MISSING" replaced with the new "verb=audit routes to chrome-devtools-mcp" (the pre-1d fall-through was the absence of this rule).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — "When the router picks this adapter" table reflects the new defaults; documents the session+capture limitation (session wins; capture flags silently ignored — resolution path is part 1f).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1d-router-promotion.md` — phase plan.

After this PR, `bash scripts/browser-snapshot.sh --capture-console` (or any verb with `--capture-*`) routes to chrome-devtools-mcp without `--tool=`. `bash scripts/browser-audit.sh` (when part 1e ships the script) will dispatch via the router automatically. The promotion is now meaningful because part 1c-ii made chrome-devtools-mcp's stateful verbs work via daemon — the router can confidently send click/fill traffic there too. No adapter changes; no verb script changes; the routing change is transparent to callers.

Untouched per scope discipline: every adapter file (`scripts/lib/tool/*.sh` capabilities unchanged), every verb script (`scripts/browser-*.sh` — they call `pick_tool VERB` and pick up the new routing for free), `scripts/lib/node/chrome-devtools-bridge.mjs`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, every credentials/session/site lib, `tests/lint.sh`.

### Phase 5 part 1c-ii — chrome-devtools-mcp daemon + ref persistence (click/fill)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — daemon mode lands. New verbs `daemon-start` / `daemon-stop` / `daemon-status` mirror `playwright-driver.mjs`'s lifecycle precedent. The daemon spawns ONE long-lived MCP server child, performs the `initialize` handshake once, holds the `eN ↔ uid` ref map, and exposes verb dispatch over a TCP loopback IPC server (`127.0.0.1:0` ephemeral port — Unix sun_path 104-char cap on macOS bats temp paths). State persisted at `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json` (mode 0600, dir 0700).
- [feat] **Stateful verbs `click` and `fill` work end-to-end via real MCP** when daemon is running. `bridge.mjs click eN` resolves `eN → uid` from the cached refMap (populated by the prior `snapshot`) and calls MCP `tools/call name=click args={uid}`. Without daemon → exit 41 with hint pointing at `daemon-start`. The remaining stateful verbs (`inspect` / `extract`) still exit 41 — bundled with their verb scripts in part 1e.
- [feat] **Stateless verbs route through the daemon when one is running** so the same MCP server child + Chrome state are reused across calls. Without daemon, the original part-1c one-shot path runs unchanged.
- [security] Privacy: `fill --secret-stdin` reads the secret from stdin only (never argv per AP-7). Daemon-side reply scrubs any echoed text from the MCP error path (`<redacted>` substitution mirroring `playwright-driver.mjs`). Sentinel canary `sekret-do-not-leak-CDT-1c-ii` verified absent from the skill's stdout summary.
- [internal] new `tests/chrome-devtools-mcp_daemon_e2e.bats` (12 cases) — daemon lifecycle (status / start / running / idempotent start / stop / stop-when-none), click via daemon (no-daemon hint, ref-translation happy path, unknown-ref error), fill via daemon (happy path, secret-stdin canary, no-daemon hint). Defensive setup: `CHROME_DEVTOOLS_MCP_BIN=${STUBS_DIR}/mcp-server-stub.mjs` exported in `setup()` (HANDOFF §60 pattern); `teardown()` always runs `daemon-stop || true`.
- [internal] `tests/stubs/mcp-server-stub.mjs` — added `click` and `fill` `tools/call` handlers (echo `uid` + `text` in their content text). The stub log captures the wire so bats can assert `eN → uid` translation server-side.
- [internal] `tests/chrome-devtools-bridge_real.bats` — updated 2 stateful exit-41 tests: now asserts the new `requires running daemon` hint (replaces the part 1c "deferred to 1c-ii" wording).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — Status section + per-verb table updated; new "Daemon mode (phase-05 part 1c-ii)" subsection with copy-paste recipe; Limitations section trimmed (real MCP transport no longer "deferred").
- [docs] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_doctor_check` — note bumped: stateless verbs one-shot, click/fill via daemon-start.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1c-ii-cdt-mcp-daemon.md` — phase plan.

After this PR, the cdt-mcp adapter unblocks downstream work: `--tool=chrome-devtools-mcp` exposes 6 of 8 verbs in real mode (4 stateless + click + fill). The remaining 2 (`inspect` / `extract`) wait for part 1e where the verb scripts and daemon dispatch land together. Path B router promotion (part 1d) and Chrome `--user-data-dir` session loading (part 1f) remain queued.

Untouched per scope discipline: `scripts/lib/router.sh` (Path A still — promotion deferred to part 1d), `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/verb_helpers.sh`, every `scripts/browser-*.sh` (verb scripts unchanged — they shell to the adapter; the adapter shells to the bridge; the bridge handles IPC), every other adapter file, `tests/lint.sh`.

### Phase 5 part 3 — `login --auto` auto-relogin from stored credentials

- [feat] `scripts/browser-login.sh --auto` — programmatic headless login using the credential set via `creds-add`. Reads username from credential metadata, password via `credential_get_secret` (dispatches to whichever backend the cred uses — plaintext / keychain / libsecret). Sends `username\0password` to the driver via stdin per AP-7 (secret never on argv). Mutually exclusive with `--interactive` and `--storage-state-file`. Validates: cred exists, cred bound to `--site`, `auto_relogin=true`, `account` non-empty.
- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — reads NUL-separated `username\0password` from stdin, launches headless chromium, navigates to site URL, fills best-effort form selectors (`input[type=email]`, `input[type=password]`, `button[type=submit]`, etc.), clicks submit, waits for navigation/network-idle (15s budget), captures `storageState`, writes to `--output-path`.
- [security] AP-7 STRICT: secret reaches driver via stdin pipe only. `printf '%s\0' "${account}"` precedes `credential_get_secret "${as}"` in the pipeline; combined stdin is exactly `account\0password`. Never appears in process argv.
- [security] Privacy: `--auto --dry-run` summary JSON contains `account` (the username, NOT the password) plus standard verb/tool/why/status/duration_ms/site/session keys. Sentinel canary `sekret` verified absent from `--dry-run` output.
- [internal] `tests/login.bats` — replaced the obsolete "--auto refused in Phase 2" test with 7 new `--auto` cases: mutex with `--interactive`, mutex with `--storage-state-file`, `--site` required, missing cred (exit 23), `auto_relogin=false` refusal, site-mismatch refusal, `--dry-run` happy path. Each test pre-creates the plaintext-acknowledged marker + exports keychain/libsecret stubs (defensive — preserves the lesson from part 2b).
- [docs] `SKILL.md` — added `login (auto)` row.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-3-auto-relogin.md` — phase plan.

The auth track now actually saves typing: stored credentials → one CLI invocation → fresh session captured. Stateless single-step username+password flows work via best-effort selectors. Multi-step / 2FA / non-standard form sites need future part 3-iii (auth-flow detection at creds-add time) or fall back to `--interactive`.

**Out of scope (deferred to follow-ups)**:
- **Transparent verb-retry on `EXIT_SESSION_EXPIRED`** (parent spec §4.4 silent re-login on every verb call) — Phase 5 part 3-ii.
- **Auth-flow detection at `creds add` time** — Phase 5 part 3-iii.
- **2FA detection → exit 25** — Phase 5 part 3-iv.
- Real-browser bats tests (no stub) — gated like `--interactive`'s; manual / future-CI.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh` (verb-retry deferred), `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/tool/*.sh`, `scripts/lib/node/chrome-devtools-bridge.mjs`, `scripts/browser-doctor.sh`, every `scripts/browser-creds-*.sh`, every other adapter file, `tests/lint.sh`.

### Phase 5 part 1c — chrome-devtools-mcp real MCP stdio transport (stateless verbs)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::realDispatch` — implemented. Bridge spawns `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}` with stdio piped, performs MCP `initialize` handshake (protocol version `2024-11-05`), translates verb argv → `tools/call`, shapes response into skill summary JSON, cleanly shuts down. JSON-RPC 2.0 NDJSON wire protocol per MCP stdio convention.
- [feat] **Stateless verbs work end-to-end via real MCP**: `open` → `navigate_page`, `snapshot` → `take_snapshot`, `eval` → `evaluate_script`, `audit` → `lighthouse_audit` (60s timeout for lighthouse). uid → eN translation at adapter boundary for snapshot output (per token-efficient-output spec §5); the original upstream `uid` is preserved on each ref for traceability.
- [feat] **Stateful verbs (click/fill/inspect/extract) return exit 41** with self-healing hint pointing at part 1c-ii. They need eN → uid persistence across calls; without daemon-mode (planned next), each bridge process starts fresh and has no ref map. Hint message specifically calls out part 1c-ii so users know where the capability lands.
- [internal] new `tests/stubs/mcp-server-stub.mjs` — mock MCP server speaking JSON-RPC 2.0 NDJSON over stdio. Handles `initialize` + `notifications/initialized` + `tools/call` for the 4 stateless tools. Logs each received line to `${MCP_STUB_LOG_FILE}` so bats can assert handshake order. Lets bats run on macos + ubuntu CI without `npx chrome-devtools-mcp@latest` (which needs network + Chrome).
- [internal] `tests/chrome-devtools-bridge_real.bats` (13 cases) — real-mode integration via mock: BROWSER_SKILL_LIB_STUB=1 regression guard, initialize-before-tools/call ordering verified via stub log, all 4 stateless verbs, all 4 stateful verbs return 41, bad-args paths, missing-MCP-bin path.
- [bugfix] Initial implementation hit a JS temporal-dead-zone bug — `realDispatch(argv)` was invoked at module top before the `const TIMEOUT_MS` declarations below ran; the async function body's synchronous prelude referenced consts in TDZ → `ReferenceError`. Fix: move the entry-point invocation to the very end of the module (after all consts initialize).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — updated Status section + per-verb real-mode behavior table; deferred-stateful note points at part 1c-ii.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-1c-cdt-mcp-transport.md` — phase plan.

After this PR, `bash scripts/browser-<verb>.sh --tool=chrome-devtools-mcp` actually works for the 4 stateless verbs against a real upstream MCP server (`npx chrome-devtools-mcp@latest` or any wrapper at `${CHROME_DEVTOOLS_MCP_BIN}`). Routing promotion (Path B) stays deferred to part 1d; verb scripts (audit/extract/inspect un-skip) to part 1e.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/verb_helpers.sh`, `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged), `scripts/browser-doctor.sh`, every `scripts/browser-*.sh`, every other adapter file, `tests/lint.sh`.

### Phase 5 part 2e — `migrate-credential` cross-backend moves

- [feat] new `scripts/browser-creds-migrate.sh` — move a credential from one backend to another. CLI: `creds-migrate --as CRED_NAME --to BACKEND [--yes-i-know] [--yes-i-know-plaintext] [--dry-run]`. Mirrors `creds-remove`'s typed-name confirmation UX exactly.
- [feat] `scripts/lib/credential.sh` — new `credential_migrate_to NAME NEW_BACKEND` public primitive + new `_credential_dispatch_to BACKEND OP NAME` internal helper. Existing `_credential_dispatch_backend` refactored to delegate to the new helper (DRY: one dispatcher implementation, two entry points).
- [security] **Fail-safe ordering**: `credential_migrate_to` reads from old backend → writes to new backend → deletes from old → updates metadata. If the new-backend write fails (e.g. keychain unavailable), the original credential remains intact. If the old-backend delete fails AFTER a successful new-write, both backends transiently hold the secret — verb logs a warning, doesn't crash; user can manually clean up.
- [security] **First-use plaintext gate inherited from creds-add**: migrating TO plaintext requires `--yes-i-know-plaintext` (or a pre-existing acknowledgment marker). Closes the bypass-via-migrate hole that the part-2d-iii insight flagged. Successful migrate-to-plaintext also touches the marker so subsequent plaintext ops skip the gate silently (consistent with creds-add behavior).
- [security] Privacy invariant: summary JSON NEVER includes the secret value. Sentinel canary `sekret-do-not-leak-migrate` asserted absent from output.
- [internal] `tests/credential.bats` (+6 cases) — `credential_migrate_to` lib coverage: each backend pair (plaintext↔keychain↔libsecret), same-backend refusal, unknown-backend refusal, byte-exact secret preservation across migration.
- [internal] `tests/creds-migrate.bats` (11 cases) — verb integration: 3 backend pair migrations + plaintext-gate inheritance (refusal + acceptance) + same-backend refusal + unknown credential + unknown backend + typed-name mismatch + `--dry-run` + summary JSON shape + privacy canary.
- [docs] `SKILL.md` — added `creds migrate` row.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2e-migrate-credential.md` — phase plan.

**Phase 5 part 2 is now feature-complete.** All 5 credentials verbs shipped (`creds add/list/show/remove/migrate`), all 3 Tier-1 backends real (plaintext/keychain/libsecret), smart per-OS auto-detect, masked reveal, first-use plaintext gate uniformly enforced (creds-add + creds-migrate), doctor surface. Only auto-relogin (Phase 5 part 3) and TOTP (Phase 5 part 4) remain in the broader phase.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/browser-doctor.sh`, every other `scripts/browser-*.sh` (existing 4 creds verbs unchanged), every adapter file, `tests/lint.sh`.

### Phase 5 part 2d-iii — `mask.sh` + `creds show --reveal` + first-use plaintext gate

- [feat] new `scripts/lib/mask.sh` — reusable masking helper. `mask_string VAL [SHOW_FIRST=1] [SHOW_LAST=1]`. Examples: `"password123"` → `"p*********3"`; short strings (≤2 chars) → all stars (no leak); very-long strings cap at 80 middle stars to keep masked rendering bounded. Used by `creds show --reveal` for the masked preview alongside the unmasked value; reusable for any future verb that needs to render a sensitive value safely.
- [feat] `scripts/browser-creds-show.sh` — new `--reveal` flag. Default behavior unchanged (metadata only — privacy invariant from part 2d-ii holds). With `--reveal`: typed-phrase confirmation (mirror remove-session UX — user types credential name back via stdin), on match → emit `secret` + `secret_masked` keys alongside `meta`; on mismatch → die `EXIT_USAGE_ERROR`. Mismatch path verified to NOT leak the secret value in error output.
- [security] `creds show --reveal` works for all 3 backends (plaintext, keychain via stub, libsecret via stub). The masked preview lets the user confirm visually they revealed the right credential without re-leaking the value. Regression guard: `creds show` WITHOUT `--reveal` continues to refuse `secret`/`secret_masked` keys in output.
- [feat] `scripts/browser-creds-add.sh` — new `--yes-i-know-plaintext` flag + first-use plaintext gate. Per parent spec §1, plaintext is paper security without disk encryption — the first plaintext add now requires explicit acknowledgment. Marker file `${CREDENTIALS_DIR}/.plaintext-acknowledged` (mode 0600) tracks acknowledgment; subsequent plaintext adds skip the gate silently. Non-plaintext backends (keychain/libsecret) unaffected.
- [internal] `tests/mask.bats` (8 cases) — covers standard / empty / 1-char (no leak) / 2-char (no leak) / 3-char / custom bounds / 200-char (capped output).
- [internal] `tests/creds-show.bats` (+4 cases) — `--reveal` typed-phrase match (secret + masked emitted), `--reveal` mismatch (no leak in error path), `--reveal` works on keychain backend, regression guard for non-reveal path.
- [internal] `tests/creds-add.bats` (+4 cases) — plaintext gate refuses without flag, `--yes-i-know-plaintext` bypasses + creates marker, marker-pre-existing path silent, keychain/libsecret backends skip the gate. setup() pre-creates the marker so existing plaintext-backend tests don't hit the gate.
- [docs] `SKILL.md` — added `creds show --reveal` row; updated `creds add` row to mention `--yes-i-know-plaintext`.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-iii-mask-and-reveal.md` — phase plan.

After this PR, the auth track's security/UX gaps are closed: secret disclosure is gated behind a typed-phrase confirmation; plaintext-on-disk requires explicit user acknowledgment. The `migrate-credential` cross-backend move (part 2e) is the last remaining auth-track verb.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/browser-doctor.sh`, `scripts/browser-creds-list.sh`, `scripts/browser-creds-remove.sh`, every adapter file, `tests/lint.sh`.

### Phase 5 part 2d-ii — `creds list/show/remove` verbs

- [feat] new `scripts/browser-creds-list.sh` — walk `${CREDENTIALS_DIR}` and emit a single-line summary JSON listing all credentials. Optional `--site NAME` filter mirrors `list-sessions`. Each row carries `{credential, site, account, backend, auto_relogin, totp_enabled, created_at}` — metadata only; NEVER includes the secret payload (privacy invariant tested with sentinel canary `sekret-do-not-leak-list`).
- [feat] new `scripts/browser-creds-show.sh` — emit one credential's metadata JSON. NEVER emits the secret value (privacy invariant — bats grep guard with sentinel canary `sekret-do-not-leak-show`). `--reveal` flow with typed-phrase confirmation deferred to part 2d-iii.
- [feat] new `scripts/browser-creds-remove.sh` — typed-name confirmation delete, mirroring `remove-session` UX exactly. `--yes-i-know` skips prompt; `--dry-run` reports without writing. Calls `credential_delete` which dispatches the secret-removal to the appropriate backend (plaintext: file unlink; keychain: `security delete-generic-password`; libsecret: `secret-tool clear`). Tests exercise all 3 backends via stubs.
- [internal] `tests/creds-list.bats` (6 cases), `tests/creds-show.bats` (7 cases), `tests/creds-remove.bats` (10 cases) — total 23 new cases. Each setup() unconditionally exports `KEYCHAIN_SECURITY_BIN` + `LIBSECRET_TOOL_BIN` stubs (defensive: preserves the lesson from part 2b's keychain-dialog incident — never let a test fall through to a real OS vault).
- [docs] `SKILL.md` — added 3 rows: `creds list`, `creds show`, `creds remove`.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-ii-creds-crud.md` — phase plan.

After this PR, the basic credential CRUD loop is complete: `creds add` (part 2d) → `creds list` / `creds show` (read; metadata-only) → `creds remove` (delete; backend-aware). The `--reveal` flow + `mask.sh` + first-use plaintext typed-phrase prompt land together in part 2d-iii where TTY-prompt patterns get factored. `migrate-credential` cross-backend moves stay in part 2e.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/credential.sh`, every `scripts/lib/secret/*.sh`, every adapter file, `scripts/browser-doctor.sh`, `scripts/browser-creds-add.sh`, `tests/lint.sh`.

### Phase 5 part 2d — `creds add` verb + smart backend select

- [feat] new `scripts/browser-creds-add.sh` — first user-visible auth verb. Registers a credential under `${CREDENTIALS_DIR}/<name>.{json,secret}`. CLI: `creds-add --site SITE --as CRED_NAME --password-stdin [--account ACCOUNT] [--backend keychain|libsecret|plaintext] [--auto-relogin true|false] [--dry-run]`. Validates site exists, cred name safe + not already registered. Auto-detects backend per OS if `--backend` not set.
- [security] AP-7 STRICT: `--password-stdin` is the **only** password-input path. NO `--password VALUE` flag. Lint-style grep test guards against future regression. Password reaches `credential_set_secret` via stdin pipe — never argv.
- [feat] new `scripts/lib/secret_backend_select.sh` — smart per-OS backend auto-detection per parent spec §1. `detect_backend` echoes `keychain` (Darwin + `security` on PATH), `libsecret` (Linux + `secret-tool` on PATH), or `plaintext` (fallback). `BROWSER_SKILL_FORCE_BACKEND` env override honored. Does NOT probe D-Bus reachability for libsecret (too brittle); user can override to `plaintext` if their Linux box has no agent.
- [feat] `scripts/browser-doctor.sh` — new advisory check after adapter aggregation. Walks `${CREDENTIALS_DIR}/*.json` and emits `credentials: N total (keychain: A, libsecret: B, plaintext: C)`. Does NOT increment `problems`; advisory only.
- [internal] `tests/creds-add.bats` (14 cases) — happy path × 3 backends + auto-detect + validation (existing cred / unknown site / unsafe name / missing required flags) + AP-7 grep guard + `--dry-run` + `--account` override + summary JSON shape. Defensive: setup() exports stub bins for keychain + libsecret unconditionally so no test can fall through to a real OS vault.
- [internal] `tests/secret_backend_select.bats` (8 cases) — env override, per-OS detection (Darwin/Linux/other) via a `uname -s` shim, missing-binary fallback to plaintext.
- [internal] `tests/doctor.bats` — added 2 cases: zero-credential state + per-backend breakdown line with hand-written metadata fixture.
- [bugfix] `scripts/lib/credential.sh` — `_CREDENTIAL_REQUIRED_FIELDS` changed from a space-separated string to a bash array. The string form was IFS-dependent: verb scripts set `IFS=$'\n\t'` (default protective hygiene), which silently broke `for field in ${_CREDENTIAL_REQUIRED_FIELDS}` word-splitting. Symptom: validation reported the entire string as one missing-field name. Array + `[@]` quoting is IFS-independent. Tests in part-2a passed because they ran in a `bash -c` subshell with default IFS; the bug surfaced when the verb script (the first IFS-strict caller) hit `credential_save`.
- [docs] `SKILL.md` — added `creds add` row to the verbs table.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-creds-add.md` — phase plan.

NO `creds list/show/remove` this PR — those follow the patterns established here in part 2d-ii. NO `mask.sh` + `--reveal` typed-phrase flow — part 2d-iii. NO `migrate-credential` — part 2e. NO interactive `read -s` password prompt — TTY-aware mocking in bats is complex; deferred. NO first-use plaintext typed-phrase confirmation prompt — lands with the TTY-prompt patterns in 2d-iii.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh`, `scripts/lib/secret/*.sh` (3 backends, all from parts 2a/2b/2c), every adapter file, `tests/lint.sh`, `tests/router.bats`.

### Phase 5 part 2c — Linux libsecret backend (secret-tool)

- [feat] new `scripts/lib/secret/libsecret.sh` — third (and final Tier-1) secret backend. Completes the per-OS roster: plaintext + keychain + libsecret. 4-fn API mirrors `keychain.sh` shape; shells to `${LIBSECRET_TOOL_BIN:-secret-tool}`; service prefix `${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}`; account = credential name. `secret_set` clear-then-store for idempotent overwrite; `secret_get` via `lookup`; `secret_delete` swallows missing-item exit-1 from `clear`; `secret_exists` probes via `lookup` to /dev/null.
- [security] AP-7 CLEAN — no documented exception. The upstream `secret-tool` CLI reads passwords from stdin natively (via `store` subcommand). The skill's own code pipes stdin directly into `secret-tool store`; password never appears in argv. Contrast with macOS keychain backend (`secret/keychain.sh`) which has a documented AP-7 exception due to the upstream `security` CLI's argv-only design.
- [feat] `scripts/lib/credential.sh` dispatcher: `libsecret` branch shifts from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch. **All three backend branches now dispatch to real implementations** — no placeholders remain in `_credential_dispatch_backend`.
- [internal] new `tests/stubs/secret-tool` — bash mock of `secret-tool` CLI. Supports `store/lookup/clear` with attr=val pairs (`service`, `account`). State in `${LIBSECRET_STUB_STORE}` (per-test isolated tempfile). Reads PW from stdin verbatim (no trailing-newline strip). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Lets bats run on macos-latest CI (no libsecret) and ubuntu-latest CI (no D-Bus session) identically.
- [internal] `tests/secret_libsecret.bats` (13 cases) — full backend coverage: AP-7-clean header guard (asserts the absence of "AP-7 documented exception" + presence of stdin-clean affirmation), stdin-roundtrip, idempotent delete, multi-secret, last-write-wins (clear-then-store), service prefix override, byte-exact verbatim roundtrip.
- [internal] `tests/credential.bats` — replaced the part-2a "libsecret returns EXIT_TOOL_MISSING (deferred)" test with positive libsecret-roundtrip-via-stub test. Uses inline env-prefix style matching the existing keychain test.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2c-libsecret.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. Linux libsecret becomes the **per-OS-default backend on Linux** (when `secret-tool` is on PATH and a D-Bus Secret Service is reachable) once `creds add` lands in part 2d.

Backend roster after this PR (3 of 3 Tier-1 shipped; smart auto-detect lands in 2d):

| OS | Default backend | Fallback |
|---|---|---|
| Darwin | keychain (security CLI) | plaintext-with-typed-phrase |
| Linux (with libsecret) | libsecret (secret-tool) | plaintext-with-typed-phrase |
| Linux (no libsecret) / other | plaintext-with-typed-phrase | (none) |

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/lib/secret/keychain.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2b — macOS Keychain backend (security CLI)

- [feat] new `scripts/lib/secret/keychain.sh` — second secret backend. 4-fn API mirrors `plaintext.sh`. Shells to `${KEYCHAIN_SECURITY_BIN:-security}`; service prefix `${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}`; account = credential name. `secret_set` reads stdin then calls `security add-generic-password -w "${secret}" -U`. `secret_get` echoes via `find-generic-password -w`. `secret_delete` idempotent (`|| true` swallows missing-item exit). `secret_exists` probes via `find-generic-password` without `-w`.
- [security] AP-7 documented exception: macOS `security` CLI takes the password on argv (`-w PASSWORD`); no clean stdin path in upstream tool. Mitigations documented in keychain.sh header — short-lived subprocess (~50ms), -U makes idempotent, Linux libsecret backend (part 2c) uses stdin-clean `secret-tool`. The skill's own code never puts secrets on argv; the leak surface is the brief `security` subprocess. Honest documented exception pattern, NOT silent compromise of the invariant.
- [feat] `scripts/lib/credential.sh` dispatcher: `keychain` branch shifted from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch (`source secret/keychain.sh; secret_${op}`). `libsecret` branch unchanged (still placeholder until 2c).
- [internal] new `tests/stubs/security` — bash mock of macOS `security` CLI. Supports `add/find/delete-generic-password` with `-s/-a/-w/-U` flag set the backend uses. State in `${KEYCHAIN_STUB_STORE}` (per-test isolated tempfile). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Mirrors `tests/stubs/playwright-cli` + `tests/stubs/chrome-devtools-mcp` (now-deleted) patterns. Lets bats run on Ubuntu CI without macOS keychain access.
- [internal] `tests/secret_keychain.bats` (13 cases) — full backend coverage: stdin-roundtrip, idempotent delete, multi-secret, last-write-wins, override of service prefix, AP-7 header-comment grep guard.
- [internal] `tests/credential.bats` — replaced the part-2a "keychain returns EXIT_TOOL_MISSING (deferred)" test with positive keychain-roundtrip-via-stub test. libsecret-deferred test stays (still placeholder until 2c).
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2b-keychain.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. macOS Keychain becomes the **per-OS-default backend on macOS** once `creds add` lands in part 2d (smart auto-detect: keychain on macOS, libsecret on Linux with libsecret installed, plaintext fallback otherwise).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2a — credentials foundation (lib + plaintext backend)

- [feat] new `scripts/lib/credential.sh` — credentials substrate. Eight public fns: `credential_save/load/meta_load/list_names/delete/exists/set_secret/get_secret`. Schema v1 (mirror session schema). Two files per credential: `<name>.json` for metadata (mode 0600, NEVER secret values) and `<name>.secret` for backend-owned payload. Backend dispatcher routes secret operations by `metadata.backend` field; sources backends on demand to keep parent-shell namespace clean.
- [feat] new `scripts/lib/secret/plaintext.sh` — first secret backend. Four fns: `secret_set/get/delete/exists`. AP-7-strict: secret material flows via stdin pipes only — never argv. Atomic writes (tmp + mv); mode 0600 files inside mode 0700 `${CREDENTIALS_DIR}`. Idempotent delete. Last-write-wins on overwrite (no implicit `--force` — caller's job to confirm via `credential_delete` first).
- [feat] backend dispatcher returns `EXIT_TOOL_MISSING` (21) with self-healing hint for `keychain` and `libsecret` backends — placeholders until those backends land in phase-05 part 2b (macOS Security framework via `security` CLI) and part 2c (Linux Secret Service via `secret-tool`).
- [security] `credential_load` privacy-invariant test: output MUST NOT contain a `secret` field or any secret value. `tests/credential.bats` asserts this with a sentinel value (`sekret-do-not-leak`) — guards against any future regression that conflates metadata with payload.
- [internal] `tests/credential.bats` (21 cases) + `tests/secret_plaintext.bats` (12 cases) — full lib + backend coverage including: file-mode invariants, dir-mode invariants, schema validation, dispatcher routing, deferred-backend exit codes, path-traversal rejection, AP-7 grep guard.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2a-creds-foundation.md` — phase plan.

NO verb scripts this PR. `creds add/list/show/remove` land in part 2d once the backend roster (2a/2b/2c) is complete. NO doctor changes — credential count comes in 2d when verbs trigger surface visibility.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md` (no new verbs to autogen), `tests/lint.sh`.

### Phase 5 part 1b — cdt-mcp bridge scaffold + lib-stub pivot

- [adapter] new `scripts/lib/node/chrome-devtools-bridge.mjs` — node ESM bridge between the chrome-devtools-mcp adapter and the upstream MCP server. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) performs sha256(argv) → `tests/fixtures/chrome-devtools-mcp/<sha>.json` lookup and echoes contents (matches the part-1 hashing form `printf '%s\0' "$@" | shasum -a 256` so existing fixtures work unchanged). Real-mode MCP transport (initialize handshake + `tools/call` + `uid → eN` translation) is deferred to phase-05 part 1c — bridge throws with a self-healing hint pointing at that part.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` rewired to shell to the bridge via a new `_drive` helper, mirroring `playwright-lib`'s shape exactly. Adapter no longer references `${CHROME_DEVTOOLS_MCP_BIN}` for verb dispatch; the env var still exists but its semantics shifted — it now means "the upstream MCP server binary the bridge spawns in real mode" (defaults to `chrome-devtools-mcp`).
- [adapter] `tool_doctor_check` pivoted from "bin on PATH" to "node on PATH + bridge file present" (mirror `playwright-lib::tool_doctor_check`). Includes a `note` field explaining real-mode transport is deferred to part 1c. Doctor now passes on plain CI without any env override (node is always present).
- [internal] deleted `tests/stubs/chrome-devtools-mcp` (~50 LOC of bash) — replaced by lib-stub mode in the bridge. Mirrors `playwright-lib`'s no-binary-stub model.
- [internal] reverted the part-1 additions to `tests/doctor.bats` (3 sites) and `tests/install.bats` (1 site) — `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` overrides are no longer needed because doctor now passes on node-and-bridge alone.
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases): env var pivoted from `CHROME_DEVTOOLS_MCP_BIN` to `BROWSER_SKILL_LIB_STUB=1`; one test renamed from "stub bin on PATH" to "node on PATH (no env override needed)". Argv-shape assertions via `STUB_LOG_FILE` unchanged — bridge logs argv to that file in stub mode for parity.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — new "Architecture" diagram (adapter → bridge → upstream); rewritten "Stub mode" section; new "Environment variables" reference table; "Limitations" section restructured to call out which sub-part lands each remaining capability.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md` — phase plan.

Untouched per Path A discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files (`playwright-cli.sh`, `playwright-lib.sh`), 8 fixtures under `tests/fixtures/chrome-devtools-mcp/`.

### Phase 5 part 1 — chrome-devtools-mcp adapter (Path A — opt-in)

- [adapter] added `scripts/lib/tool/chrome-devtools-mcp.sh` — third concrete adapter, third on the toolbox roster after `playwright-cli` and `playwright-lib`. Declares all 8 verbs (`open click fill snapshot inspect audit extract eval`) so `--tool=chrome-devtools-mcp` makes the full surface reachable today via the capability filter in `pick_tool`. The flagship verbs (`inspect`, `audit`, `extract`) are the long-term defaults per parent spec Appendix B; router promotion (Path B) is deferred to phase-05 part 1c per anti-pattern AP-4 (no same-PR promotion).
- [adapter] real-mode placeholder: the adapter shells to `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}`. The upstream is an MCP server (`npx chrome-devtools-mcp@latest`, JSON-RPC over stdio), not a CLI. The stdio bridge that wires the adapter to it is deferred to phase-05 part 1b.
- [adapter] `tool_fill --secret-stdin` is honored (unlike `playwright-cli` which exits 41) — passes the flag through to the bin, which reads stdin. Differentiates from `playwright-cli` (rejects stdin) and matches `playwright-lib` (driver reads stdin in node).
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases) — contract conformance + flagship verb declarations + happy-path verb dispatch via stub + missing-fixture exit-41 propagation + `--ref`-required guard.
- [internal] `tests/stubs/chrome-devtools-mcp` (mirror of `tests/stubs/playwright-cli`): `sha256(argv joined by NUL)` → fixture lookup; honors `--version` so doctor reports the bin as found under stub override.
- [internal] `tests/fixtures/chrome-devtools-mcp/<sha>.json` × 8 — covers inspect/audit/snapshot/eval/open/click/extract/fill argv shapes.
- [internal] `tests/doctor.bats` + `tests/install.bats` — added `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` alongside the playwright-cli stub so the `all checks passed` assertions stay true under the new adapter.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — when-to-use, capability declaration, opt-in syntax, stub-mode notes, deferred-bridge call-out.
- [docs] `SKILL.md` + `references/tool-versions.md` — autogenerated 3rd adapter row.
- [docs] `docs/superpowers/plans/2026-05-01-phase-05-part-1-chrome-devtools-mcp.md` — phase plan.

Untouched per Path A discipline (recipe + AP-4): `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files.

### Phase 4 part 4e — show-session + remove-session verbs (full session CRUD)

- [feat] `scripts/browser-show-session.sh` — emits session metadata (origin, captured_at, expires_in_hours, source_user_agent) plus storage_state counts (cookie_count, origin_count, file_size_bytes). **CRITICAL:** never emits cookie/token values; the agent has no business seeing raw session material. Test asserts cookie values do not leak into output.
- [feat] `scripts/browser-remove-session.sh` — typed-name confirmed delete of session storageState + meta. Mirrors `remove-site` ergonomics: `--yes-i-know` skips prompt, `--dry-run` reports planned action. Does NOT clear `site.default_session` pointers (cascade is Phase 5); dangling pointers surface clearly via `resolve_session_storage_state`'s self-healing hint at next use.
- [feat] `scripts/lib/session.sh::session_delete` — new lib helper. Idempotent (no-op on missing files), `assert_safe_name` guards path-traversal.
- [docs] `SKILL.md` verbs table gains `show-session` + `remove-session` rows.
- [internal] `tests/show-remove-session.bats` (10) — full coverage incl. cookie-value-leak guard. `tests/session.bats` (+3) — session_delete unit tests.

Session CRUD now complete: `login` (create) / `list-sessions` (read all) / `show-session` (read one) / `remove-session` (delete). Update happens via re-login.

### Phase 4 part 4d — Real-mode interactive login + multi-session ergonomics

- [feat] `playwright-driver.mjs::runLogin` — single-shot headed Chromium flow. Launches browser at `--url`, prints "press Enter when done logging in" to stderr, waits for stdin newline, captures `context.storageState()`, writes to `--output-path` (mode 0600). Independent of the IPC daemon — login is its own ephemeral isolated context.
- [feat] `scripts/browser-login.sh` adds `--interactive` flag (mutually exclusive with `--storage-state-file`). Shells the driver, validates the captured storageState through the same Phase-2 origin-binding pipeline, writes the session + meta sidecar. `--interactive --dry-run` skips the browser launch and reports the planned action. Summary `why` field becomes `interactive-headed-capture` (vs `storageState-file-import` for the file path).
- [feat] `scripts/browser-list-sessions.sh` — new verb. Lists sessions with their bound site + origin + captured_at + expires_in_hours. Optional `--site NAME` filter exposes the **1-many credential model**: a site can have many sessions (e.g. `prod--admin`, `prod--readonly`, `prod--ci`) for per-role/per-account workflows. Storage state itself stays at mode 0600; this verb only emits metadata, never cookie/token values.
- [docs] `SKILL.md` verbs table gains rows for `login --interactive`, `login --storage-state-file`, and `list-sessions`. Login usage block now documents the 1-many model explicitly.
- [internal] `tests/list-sessions.bats` (5 cases) + 3 new login-flag tests. Phase-2 fixture-based login tests unchanged.

### Phase 4 part 4b — IPC daemon + stateful verbs (snapshot/click/fill) real mode

- [feat] `daemonChildMain` becomes an IPC server. Holds `(BrowserServer, Browser, current Context, current Page, refMap)` in closure. Listens on TCP loopback (random port — Unix socket sun_path is 104 chars on macOS; bats temp paths exceed it). State file gains `ipc_host` + `ipc_port` fields.
- [feat] `runSnapshot` / `runClick` / `runFill` route through `ipcCall` — JSON-line protocol over TCP loopback. Daemon executes verbs against held state; clients are thin transports.
- [feat] `runOpen` ALSO routes through IPC when daemon present; the daemon-held context+page persists for snapshot/click/fill. Falls back to one-shot launch when no daemon.
- [feat] `--secret-stdin` for fill: client reads stdin, sends text in JSON IPC message, daemon scrubs Playwright error logs (which echo fill args) before replying. Client reply never contains the secret on any path.
- [feat] Snapshot uses Playwright 1.59's `page.ariaSnapshot()` (replaces dropped `page.accessibility`). Output is YAML; `parseAriaSnapshot()` extracts interactive (role, name) tuples and assigns `eN` ids. Click/fill use `page.getByRole(role, {name}).first()` for stable cross-call locators.
- [internal] Empirical finding documented: `chromium.connect()` clients DO NOT share contexts across connections — that's why daemon-side dispatch (this design) is necessary. `runOpen`'s `attached_to_daemon: true` field now genuinely reflects state persistence.
- [internal] `tests/playwright-lib_stateful_e2e.bats` — 4 gated cases covering full chain (start → open → snapshot → click → stop), no-open-page error, ref-not-found error, and the secret-leak guard.
- [docs] `docs/superpowers/plans/2026-05-01-phase-04-part-4c-ipc-daemon.md` — design doc the implementation followed; kept as historical record.

### Phase 4 part 4a — Daemon lifecycle + open-via-daemon

- [feat] `playwright-driver.mjs` `daemon-start` / `daemon-stop` / `daemon-status` subcommands. Spawns a detached node child that calls `chromium.launchServer()` and writes state (PID + wsEndpoint + started_at) to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.json` (mode 0600). Parent polls (≤10s), prints state, exits. Stopping SIGTERMs the PID and cleans up.
- [feat] `runOpen` attaches to a running daemon when present (chromium.connect via wsEndpoint). Closes pre-existing contexts so the agent's "current context" is unambiguous; a new context+page persists in the daemon for subsequent verbs. Falls back to one-shot launch when no daemon — keeps existing smoke-test ergonomics. Output now includes `attached_to_daemon: bool` so callers can see which path ran.
- [feat] Daemon stderr captured to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.log` (mode 0600) — silent failures (e.g. missing chromium cache) become diagnosable.
- [internal] `tests/playwright-lib_daemon_e2e.bats` — 5 e2e cases gated on `command -v playwright`. Covers start/status/stop, attach-on-open, idempotent start, stop-when-none-running. CI without Playwright skips the file via `setup_file()`.
- [fix] `.gitignore` — daemon state/log files (so accidental driver runs from inside the repo don't pollute git).

### Phase 4 part 3 — Real-mode driver (open) + sessions threaded into all verbs

- [feat] `scripts/lib/node/playwright-driver.mjs` real-mode `open` — single-shot launch + navigate + close. Lazy-imports `playwright` via `createRequire` with `npm root -g` fallback (or `BROWSER_SKILL_NPM_GLOBAL` override) so users can keep playwright globally installed without project-level package.json.
- [feat] Stateful verbs (snapshot/click/fill/login) emit a clear "daemon mode required (Phase 4 part 4)" hint in real mode; stub mode + playwright-cli routes remain functional.
- [feat] `scripts/browser-snapshot.sh`, `browser-click.sh`, `browser-fill.sh` now call `resolve_session_storage_state` between argv parse and `pick_tool` — sessions thread through every verb script that has an adapter.
- [feat] `lib/session.sh::session_save` validates `storageState.origins[*].localStorage` is an array. Real Playwright errors at `browser.newContext()` if the field is missing — the new guard surfaces it at save time with a clear pointer. Hand-edited storageState files (Phase-2 login flow input) trip on the original shape; real captures (`context.storageState()`) come out correctly.

### Phase 4 — Real Playwright (node-bridge adapter) + session loading

- [adapter] `scripts/lib/tool/playwright-lib.sh` — second concrete adapter; shells to a Node ESM driver that speaks the real Playwright API directly. Declares `session_load: true` capability, supports `--secret-stdin` natively (driver reads stdin in node), declares `login` verb (replaces the Phase-2 stub).
- [feat] `scripts/lib/node/playwright-driver.mjs` — Node ESM bridge. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) hashes argv → reads `tests/fixtures/playwright-lib/<hash>.json` so CI runs without Playwright installed. Real mode: deferred to follow-up (lazy-imports playwright; launches chromium; applies storageState).
- [feat] `scripts/lib/verb_helpers.sh::resolve_session_storage_state` — maps `--site` / `--as` to a storageState file path; exports `BROWSER_SKILL_STORAGE_STATE`. Origin enforcement via Phase-2 `session_origin_check`. `--as` without `--site` is a usage error.
- [feat] `scripts/lib/router.sh::rule_session_required` — placed before `rule_default_navigation`; prefers `playwright-lib` when `BROWSER_SKILL_STORAGE_STATE` is set.
- [feat] `parse_verb_globals` adds `--as SESSION` (sets `ARG_AS`).
- [feat] `scripts/browser-open.sh` calls `resolve_session_storage_state`; verb scripts now thread sessions transparently.
- [fix] `scripts/browser-login.sh` summary tag changes from `tool=playwright-lib-stub` to `tool=playwright-lib` (Phase-2 carry-forward closed).
- [docs] `references/playwright-lib-cheatsheet.md` — new cheatsheet covering the node-bridge specifics.
- [docs] `SKILL.md` verbs table gains a session-loading example row.
- [internal] `tests/playwright-lib_adapter.bats` (17 cases — 6 driver stub-mode + 11 adapter contract). `tests/session-loading.bats` (10 cases — full --site/--as resolution coverage including origin mismatch + missing-session paths).

### Phase 3 part 3 — Sibling verb scripts

- [feat] `scripts/browser-snapshot.sh` — `eN`-indexed accessibility snapshot via picked adapter; passes through optional `--depth N`.
- [feat] `scripts/browser-click.sh` — click by `--ref eN` (preferred) or `--selector CSS` (mutually exclusive; one required).
- [feat] `scripts/browser-fill.sh` — fill by `--ref eN` with `--text VALUE` or `--secret-stdin` (mutually exclusive). `--secret-stdin` reads the secret from stdin and pipes it through to the adapter; the secret string never appears in argv (test asserts the leak guard).
- [feat] `scripts/browser-inspect.sh` — inspect by `--selector CSS`.
- [docs] `SKILL.md` verbs table gains `snapshot` / `click` / `fill` / `inspect` rows.
- [internal] 4 new bats files (19 cases) + 2 new stub fixtures (`fill --ref e3 --text hello`, `inspect --selector h1`).

### Phase 3 part 2 — Real verb scripts

- [feat] `scripts/lib/verb_helpers.sh` — `parse_verb_globals` + `source_picked_adapter` shared boilerplate for all verb scripts.
- [feat] `scripts/browser-open.sh` — first real verb script: `--site`/`--tool`/`--dry-run`/`--raw` global flags, `--url` required arg, full router → adapter → emit_summary pipeline.
- [docs] `SKILL.md` verbs table gains `open` row.
- [internal] `tests/verb_helpers.bats` (5) + `tests/browser-open.bats` (6) — full pipeline coverage via the playwright-cli stub.

### Phase 3 — Tool adapter extension model + first adapter

#### Added
- [feat] `BROWSER_SKILL_TOOL_ABI=1` constant in `scripts/lib/common.sh` — single-source ABI version for adapters; `LIB_TOOL_DIR` exported by `init_paths`.
- [feat] `scripts/lib/output.sh` — token-efficient output helpers (`emit_summary` / `emit_event` / `capture_path`) implementing `2026-05-01-token-efficient-adapter-output-design.md` §3.
- [feat] `scripts/lib/router.sh` — single-source routing precedence with `ROUTING_RULES` array of rule functions; `pick_tool` + `_tool_supports` capability filter; `rule_default_navigation` routes open/click/fill/snapshot/inspect to playwright-cli.
- [adapter] First concrete adapter `scripts/lib/tool/playwright-cli.sh` implementing the contract (3 identity + 8 verb-dispatch fns); sources `output.sh`.
- [feat] `scripts/regenerate-docs.sh` — manual generator for `references/tool-versions.md` and `SKILL.md` Tools block; idempotent.
- [internal] `tests/lint.sh` — three-tier adapter lint (static + dynamic + drift) with `lint.bats` coverage; drift tier enforces autogen sync + every-adapter-sources-output.sh.
- [internal] `tests/routing-capability-sync.bats` — drift test ensuring router rules align with adapter-declared capabilities.
- [internal] `tests/stubs/playwright-cli` + `tests/fixtures/playwright-cli/` — argv-hash-keyed adapter contract tests.
- [docs] `references/playwright-cli-cheatsheet.md`.
- [docs] `references/recipes/add-a-tool-adapter.md` — two-path recipe (Path A: ship-without-promotion; Path B: promote-to-default).
- [docs] `references/recipes/anti-patterns-tool-extension.md` — 9 WRONG/RIGHT examples.

#### Changed
- [adapter] `scripts/browser-doctor.sh` — adapter aggregation loop walks `scripts/lib/tool/*.sh` in subshells; `node` elevated from advisory to required; status semantics ok/partial/error per adapter outcomes.
- [docs] `SKILL.md` — added autogenerated `## Tools` section between markers.

#### Documentation
- New design spec: `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` augmenting parent spec §3.3 + §13.2.
- New design spec: `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md` codifying the bytes adapters emit (sources: chrome-devtools-mcp design principles + microsoft/playwright-cli + browser-act/skills).

### Phase 2 — Site & session core

- [feat] `add-site` / `list-sites` / `show-site` / `remove-site` verbs ship (typed-name confirm on remove)
- [feat] `use` verb: get / set / clear current site
- [feat] `login` verb (Phase 2 stub): consumes a hand-edited Playwright storageState file, validates origins against the site URL, writes session + meta sidecar
- [feat] `lib/site.sh`: site profile CRUD with atomic write, mode 0600, schema_version=1
- [feat] `lib/session.sh`: storageState read/write, `session_origin_check` (spec §5.5), `session_expiry_summary`
- [feat] `common.sh`: `now_iso` helper added (UTC, second precision)
- [security] sessions inherit the same gitignored / 0600-files invariant as Phase 1
- [internal] `tests/helpers.bash` now sources `lib/common.sh`; `${EXIT_*:-N}` fallback pattern dropped from all `.bats` files
- [docs] SKILL.md verb table reflects new verbs; mode wording corrected to "0700 dir, 0600 files"; `CLAUDE_SKILL_DIR` explainer added

### Phase 1 — Foundation

- [feat] `install.sh --user --with-hooks --dry-run` ships
- [feat] `uninstall.sh` ships (symlink-only by default)
- [feat] `doctor` verb: deps + bash version + home dir mode + disk encryption (advisory)
- [feat] `lib/common.sh`: exit codes, logging, summary_json, BROWSER_SKILL_HOME resolver, with_timeout, now_ms
- [security] `.gitignore` blocks credentials/sessions/captures/keys/.env
- [security] `.githooks/pre-commit` blocks staged credentials and password-shaped diff content
- [docs] SKILL.md, README.md, SECURITY.md scaffolded
- [internal] bats unit suite (~44 tests) runs in <10 s

### Phase 1 — Pre-Phase-2 cleanup (post v0.1.0-phase-01-foundation)

- [fix] `now_ms()` moved from `browser-doctor.sh` into `lib/common.sh` so future verb scripts can compute `duration_ms` without copy-paste.
- [fix] `node` check in doctor downgraded to advisory: missing node now warns but does not increment `problems` (Phase 1 does not require node yet; Phase 3 will elevate).
- [internal] new `check_cmd_advisory` helper in doctor for warn-but-do-not-fail dependency checks.
