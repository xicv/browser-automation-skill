# Phase 11 part 2-ii — `browser-do propose` (CLOSES Phase 11 part 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close Phase 11 part 2 with auto-cluster URL pattern detection. New `browser-do propose` sub-mode: takes URLs as input, clusters them by structural similarity (numeric segments → `:id`, UUID segments → `:uuid`), and emits proposal events for clusters meeting a threshold. Pure-compute — no new persistent storage.

**Branch:** `phase-11-part-2-ii-propose`
**Tag:** `v0.51.0-phase-11-part-2-ii-propose`

---

## Locked decisions

- **C1 — Pure compute, no new persistence.** Agent owns URL collection. `propose` reads URLs from `--url` flag (repeatable) and/or stdin (one URL per line). **Does NOT add `recent_urls.jsonl` or any other observation log.** Rationale: keeps scope contained, no schema bump, no surprise persistence side-effects, composable with shell pipes (`tac history.log | propose`). Active observation is a future enhancement; v1 stays pure.
- **C2 — Heuristic scope = numeric + UUID only for v1.** Slug segments (`/posts/my-blog-post`) are too high-entropy — clustering on alphanumerics produces false positives that the agent has to filter out. Defer slug heuristic.
  - **Numeric segment** = `^[0-9]+$` → replace with `:id`.
  - **UUID segment** = `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$` → replace with `:uuid`.
  - Other segments stay verbatim.
- **C3 — Threshold default `N=3`, configurable via `--threshold N`.** Three observations is the smallest count that justifies generalization (two could be coincidence; three is a pattern). Lower = more proposals + more noise; higher = miss real patterns. N=3 is the conventional middle ground.
- **C4 — Suppress already-known patterns.** Skip proposing URL patterns that are already in `<site>/patterns.json` (any archetype). Without this, every `propose` invocation re-emits patterns the user already accepted; turns the verb noisy + makes its output un-pipeable. **The lookup is by `url_pattern` string equality**; equivalent patterns expressed differently (e.g. `/devices/:id` vs `/devices/:deviceId`) are NOT considered the same — both would propose. (Future refinement: pattern-equivalence canonicalization. Defer.)
- **C5 — Always emit proposal events; never auto-record.** Agent decides whether to call `record --pattern X --archetype Y` to land the proposal. Avoids surprise pattern landings + reviewable agent behavior. Auto-record is a separate future flag (e.g. `--auto-record`); not in v1.
- **C6 — Always exits 0.** Proposing zero clusters is not an error — it's a valid result ("no patterns worth proposing yet"). Exit 0 + summary `proposals:0`. Agents pipe `propose` output through `jq` to act on `_kind:proposal` events; non-zero exit would force shell-script error handling for the no-op case.
- **C7 — Site context resolution.** `--site NAME` flag wins; falls back to `current_get`. Empty current → `EXIT_USAGE_ERROR`. Mirrors existing verbs.

## Surface

```
bash scripts/browser-do.sh propose \
  [--site NAME] \
  [--threshold N] \
  [--url URL ...]
# Stdin: optional, one URL per line. Combined with --url args.
```

- `--site NAME` — site context (mirrors other verbs).
- `--threshold N` — minimum URLs per cluster to emit a proposal. Default `3`.
- `--url URL` (repeatable) — inline URL input.
- Stdin — one URL per line; whitespace-only lines and `^#` comments ignored.

## Behavior

```
1. Resolve site (flag → current → die).
2. Collect URLs from --url args + stdin (deduped).
3. Load existing patterns from <site>/patterns.json (if present) into a "known" set.
4. For each URL, compute templated pathname:
     - Parse URL with `new URL(url, "https://placeholder.local")`
     - Extract pathname; split into segments
     - Replace numeric segments with `:id`; UUID segments with `:uuid`
     - Reassemble templated pathname
5. Group URLs by templated pathname.
6. For each group with count >= threshold AND template NOT in known:
     - Compute archetype_id via _derive_archetype_id (reuses 1-ii helper)
     - Emit `_kind:proposal` event:
       {site, url_pattern, archetype_id, sample_urls (first 3), count}
7. Emit summary line with proposals count + skipped count + threshold.
8. Exit 0 always.
```

## Implementation strategy

