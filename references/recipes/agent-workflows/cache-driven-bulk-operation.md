# Workflow: cache-driven bulk operation

**Goal:** process 50+ items via the memory cache. Demonstrate the ROI of the Phase 11 cache + Phase 11 v2 observation log loop.

**Outcome:** after a one-time learning phase (~3 actions), 50 subsequent actions dispatch with zero LLM ref-resolution. Token cost drops from ~5K × 50 = 250K to ~200 × 50 = 10K (25× reduction; representative ballpark).

## Prerequisites

- Site registered + session captured ([`login-then-scrape.md`](login-then-scrape.md) steps 0-3).
- Patterns + archetypes set up for the target action ([`incremental-pattern-discovery.md`](incremental-pattern-discovery.md) steps 1-4).
- A list of 50+ URLs that share the same archetype (e.g. `https://app.acme.com/orders/1001` through `/orders/1050`).

## Steps

### 1. Confirm the cache is primed

```bash
# Pattern should exist for /orders/:id, archetype orders-id, with at least one
# intent recorded (e.g. "cancel order").
jq '.patterns[] | select(.url_pattern == "/orders/:id")' \
  ~/.browser-skill/memory/acme/patterns.json
# → 1 row

jq '.interactions[] | select(.intent == "cancel order")' \
  ~/.browser-skill/memory/acme/archetypes/orders-id.json
# → 1 row with success_count >= 1
```

If either is empty, run [`incremental-pattern-discovery.md`](incremental-pattern-discovery.md) first.

### 2. Generate the URL list

```bash
seq 1001 1050 | sed 's|^|https://app.acme.com/orders/|' > /tmp/order-urls.txt
wc -l /tmp/order-urls.txt
# → 50 /tmp/order-urls.txt
```

### 3. Dispatch in a loop — zero LLM tokens after warm-up

```bash
bash scripts/browser-use.sh --set acme
exec 3</tmp/order-urls.txt
while IFS= read -r url <&3; do
  bash scripts/browser-do.sh \
    --site acme --verb click \
    --intent "cancel order" \
    --url "${url}" \
    --as acme--admin 2>&1 | tail -1 | jq -c '{verb, mode, cache_hit, dispatch_rc, url}'
done
exec 3<&-
```

Each iteration emits a one-line JSON summary. Watch `cache_hit:true` repeat 50 times.

### 4. Confirm ROI signal in doctor

```bash
bash scripts/browser-doctor.sh | grep "memory cache hit"
# → memory cache hit rate: 96% (50/52 events)
# (the 2 misses are the warm-up actions from step 1; hits scale linearly)
```

Or query `events.jsonl` directly:

```bash
jq -s '
  {
    total: length,
    hits: ([.[] | select(.cache_hit == true)] | length),
    rate_pct: (([.[] | select(.cache_hit == true)] | length) * 100 / length)
  }
' ~/.browser-skill/memory/events.jsonl
# → {total: 52, hits: 50, rate_pct: 96}
```

## Self-heal in motion

If the cached selector breaks mid-run (e.g. URL #25 is a different layout):

1. The dispatched `browser-click --selector ...` exits 11 (`EXIT_EMPTY_RESULT`).
2. `browser-do --intent` catches this on the D1 exit-code whitelist + calls `memory_record_failure`.
3. After 4 such failures, `disabled:true` flips + `self_heal_history[]` gains a `"disabled"` entry.
4. Subsequent iterations return `cache_miss reason:intent_not_cached` (disabled is indistinguishable from never-cached per D3).
5. Agent re-resolves the new selector + calls `browser-do record` → `disabled:false` + `"healed"` entry.
6. Loop resumes with cache hits.

Inspect the audit trail:

```bash
jq '.interactions[] | select(.self_heal_history | length > 0)
    | {intent, self_heal_history}' \
  ~/.browser-skill/memory/acme/archetypes/orders-id.json
```

## Numbers worth measuring

Before the dogfood loop, the comparison is theoretical. Run the script for 7 days against a real site you actually use. Then:

- **Cache hit rate per day:** trends upward as patterns are observed + recorded.
- **Wall-clock per action:** cache hit ≈ adapter dispatch only (50-200ms); cache miss ≈ full snapshot + agent reasoning (5-20s on cdt-mcp).
- **Token cost per action:** measure with `claude -p` harness (cache hit ≈ <500 input tokens; miss ≈ 3-10K).

The ROI claim ("zero LLM tokens on cache hit") is exact for the skill turn — the parent session may still consume tokens for context that's not skill-related.

## Don't

- **Don't run with `--auto-record` on an unverified corpus.** A bad heuristic match could pollute `patterns.json` with garbage. Validate the propose output first; auto-record after.
- **Don't assume cache hit means "did the right thing."** Cache hit means "skipped LLM ref-resolution + dispatched verb." Verb-level success (did the click actually cancel the order?) is the verb's exit code, not the cache lookup's status.
- **Don't run the loop in parallel against the same site.** `browser-do --intent` is single-shot; concurrent runs race on `memory_record_pattern`'s upsert. Serial is the design (PID-locking only on `browser-migrate`).
