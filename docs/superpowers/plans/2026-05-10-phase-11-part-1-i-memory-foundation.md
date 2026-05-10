# Phase 11 part 1-i — `lib/memory.sh` foundation (URL→archetype + interaction cache I/O)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First sub-part of Phase 11. Ships `scripts/lib/memory.sh` (pure read/write API for the per-archetype selector cache) plus `scripts/lib/node/url-pattern-resolver.mjs` (URLPattern wrapper). NO verb integration (deferred to 11-1-ii `browser-do`). NO self-heal orchestration loop (deferred to 11-1-iii — only the fail-counter mechanic lands here so 11-1-iii has the storage primitives in place).

**Branch:** `phase-11-part-1-i-memory-foundation`
**Tag:** `v0.47.0-phase-11-part-1-i-memory-foundation`

---

## Locked decisions (carry-through from design doc 2026-05-08)

- **M1** Cache key = `(site, url_pattern, intent_phrase)`.
- **U1** URL pattern resolution via hand-rolled regex matcher (`:name` segment + `*` wildcard subset). **Deviation from design doc §3 U1's "URLPattern web standard" decision:** the global `URLPattern` is only stable in Node 23.8+, and CI runners (and many user systems) still default to Node 20. A hand-rolled matcher keeps behavior deterministic across all supported Node versions and avoids the npm-polyfill cost. Native `URLPattern` can replace this when CI baseline lifts to Node 24+ (target: mid-2026 per https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/). v1 subset is sufficient for the patterns Phase 11 needs (`:id`, `:userId`, `*`).
- **E1** Engagement via future `browser-do` verb (NOT in 11-1-i).
- **H1** Self-healing = mark fail → invalidate after `fail_count > 3`. **Storage mechanic lands here; orchestration loop lands in 11-1-iii.**

## Storage shape (frozen at v1, per design doc §4)

```
${BROWSER_SKILL_HOME}/memory/                      # mode 0700, lazy-created
├── _index.json                                    # mode 0600 (write deferred — placeholder file untouched in 11-1-i)
└── <site>/                                        # mode 0700
    ├── patterns.json                              # mode 0600
    │     {schema_version: 1, patterns: [
    │        {url_pattern: "/devices/:id", archetype_id: "devices-detail",
    │         first_seen, last_seen, hit_count}
    │     ]}
    └── archetypes/                                # mode 0700
        └── <archetype_id>.json                    # mode 0600
              {schema_version: 1, archetype_id, url_pattern,
               first_seen, last_seen, use_count,
               interactions: [
                 {intent, selector, first_used, last_used,
                  success_count, fail_count, disabled, self_heal_history: []}
               ]}
```

**Lazy creation.** `memory/` not created at install time; first `memory_save_archetype` / `memory_record_pattern` call invokes `memory_init_dir`. Mirrors Phase 7's `captures/` precedent + Phase 9-1-v's `baselines.json` precedent.

**`_index.json` not yet written.** Per design doc §4 ("`_index.json` updates are best-effort/coalesced"). 11-1-i ships only per-site `patterns.json` + per-archetype JSON. Cross-site index lands in 11-1-ii or 11-1-iii when `browser-do` knows about all sites it touches.

## API additions

### `scripts/lib/memory.sh` (new lib helper)

```bash
memory_init_dir                                    # mkdir -p memory/ + chmod 700; idempotent
memory_load_archetype <site> <archetype_id>        # echoes archetype JSON; "" if missing
memory_save_archetype <site> <archetype_id> <json> # atomic write; mode 0600
memory_lookup        <site> <archetype_id> <intent>            # echoes selector or empty
memory_record        <site> <archetype_id> <intent> <selector> # upsert interaction; bumps success_count + last_used
memory_record_failure <site> <archetype_id> <intent>           # increments fail_count; threshold>3 → disabled:true
memory_record_pattern <site> <url_pattern> <archetype_id>      # upsert pattern in patterns.json
memory_resolve_archetype <site> <url>              # echoes archetype_id by URLPattern match; empty on miss
```

All functions:
- Source-only — no CLI entry point in this PR.
- Validate `site` + `archetype_id` via existing `assert_safe_name` from `common.sh`.
- Use `summary_json` only inside the future verb layer; this lib stays silent on stdout (functions echo raw values, not events).
- Atomic write pattern: `tmp.$$ → chmod 600 → mv` (mirror `site.sh` precedent).

### `scripts/lib/node/url-pattern-resolver.mjs` (new node-helper)

Reads JSON from stdin: `{patterns: [{url_pattern, archetype_id}], url}`.
Writes JSON to stdout: `{matched_pattern, archetype_id}` on hit, `null` on miss.