URL templating delegates to a node-helper (mirrors 1-i `url-pattern-resolver.mjs` precedent — keeps URL parsing in node, not bash regex). New file `scripts/lib/node/url-pattern-cluster.mjs` reads `{urls:[...]}` from stdin, writes `{clusters:[{templated, urls}]}` to stdout. Bash side does threshold filtering + known-pattern suppression + event emission.

```
bash propose: collect URLs from args+stdin
            ↓
       load patterns.json → known set
            ↓
       echo {urls} | node url-pattern-cluster.mjs → {clusters}
            ↓
       jq filter: count >= threshold AND template not in known
            ↓
       emit _kind:proposal events
            ↓
       summary line
```

## Test cases (RED → GREEN)

`tests/browser-do.bats` (gains 8 cases, total 32):

1. 3 numeric URLs (`/devices/1`, `/devices/2`, `/devices/3`) → emits 1 proposal with `url_pattern:/devices/:id` + `count:3`.
2. 3 UUID URLs (`/items/<uuid1>`, `/items/<uuid2>`, `/items/<uuid3>`) → emits 1 proposal with `url_pattern:/items/:uuid`.
3. Below threshold (only 2 URLs) → 0 proposals; summary `proposals:0`; exit 0.
4. Mixed unrelated URLs (`/a`, `/b`, `/c`) → 0 proposals (each cluster size 1).
5. Already-known pattern in `patterns.json` → suppressed; no proposal even with 3+ URLs.
6. `--threshold 5` override + only 4 URLs → 0 proposals.
7. URLs read from stdin (one per line) → proposal emitted.
8. Slug-shaped segments don't cluster (`/posts/my-post`, `/posts/your-post`, `/posts/their-post`) → 0 proposals (each pathname is verbatim; no numeric/UUID in any segment, so no template match).

## Sub-scope (what 2-ii does NOT do)

- **No persistent observation log** — agent owns URL collection (C1).
- **No slug heuristic** — too high-entropy for v1 (C2).
- **No auto-record on proposal** — agent must explicitly call `record` (C5).
- **No pattern-equivalence canonicalization** — `/devices/:id` and `/devices/:deviceId` are distinct (C4 future refinement).
- **No cross-site clustering** — strict per-site boundary (parent design doc §12).
- **No proposal ranking by frequency** — proposals emitted in cluster-discovery order; agents that want ranking can `jq sort_by(.count)`.
- **No `--auto-record` flag** — defer.
- **No new lib helpers in `memory.sh`** — propose is self-contained in browser-do.sh + the node-helper.

## Acceptance

- `tests/browser-do.bats` 32 cases all green on macos-latest + ubuntu-latest.
- `bash tests/lint.sh` exit 0.
- `propose` with no URLs (empty args + empty stdin) → exit 0, `proposals:0`.
- Existing `--intent` and `record` sub-modes work unchanged (no regression).
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.
- HANDOFF refresh: closes Phase 11 part 2 (2/2 sub-parts shipped).

## Notes for follow-ups

- **Active observation (post-Phase 11 part 2):** if usage shows agents repeatedly piping the same URL list into `propose`, consider adding a passive `recent_urls.jsonl` per site that `record` and `--intent` append to. Then `propose` reads it by default. Schema-bump-clean if the file is opt-in (env-var or flag-gated).
- **Slug clustering (post-Phase 11 part 2):** entropy-based — segments below some uniqueness threshold (Shannon entropy or simpler: ratio of unique values across observations) become `:slug`. Higher false-positive risk than numeric/UUID; defer until demand surfaces.
- **`--auto-record` flag:** `propose --auto-record --threshold N` would land proposals immediately. Trades reviewability for convenience. Defer.
- **Pattern-equivalence canonicalization:** `:id` vs `:itemId` are equivalent for matching purposes. A canonicalizer would let suppression catch more duplicates. Adds design surface; defer.

## Closes Phase 11 part 2

After this PR ships, the full Phase 11 roadmap (per design doc 2026-05-08) is:
- Part 1 ✅ CLOSED (lib + verb + self-heal)
- Part 2 ✅ CLOSED (manual `--pattern` + auto-cluster `propose`)

Memory is feature-complete for v1. Future Phase 11 work is hardening (slug heuristic, auto-record, pattern-equivalence) — all post-v1 backlog items.
