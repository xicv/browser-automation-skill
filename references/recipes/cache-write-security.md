# Recipe: Cache-write security

A discipline for any verb that writes learned state to disk based on caller-supplied bytes. Codifies the contract that Phase 11 part 1's memory cache (`scripts/lib/memory.sh` + `scripts/browser-do.sh`) ships with: verbs that turn agent input into persistent cache state are a different security shape from verbs that read state, and they need defenses the read side doesn't.

## When to use this recipe

Use this **whenever you add a verb that persists caller-supplied selectors, intents, URL patterns, or other free-text agent input as cache/memory state read by future invocations**. Examples already shipped:

- `scripts/browser-do.sh record` — Phase 11 part 1-ii; writes `(intent, selector, url_pattern)` triples to `~/.browser-skill/memory/<site>/`.
- `scripts/browser-do.sh --intent` (cache-hit success path) — Phase 11 part 1-ii/iii; bumps `success_count` + records `pattern → archetype` mapping on dispatch success.
- `scripts/browser-do.sh --intent` (cache-hit failure path, exit 11/13) — Phase 11 part 1-iii; increments `fail_count` toward H1 disable threshold.

Do NOT use this recipe for:
- Read-side verbs (lookup, list, show) — they don't persist new state; the privacy invariant is "don't echo what's already on disk", which is `privacy-canary.md`'s domain.
- Captures (Phase 7) — they persist *observed* page state, not cache mappings; sanitization is `sanitize.sh`'s job, not the cache-write contract.
- Sites profile / credentials / sessions (Phase 1–4) — these store explicit user-registered material; the user typed it deliberately. Cache writes happen *incidentally* during agent execution, which is what makes the security shape different.

## The five rules

### Rule 1 — Whitelist the cache-write surface

Never accept a caller-supplied **verb name** that you'll dispatch (or store) without enumerating allowed targets in code.

```
WRONG — accept any verb name the caller supplies
case "${arg_verb}" in
  *) bash "${SCRIPT_DIR}/browser-${arg_verb}.sh" --selector "${cached}" ;;
esac
```

```
RIGHT — explicit constant whitelist; reject everything else
readonly DO_VERB_WHITELIST=(click)   # v1: only click takes --selector
_verb_in_whitelist() {
  local needle="$1" v
  for v in "${DO_VERB_WHITELIST[@]}"; do
    [ "${v}" = "${needle}" ] && return 0
  done
  return 1
}
_verb_in_whitelist "${arg_verb}" \
  || die "${EXIT_USAGE_ERROR}" "browser-do: --verb '${arg_verb}' not in whitelist (allowed: ${DO_VERB_WHITELIST[*]})"
```

Why: a caller-supplied verb name dispatching to `bash scripts/browser-${arg_verb}.sh` lets a typo silently route to the wrong verb (`fil` → file-not-found vs `fill` actually firing); worse, lets a hostile prompt trick the agent into invoking credential-handling verbs (`creds-show`, `extract`, `audit`) under the cache-hit fast path. Whitelist is constant; reviewers can grep it; new verbs join the whitelist by an explicit code change with reviewable rationale.

Reference: `scripts/browser-do.sh::DO_VERB_WHITELIST` + `tests/browser-do.bats::4`.

### Rule 2 — Refuse cache writes containing credential sentinels

Cache writes carry caller-supplied free-text (intent phrases, selectors). If an agent accidentally inlines credential bytes into those args, they hit disk in the cache and survive across sessions. Refuse with a fast-fail.

```
WRONG — store whatever the caller passed
memory_record "${site}" "${arch}" "${intent}" "${selector}"
# Caller wrote intent="type password 'mySecret123'" → "mySecret123" persists.
```

```
RIGHT — refuse on sentinel-shaped content
readonly CANARY_SENTINEL='PASSWORD-CANARY'
_canary_check() {
  local field="$1" value="$2"
  if printf '%s' "${value}" | grep -qF -- "${CANARY_SENTINEL}"; then
    die "${EXIT_BLOCKLIST_REJECTED}" "browser-do: refused — ${field} contains canary sentinel '${CANARY_SENTINEL}'"
  fi
}
_canary_check "intent"   "${arg_intent}"
_canary_check "selector" "${arg_selector}"
memory_record "${site}" "${arch}" "${arg_intent}" "${arg_selector}"
```

This is **not a real secret detector** — entropy scanning, real password-format detection, and the broader regex-zoo of credential patterns are out of scope for this recipe. The sentinel:

- Lets bats inject `PASSWORD-CANARY` into intent or selector, assert exit `EXIT_BLOCKLIST_REJECTED (28)`, AND assert the cache file is untouched on disk. That's the **regression** safety net.
- Forces the production code to have a refusal codepath at all, instead of unconditionally writing whatever shows up.

Real entropy/format-based detection is a future hardening pass. Document it as such in the recipe-doc + plan-doc.

Reference: `scripts/browser-do.sh::_canary_check` + `tests/browser-do.bats::24,25`.

### Rule 3 — Cache writes are best-effort; never taint the action's exit code

The action (clicking, filling, navigating) is the user's actual intent. The cache-write is an *opportunistic side effect* that improves future runs. **Cache freshness < action correctness.**

```
WRONG — cache failure surfaces as the verb's exit code
memory_record "${site}" "${arch}" "${intent}" "${selector}" \
  || die "${EXIT_GENERIC_ERROR}" "cache write failed"
```

```
RIGHT — log and forge ahead
if ! memory_record "${site}" "${arch}" "${intent}" "${selector}" 2>/dev/null; then
  warn "browser-do: cache success_count update failed (best-effort; action exit unchanged)"
fi
```

Why: a disk-full or perms-bug while writing the cache must not retroactively turn a successful click into an error the agent has to handle. The agent did the right thing; if the skill couldn't remember, that's the skill's problem to log, not the agent's problem to debug. The `warn:` line is observable to the user/reviewer; the action's exit code (and downstream agent decisions) stays correct.

Reference: `scripts/browser-do.sh` cache-hit-success branch + post-dispatch failure-recording branch (both `warn:`-only on cache failure).

### Rule 4 — Self-heal failure-counting needs an exit-code whitelist

If you wire failure counting into a verb (e.g. "fail 4 times → mark cached selector disabled"), **only specific exit codes drive the counter.** Counting any non-zero exit poisons the cache when the failure was environmental.

```
WRONG — count any failure as a selector-fitness signal
if [ "${dispatch_rc}" -ne 0 ]; then
  memory_record_failure "${site}" "${arch}" "${intent}"
fi
```

```
RIGHT — whitelist the exit codes that genuinely indicate a selector miss
elif [ "${dispatch_rc}" -eq "${EXIT_EMPTY_RESULT}" ] || [ "${dispatch_rc}" -eq "${EXIT_ASSERTION_FAILED}" ]; then
  # 11 = element not found at selector; 13 = assertion failed (expected element absent).
  # 30 (network), 42 (tool crash), 43 (timeout) are environmental — they would poison
  # the cache if we counted them.
  if ! memory_record_failure "${site}" "${arch}" "${intent}" 2>/dev/null; then
    warn "browser-do: cache fail_count update failed (best-effort)"
  fi
fi
```

Why: a flaky network or a one-off tool crash shouldn't push a working selector toward disable. The cache is supposed to remember "this selector reliably finds the element"; only the kind of failure that would change that conclusion (the selector returning nothing; the assertion not matching) qualifies as evidence the cached value is stale.

Pick the whitelist deliberately:
- **In:** Exit codes that mean "the cached value was tried and its referent wasn't there." `EXIT_EMPTY_RESULT (11)` and `EXIT_ASSERTION_FAILED (13)` for Phase 11 part 1.
- **Out:** Network errors, tool crashes, timeouts, session expiry, usage errors. Document the cutoff inline so future readers see the rule, not just the list.

Reference: `scripts/browser-do.sh` post-dispatch elif branch + `tests/browser-do.bats::29,30,31` (covers in-whitelist 11+13 + out-of-whitelist 30).

### Rule 5 — Lock the cache schema; don't store action-type

Cache schema is **forever** (or schema-version-bump-forever). Frozen v1 shapes can only grow new fields, not change existing ones. The temptation to add a `verb` field per cached interaction so the cache can dispatch any verb on hit — *resist it*.

```
WRONG — cache stores (intent, selector, verb)
{
  "intent": "click delete",
  "selector": "button.delete",
  "verb": "click"               // <-- couples cache to verb-set; schema-bump on every new verb
}
```

```
RIGHT — cache stores (intent, selector); caller specifies verb per call
{
  "intent": "click delete",
  "selector": "button.delete"
}
# Caller: browser-do --verb click --intent "click delete"
# Same selector can serve hover, fill (with --text), etc. — orthogonal axis.
```

