# Phase 11 part 1-ii — `browser-do` verb (cache lookup + dispatch + explicit write-back)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First user-visible memory feature. Two sub-modes in one verb:
- `browser-do --verb VERB --intent "..."` — cache lookup; on hit dispatches existing `browser-VERB.sh --selector $cached`; on miss emits `cache_miss` event + exits 11.
- `browser-do record --intent "..." --selector "..." --url "..."` — explicit write-back via `memory_record` + `memory_record_pattern`.

**Branch:** `phase-11-part-1-ii-browser-do`
**Tag:** `v0.48.0-phase-11-part-1-ii-browser-do`

---

## Locked design decisions (carry-through from HANDOFF "open shape questions")

- **Q1 — LLM resolution surface:** **Event-driven, not in-skill.** On miss, the verb emits a structured `_kind: cache_miss` event with `intent`, `archetype_id`, `reason`, `suggestion: "snapshot+pick+record"`. Skill stays model-agnostic — parent agent (Claude Code) picks the ref via its own snapshot+reasoning, then explicitly calls `browser-do record ...` to fill the cache. **No LLM call inside the skill.**
- **Q2 — Site context:** `--site NAME` overrides; falls back to `current_get` from Phase 1 (mirror existing verbs). Empty current → `EXIT_USAGE_ERROR`.
- **Q3 — Write-back failure mode:** Best-effort. If `memory_save_archetype` fails (disk full, permissions), the **action's** exit code is unchanged; cache failure is logged via `warn:` to stderr only. Action correctness > cache freshness.
- **Q4 — Cache-stored verb type:** **Selector only, no verb-type field.** Schema v1 was just frozen in 11-1-i; adding a `verb` field would be a breaking change. Caller specifies `--verb VERB` on every `browser-do` invocation. Same selector can serve different verbs (click vs. hover same target).
- **Q5 — `--verb` whitelist:** v1 supports `click` only. Other selector-target verbs (`fill`, `hover`, `press`, `select`) currently take `--ref eN` only — refs are snapshot-relative and can't be cached across snapshots. They get added to the whitelist when their adapter ABI gains selector-mode plumbing (a follow-up sub-part). Whitelist is defensive against typos + accidental dispatch of credential-handling verbs (`extract`, `audit`, etc.) and against verbs that don't fit the lookup-by-intent model (`open`, `snapshot`, `assert`).
- **Q6 — Pattern derivation when `--pattern` absent:** Simple regex `s|/[0-9]+|/:id|g` against URL pathname. `/devices/123` → `/devices/:id`. UUID detection deferred to 11-2-ii. User can always pass `--pattern '/explicit/:thing'` to override.
- **Q7 — Archetype ID derivation:** Deterministic from pattern: strip leading `/`, drop `:` chars, replace `/` with `-`, lowercase. `/devices/:id` → `devices-id`. User can override with `--archetype NAME`. Constrained to `^[A-Za-z0-9_-]+$` (matches `assert_safe_name`).
- **Q8 — Privacy canary:** Two layers. (a) **Production refusal:** verb refuses to record if intent OR selector contains the literal sentinel `PASSWORD-CANARY` (matches recipe pattern; provides fast-fail for agents that accidentally inline credentials into args). (b) **Test discipline:** bats canary writes `PASSWORD-CANARY` in a credential field; asserts verb exit 28 (`EXIT_BLOCKLIST_REJECTED`) + asserts cache file untouched. Real entropy/secret-detection deferred to a future hardening pass.

## Surface

### Sub-mode 1 — read+dispatch

```
bash scripts/browser-do.sh \
  --verb VERB \
  --intent "phrase describing the action" \
  [--site NAME] \
  [--url URL] \
  [-- VERB_ARG VERB_ARG ...]
```

- `--verb VERB` — required. One of `click | fill | hover | press | select`.
- `--intent "..."` — required. Free-text natural-language phrase.
- `--site NAME` — optional. Defaults to `current_get`.
- `--url URL` — optional. If absent, the verb requires a previously-cached pattern resolution to succeed; otherwise emits `cache_miss` with `reason: "no_url_no_archetype"`.
- `-- VERB_ARG ...` — extra args forwarded verbatim to the dispatched `browser-VERB.sh`. `--selector "$cached"` is auto-prepended; caller adds `--text "..."` for fill, `--key Enter` for press, etc.

**Behavior:**
1. Resolve site (flag → current → die).
2. Resolve archetype: `memory_resolve_archetype $site $url`.
3. Empty archetype → emit `_kind:cache_miss reason:no_pattern_for_url`; exit 11.
4. `memory_lookup $site $arch $intent` → empty selector → emit `_kind:cache_miss reason:intent_not_cached`; exit 11.
5. Hit: dispatch `bash scripts/browser-$verb.sh --selector "$cached" $extra_args`.
6. Verb succeeds → emit `_kind:cache_hit`; bump `success_count` via `memory_record` (re-records same selector — bumps counter); bump pattern `hit_count`; exit 0.
7. Verb fails → forward verb's exit code; **do NOT** call `memory_record_failure` here (that's 11-1-iii's responsibility — failure orchestration loop).

**Stdout shape (cache hit, summary line last):**
```
{"_kind":"cache_hit","intent":"...","selector":"...","archetype_id":"...","site":"..."}
{"verb":"do","mode":"intent","cache_hit":true,"archetype_id":"...","duration_ms":42,"status":"ok"}
```