Hand-rolled regex matcher (no npm deps; no Node-version dependency; stable globals only). Each `url_pattern` is compiled into a `RegExp`:
- `:name` (any identifier-shaped name) → `[^/]+` (one path segment)
- `*` → `.*` (anything including slashes)
- Other regex metacharacters are escaped verbatim

Matched against the URL's pathname (URL parsed via `new URL(url, "https://placeholder.local")` to handle relative paths). First-match-wins (deliberate; design doc §4: patterns iterate in insert order). If callers want priority, they reorder the list.

## Test cases (RED → GREEN)

`tests/memory.bats` (new file, ~10 cases):

1. `memory_init_dir` — creates `${BROWSER_SKILL_HOME}/memory/` mode 0700; idempotent on re-call.
2. `memory_save_archetype` + `memory_load_archetype` round-trip — same JSON in/out; archetype file mode 0600; per-site dir mode 0700.
3. `memory_lookup` — returns selector for matching `(site, archetype, intent)` triple.
4. `memory_lookup` — returns empty string for unknown intent (cache miss).
5. `memory_record` — adds new interaction; `first_used` + `last_used` set; `success_count: 1`, `fail_count: 0`, `disabled: false`.
6. `memory_record` on existing intent — `success_count` increments; `last_used` advances; `first_used` preserved.
7. `memory_record_failure` — increments `fail_count`; under threshold leaves `disabled: false`.
8. `memory_record_failure` past threshold (4th call) — sets `disabled: true`.
9. `memory_record_pattern` — upserts pattern in `patterns.json`; mode 0600; idempotent on same `(url_pattern, archetype_id)` pair.
10. `memory_resolve_archetype` — `/devices/:id` pattern matches `/devices/123` URL → echoes `devices-detail`; non-matching URL → empty.

## Path security + privacy canary

- All writes go through `assert_safe_name` (site + archetype_id constrained to `^[A-Za-z0-9_-]+$`). No traversal possible.
- `intent` strings are stored verbatim — they're free-text natural language. **They are NOT used as filesystem path components**, so traversal-via-intent is structurally impossible.
- Selectors are CSS selector strings. Future cache-write-security recipe (per design doc §6) will lint cache writes for JS-injection-shaped selectors; 11-1-i ships verbatim storage. **Privacy canary deferred to 11-1-ii** when `browser-do` writes to memory under realistic user flows; verb-side canary is the right surface, not lib-side.

## Sub-scope (what 11-1-i does NOT do)

- **No `browser-do` verb.** 11-1-ii.
- **No self-heal loop** (resolve → execute → mark-fail → re-resolve). 11-1-iii. The `memory_record_failure` storage primitive lands here.
- **No `_index.json` writes.** Per design doc §4 (deferred / coalesced).
- **No manual `--pattern` flag** for browser-do. 11-2-i.
- **No auto-cluster URL pattern detection.** 11-2-ii.
- **No cache-write-security recipe.** Per design doc §6 ("ships AFTER Phase 11 part 1, not with it").
- **No intent canonicalization** (lowercase, lemmatize, etc.). Design doc §3 open-question; defer until cache-hit-rate measurements warrant complexity.
- **No memory TTL / decay.** Design doc §12 open-question; defer.
- **No verb-level privacy canary.** Lands with 11-1-ii (verb is the right surface).

## Acceptance

- `tests/memory.bats` 10 cases all green.
- `bash tests/lint.sh` exit 0 (all three tiers) — covers shellcheck on `lib/memory.sh` + node-syntax check on `lib/node/url-pattern-resolver.mjs` if lint walks .mjs.
- No Node-version requirement beyond the existing skill baseline (Node 20+); the matcher uses only stable globals (`URL`, `RegExp`, `JSON`, `process`).
- CHANGELOG `[Unreleased]` `[feat]` tag describing the lib foundation; explicit "no verb integration yet" note so HANDOFF reader knows the user-visible piece is 11-1-ii.
- No edits to `common.sh` (memory-specific paths live inside `memory.sh` as `_memory_dir`, `_memory_site_dir`, `_memory_patterns_path`, `_memory_archetype_path` helpers — keeps the diff scoped + avoids forcing every other lib to recompile its idea of paths).

## Notes for follow-ups

- **11-1-ii: `browser-do --intent "..."` verb** — looks up cache via `memory_lookup`; on hit dispatches cached action; on miss runs snapshot + LLM + write-back via `memory_record` + `memory_record_pattern`. Verb-level privacy canary lands with this PR.
- **11-1-iii: self-heal loop** — wires `memory_record_failure` into `browser-do`'s post-execute step; on threshold-disable, re-snapshot + re-resolve + overwrite via `memory_record`.
- **11-2-i: manual `--pattern` flag** — `browser-do --pattern '/devices/:id' --intent "..."` skips auto-detection.
- **Recipe `cache-write-security.md`** — post-Phase-11-part-1 follow-up per design doc §6.
