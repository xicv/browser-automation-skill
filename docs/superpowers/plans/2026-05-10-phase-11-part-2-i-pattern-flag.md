# Phase 11 part 2-i — `--pattern` / `--archetype` flags in `browser-do --intent` mode

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Extend `browser-do --intent` to accept explicit `--pattern '/devices/:id'` and `--archetype devices-id` flags, so agents can short-circuit URL→archetype resolution when they already know the conceptual archetype. The `record` sub-mode already accepts both flags (shipped 1-ii); this PR makes the `--intent` sub-mode symmetric.

**Branch:** `phase-11-part-2-i-pattern-flag`
**Tag:** `v0.50.0-phase-11-part-2-i-pattern-flag`

---

## Locked decisions

- **R1 — Resolution priority (most explicit wins):**
  1. `--archetype NAME` — direct archetype-id; skip both URL lookup and pattern derivation.
  2. `--pattern PATTERN` — derive archetype-id via `_derive_archetype_id` (reuses 1-ii helper); skip URL lookup.
  3. `--url URL` — `memory_resolve_archetype` (existing path).
  4. None of the three → existing `cache_miss reason:no_pattern_for_url`. Preserves backwards-compat for callers that omit all three.
- **R2 — `--archetype` honors `assert_safe_name`** (just like `record`'s `--archetype`). Caller-supplied archetype-id constrained to `^[A-Za-z0-9_-]+$`. Mirrors 1-ii behavior; consistent treatment across sub-modes.
- **R3 — `--pattern` does NOT need to be cached.** This is read-side only; it does NOT call `memory_record_pattern`. The agent's explicit pattern flag means "use this pattern for THIS lookup"; whether the pattern persists in `patterns.json` is a separate decision made by `record` calls. Decoupling read-side flag from write-side persistence keeps `--intent` purely consultative.
- **R4 — No `cache_miss` reason variant.** Reasons stay as-is: `no_pattern_for_url` (no URL/pattern/archetype provided) and `intent_not_cached` (archetype resolved but intent unknown). Adding a "user-specified-archetype-not-found" variant has no behavior gain — agent response is identical (snapshot+pick+record). Matches 1-iii D3 disabled-vs-never-cached precedent.
- **R5 — Empty cache_miss reason for explicit-archetype-but-no-cache:** when `--archetype NAME` is given but the archetype JSON file doesn't exist, fall through to `cache_miss reason:intent_not_cached`. Treats absent-archetype same as known-but-missing-intent — both produce identical agent action.

## Surface

```
bash scripts/browser-do.sh \
  --verb VERB \
  --intent "phrase" \
  [--site NAME] \
  [--url URL] \
  [--pattern '/devices/:id'] \
  [--archetype devices-id] \
  [-- VERB_ARG ...]
```

- `--archetype NAME` (new) — explicit archetype-id; bypasses URL/pattern derivation.
- `--pattern PATTERN` (new) — explicit URL pattern; archetype-id derived via `_derive_archetype_id`.
- `--url URL` (existing) — falls back to `memory_resolve_archetype` if neither --archetype nor --pattern given.
- All three are optional and independently overrideable. Most-explicit-wins (R1).

## Behavior change

Inside `--intent` sub-mode, the archetype-resolution block:

```bash
# Resolution priority (R1): --archetype > --pattern > --url.
archetype_id=""
if [ -n "${arg_archetype}" ]; then
  assert_safe_name "${arg_archetype}" "archetype-id"
  archetype_id="${arg_archetype}"
elif [ -n "${arg_pattern}" ]; then
  archetype_id="$(_derive_archetype_id "${arg_pattern}")"
elif [ -n "${arg_url}" ]; then
  archetype_id="$(memory_resolve_archetype "${site}" "${arg_url}" 2>/dev/null || true)"
fi
```

Empty archetype after this block → existing `cache_miss reason:no_pattern_for_url`.

## Test cases (RED → GREEN)

`tests/browser-do.bats` (gains 5 cases, total 24):

1. `--intent --pattern '/devices/:id'` works without `--url` → resolves `devices-id` archetype → cache hit dispatches stub-click.
2. `--intent --archetype devices-id` direct lookup (no `--url`, no `--pattern`) → cache hit.
3. `--intent --archetype devices-id --pattern '/different/:thing' --url '...'` — most-explicit wins (`--archetype` resolves directly; pattern + url ignored).
4. `--intent --pattern '/explicit/:id' --url 'https://x/devices/123'` — `--pattern` overrides URL-derived archetype (doesn't call `memory_resolve_archetype`).
5. `--intent` without any of `--url` / `--pattern` / `--archetype` → exit 11 + `cache_miss reason:no_pattern_for_url` (existing behavior preserved).

## Sub-scope (what 2-i does NOT do)

- **No auto-cluster pattern detection** — that's 11-2-ii.
- **No `--pattern` write-side change** — `record --pattern` already supported in 1-ii. This PR is read-side only.
- **No new `cache_miss` reason variants** (R4).
- **No selector-mode plumbing for fill/hover/press/select** — independent prerequisite; tracked as separate follow-up.
- **No multi-pattern fallback** — caller passes ONE pattern; if it doesn't match, no auto-fallback to URL-derive. Resolution is single-path per call.
- **No `--archetype` validation against existing archetype files** — invalid name → `assert_safe_name` rejects; nonexistent archetype → falls through to `cache_miss reason:intent_not_cached` (R5). No "archetype-not-found" exit code.

## Acceptance

- `tests/browser-do.bats` 24 cases all green on macos-latest + ubuntu-latest.
- `bash tests/lint.sh` exit 0.
- Existing `--intent` callers (no `--pattern` / `--archetype`) work unchanged — full backwards compatibility.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **11-2-ii: auto-cluster URL patterns** — observe N visits to a site; cluster paths that diverge only at numeric/UUID/slug segments; propose pattern; user/agent confirms via `record`. This PR's `--pattern` flag becomes the manual-override path for the auto-clustered defaults.
- **Selector-mode plumbing for fill/hover/press/select** — adapter ABI work; expands `--verb` whitelist beyond `[click]`. Independent prerequisite.
- **`--pattern` as memory-population side effect** — could `--intent --pattern X` opportunistically call `memory_record_pattern` so the pattern lands in `patterns.json` for next-call URL-resolution? **R3 says no** for v1; revisit if explicit-pattern users find themselves calling `record` redundantly.