**Stdout shape (cache miss, summary line last):**
```
{"_kind":"cache_miss","intent":"...","site":"...","url":"...","archetype_id":"...","reason":"intent_not_cached","suggestion":"snapshot+pick+record"}
{"verb":"do","mode":"intent","cache_hit":false,"reason":"intent_not_cached","duration_ms":12,"status":"miss"}
```

### Sub-mode 2 — explicit write-back

```
bash scripts/browser-do.sh record \
  --intent "..." \
  --selector "..." \
  --url "..." \
  [--site NAME] \
  [--pattern '/devices/:id'] \
  [--archetype devices-detail]
```

- All of `--intent`, `--selector`, `--url` required.
- `--site` defaults to `current_get`.
- `--pattern` optional; auto-derived from URL pathname (`s|/[0-9]+|/:id|g`).
- `--archetype` optional; auto-derived from pattern (transform above).

**Behavior:**
1. Privacy canary: refuse if intent OR selector contains `PASSWORD-CANARY` → exit `EXIT_BLOCKLIST_REJECTED (28)`.
2. Derive `pattern` from URL if absent.
3. Derive `archetype_id` from pattern if absent.
4. `memory_record_pattern $site $pattern $archetype_id`.
5. Ensure archetype JSON exists (lazy-create empty shell if absent, then `memory_record` upserts the interaction).
6. Emit `_kind:record_ok` event + summary `verb:do mode:record archetype_id:... pattern:...`; exit 0.

## Test plan (`tests/browser-do.bats`, 15 cases)

1. `--intent` cache hit → dispatches stub-click → exit 0 + `cache_hit:true`.
2. `--intent` cache miss (no archetype for URL) → exit 11 + `_kind:cache_miss reason:no_pattern_for_url`.
3. `--intent` cache miss (intent not cached for known archetype) → exit 11 + `reason:intent_not_cached`.
4. `--intent` invalid `--verb ghost` → exit 2 (USAGE_ERROR; whitelist enforcement).
5. `--intent` missing `--site` AND no current → exit 2.
6. `--intent` `--site` overrides current.
7. `record` writes interaction + pattern; mode 0600 on both files.
8. `record` auto-derives `/devices/:id` pattern from `/devices/123` URL.
9. `record` `--pattern` overrides auto-derivation.
10. `record` `--archetype` overrides auto-derivation.
11. `record` refuses PASSWORD-CANARY in intent → exit 28; cache untouched.
12. `record` refuses PASSWORD-CANARY in selector → exit 28; cache untouched.
13. `record` missing `--intent` → exit 2.
14. `record` missing `--selector` → exit 2.
15. `record` missing `--url` → exit 2.

**Extra-args forwarding (`-- VERB_ARG ...`)** — implemented but not tested in v1 because v1's whitelist is `[click]` and click takes only `--selector` (no useful forwardable args). Forwarding test lands when fill/hover/press gain `--selector` support.

**New fixture:** `tests/fixtures/playwright-cli/6b0bbf75…json` — content `{"event":"click","selector":"button.delete","status":"ok"}`. Argv-hash for `["click","button.delete"]`. Reused by tests 1 + 6.

## Capture composition (none in 1-ii)

`browser-do` does NOT call `capture_start` — it's an orchestrator over existing primitives, not a verb that produces a capture. The dispatched verb (e.g. `browser-click`) may emit its own capture if invoked with `--capture`, transparently. This keeps `browser-do` itself stateless across the capture pipeline.

## Sub-scope (what 1-ii does NOT do)

- **No self-heal loop** — `memory_record_failure` is not invoked from `browser-do`. That's 1-iii. Verb dispatch failure forwards the verb's exit code unmodified.
- **No LLM call** — skill stays model-agnostic.
- **No multi-verb intent dispatch** — `--verb VERB` is required and singular.
- **No `--auto-record` flag** — agent must explicitly call `record` after a successful manual resolution. Reduces accidental cache pollution.
- **No UUID pattern derivation** — only `/[0-9]+/` segments. UUID/slug detection in 11-2-ii.
- **No cache invalidation by age / TTL** — design doc §12 open-question; not for v1.
- **No cross-site memory consultation** — strict per-site boundary (design doc §12).
- **No `--verb open` / `--verb extract`** — these don't fit the selector-by-intent model.

## Acceptance

- `tests/browser-do.bats` 14 cases all green on macos-latest + ubuntu-latest.
- `bash tests/lint.sh` exit 0.
- `bash scripts/browser-do.sh --intent "..." --verb click` works end-to-end against a stub-click verb (test fixture).
- `bash scripts/browser-do.sh record --intent ... --selector ... --url ...` writes through `lib/memory.sh` exactly the same as a direct `memory_record` call would.
- Privacy canary tests pass: `PASSWORD-CANARY` in any user-supplied arg refused; cache file unchanged.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **11-1-iii: self-heal loop** — wires `memory_record_failure` into `browser-do --intent`'s post-dispatch failure handler. On Nth consecutive miss, marks `disabled:true`; next invocation re-emits `cache_miss` with `reason:disabled` so agent re-resolves.
- **`--auto-record` flag** — could ship in 11-1-iii or later: `browser-do --intent ... --auto-record` runs the dispatched verb and, on success, records the resolved selector. Requires the verb to take a `--ref eN`-resolved selector path — depends on adapter ABI surface. Defer.
- **Recipe `cache-write-security.md`** — codify the `--verb` whitelist + canary refusal + best-effort write semantics into a recipe doc post-Phase-11-part-1.