Why: storing verb-type in the cache forces a schema bump every time you add a new dispatchable verb. The cache becomes brittle to the verb set. Moving the verb axis out (caller passes `--verb` per call) keeps the cache stable across verb-set evolution, AND lets the same selector serve multiple actions naturally (the same `button.confirm` selector is clickable AND hoverable; storing it once is correct).

Corollary: **don't store literal URLs**. Store *patterns*. URLs change every visit (`/devices/123` vs `/devices/124`); patterns generalize (`/devices/:id`). Storing the literal couples the cache to one entity instance; storing the pattern lets the cache hit across the whole archetype.

Reference: archetype JSON shape in `scripts/lib/memory.sh::memory_save_archetype` + design doc 2026-05-08-phase-11-memory-design.md §3 M1.

## What to test

Each rule needs at least one bats case proving the contract holds:

```
1. Whitelist enforcement:        --verb ghost → exit EXIT_USAGE_ERROR
2. Canary refusal (intent):      intent='PASSWORD-CANARY ...' → exit 28; cache untouched
3. Canary refusal (selector):    selector='input[name=PASSWORD-CANARY]' → exit 28; cache untouched
4. Best-effort write semantics:  (harder — needs a forced cache-write failure
                                  to prove the action's exit code stays unchanged.
                                  May be deferred to integration testing.)
5. Self-heal in-whitelist:       dispatched verb exits 11 → fail_count++
6. Self-heal in-whitelist:       dispatched verb exits 13 → fail_count++
7. Self-heal out-of-whitelist:   dispatched verb exits 30 → fail_count UNCHANGED
8. Schema stability:             new field added → existing fixtures still parse
                                  (round-trip test in lib bats)
```

Sample placement (already shipped): `tests/browser-do.bats::4,12,13,29,30,31,32` (rules 1, 2, 3, 5, 6, 7, end-to-end). `tests/memory.bats::2,13` (rule 5 round-trip + self-heal D2 reset).

## Why a per-recipe contract beats per-PR vigilance

Phase 11 part 1 shipped over three PRs (1-i lib + 1-ii verb + 1-iii self-heal). Each PR had a plan-doc that locked decisions for that scope; the cumulative cache-write contract spans all three. **Without this recipe, a future PR adding a new cache-writing verb would have to re-derive the same five rules** by reading three plan-docs in sequence + the design doc. Recipes turn cumulative knowledge into a single grep-able artifact.

Concretely: if a PR adds `browser-do --verb fill` after `fill` gains `--selector` adapter plumbing, the reviewer should be able to ask "did this PR honor the cache-write contract?" and check this file's five rules + the test placements without having to reconstruct the rationale from three months of git log.

## Don't

- **Don't** add fields that store user-typed values verbatim in the cache. Selectors are CSS strings (structurally bounded); intents are short natural-language phrases (no value bytes). If you need to cache a typed value (e.g. "remember the username for this site"), it's not a memory-cache concern — it's the **credentials backend** (Phase 4), with its own security envelope.
- **Don't** widen the self-heal exit-code whitelist without explicit rationale. Adding code 22 ("session expired") looks reasonable but couples the cache to a different subsystem's failure mode; the cached selector is fine — the *session* needs renewing.
- **Don't** cache across sites. Per-site memory is the boundary (design doc §12). A selector that works on `prod-app` may have a homonym on `staging` that means something different.
- **Don't** auto-sanitize / strip sentinel bytes silently. Refuse with `EXIT_BLOCKLIST_REJECTED`. The agent's call site needs to know the cache write didn't happen so it doesn't assume a future hit; silent strip would create a "successful write that wrote nothing" failure mode that's worse than refusal.

## See also

- [Privacy canary recipe](privacy-canary.md) — sister pattern for read-side verbs that ingest secrets.
- [Path security recipe](path-security.md) — how `~/.browser-skill/memory/` enforces 0700 dir + 0600 file modes (mirrored from the captures pipeline).
- [Anti-patterns: tool extension](anti-patterns-tool-extension.md) — AP-7 (secrets-via-stdin), the broader pattern this recipe extends to cache-write surfaces.
- Design doc: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` §6 (memory + recipes integration), §12 (cross-site boundary), §3 H1 (self-heal threshold).
- Phase 11 part 1 plan-docs: `2026-05-10-phase-11-part-1-{i,ii,iii}-*.md` — per-PR scope decisions that compose into this recipe.
