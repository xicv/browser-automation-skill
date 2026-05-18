# Recipe — Phase 13 fingerprint rescue

**Use when**: a cached selector goes stale (class rename, id rename, minor DOM
reshuffle). The Phase-11 memory cache used to require 4 consecutive failures
+ an LLM re-resolve to recover. Phase 13 adds a *pre-LLM* rescue tier that
tries to find an equivalent element via weak-fingerprint similarity. If it
succeeds, the cache silently heals (selector overwritten, fail_count reset,
`self_heal_history[]` appended with `event:"rescued"`). If it fails, the
existing fail_count path runs unchanged.

**Inspired by**: Scrapling's adaptive selectors. *Not* a Scrapling adapter —
the algorithm is ported as ~150 LOC of Node-side scoring + bash glue. No
Python dependency added.

## When the rescue runs

Only on `browser-do --intent` cache-hit-then-fail with exit code
`EXIT_EMPTY_RESULT` (11) or `EXIT_ASSERTION_FAILED` (13). Environmental
failures (network 30, tool crash 42, timeout 43) skip the rescue — those
would poison the cache if counted.

```
cache hit → dispatch verb → adapter resolves 0 elements (rc=11)
                              │
                              ▼
                  memory_fingerprint_rescue
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
   returns rescued_selector            returns "" (no match ≥ threshold)
              │                               │
              ▼                               ▼
       retry verb with rescued     memory_record_failure (existing path)
              │                       fail_count++ → after 4 → disabled
       retry succeeds?
              │
        ┌─────┴─────┐
        ▼           ▼
       yes          no
        │           │
   memory_record_heal:      memory_record_failure (existing path)
   - overwrite selector
   - reset fail_count
   - bump success_count
   - append self_heal_history
   - emit stats event {rescued:true}
```

## Algorithm

1. **Parse cached selector → weak fingerprint** (bash + jq):

   ```
   "button.delete"            → { tag: "BUTTON", classes: ["delete"], attrs: {} }
   "#submit"                  → { tag: "*",      classes: [],         attrs: {id: "submit"} }
   "form > input.email"       → { tag: "FORM",   classes: ["email"],  attrs: {} }  (combinator stripped — weak)
   ```

   Combinators (`>`, `+`, `~`), pseudo-classes (`:hover`), attribute operators
   (`^=`, `*=`) are not parsed. The fingerprint will simply be weaker and the
   JS scorer will probably miss — caller falls through to LLM re-resolve.

2. **Inject scorer into the page** via `browser-extract --eval` (Phase 13 JS
   file: `scripts/lib/fingerprint-rescue.js`). Constants `__FP` (the
   fingerprint) and `__TH` (threshold) are prepended bash-side.

3. **Score each DOM element**:

   ```
   score = 0.4 × tag_match
         + 0.4 × jaccard(target.classes, candidate.classList)
         + 0.2 × jaccard(target.attrs,   candidate.attributes)
   ```

4. **Synthesise selector for the best-scoring candidate** above threshold:

   ```
   1. #id                    (when id is /^[A-Za-z][\w-]*$/ AND uniquely resolving)
   2. [data-testid="…"]      (preferred test-automation hook)
   3. tag.class[.class…]     (uniquely resolving)
   4. nth-child path         (absolute last-resort)
   ```

## Threshold

Default `0.70`. Override per-session:

```bash
BROWSER_DO_RESCUE_THRESHOLD=0.85 bash scripts/browser-do.sh --site myapp --verb click --intent "delete row" --pattern '/devices/:id'
```

- `0.70` (default) — Scrapling-like balance. Accepts moderate drift (class
  rename) but rejects very-different candidates.
- `0.85` — conservative. Fewer false positives, more LLM round-trips on
  borderline drift.
- `0.50` — permissive. More heals, but watch the `failure_mode=
  wrong_element_acted` count in `browser-stats report` for false-positive
  drift.

## Audit visibility

Each successful rescue emits a dedicated stats event:

```json
{
  "schema_version": 1,
  "ts": "2026-05-18T01:02:03.456Z",
  "gen_ai_tool_name": "browser-do.fingerprint_rescue",
  "verb": "do",
  "adapter_route": "browser-do",
  "outcome": "success",
  "rescued": true,
  "fingerprint_from_selector": "button.delete",
  "fingerprint_to_selector": "button[data-testid=delete-btn]"
}
```

Query the heal-rate:

```bash
bash scripts/browser-stats.sh report --verb do
# → look for "browser-do.fingerprint_rescue" rows + outcome=success share
```

## When NOT to use

- **Cross-page rescue.** The rescue only runs against the *currently-loaded*
  DOM. If the verb already redirected and the cached selector is for the
  prior page, rescue won't find it. (`navigation_mismatch` failure mode
  instead.)
- **Identifier-free designs.** If the target element has no id, no
  data-testid, no stable classes, and no unique nth-child position, the
  synthesised selector will be brittle. Better to invest in a stable
  test-automation hook than depend on rescue.
- **Heavy DOMs.** The scorer walks `document.querySelectorAll('*')` — O(n).
  For pages with 10k+ DOM nodes the scoring will take >500ms. Consider
  scoping with `document.querySelectorAll(target.tag.toLowerCase())` if you
  hit this in practice (future v2 — the current implementation prioritises
  recall over speed).

## Failure modes mapped (vs the Phase-12 stats audit)

| Outcome | failure_mode | rescued | Interpretation |
|---|---|---|---|
| Cache hit, adapter ok | null | null | Steady-state. No rescue ran. |
| Cache hit, adapter fail, rescue ok | null | true | Silent heal. Audit row: `gen_ai_tool_name=browser-do.fingerprint_rescue`. |
| Cache hit, adapter fail, rescue no-match | stale_ref (on the verb event) | null | Original fail_count++. Eventual LLM re-resolve. |
| Cache hit, adapter fail, rescue match-but-retry-fail | stale_ref (on the verb event) | false (future — currently null) | Algorithm picked wrong candidate. Track this metric to tune threshold. |
| Cache hit, adapter wrong-click | wrong_element_acted | true (false positive!) | Rescue scored a wrong element ≥ threshold. **Tune threshold up** if this rises. |

## Related

- Phase 11 `self_heal_history[]` lifecycle is preserved — see `scripts/lib/memory.sh::memory_record` (enabled→disabled) + `memory_record_failure` (disabled→enabled). Phase 13 adds the third event type: `event:"rescued"`.
- Phase 12 audit surface: `references/browser-stats-cheatsheet.md`.
