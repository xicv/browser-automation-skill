# Workflow: incremental pattern discovery

**Goal:** demonstrate the full passive-observation → propose → cache-hit loop.

**Outcome:** after a few sessions of normal navigation, the skill auto-clusters visited URLs into patterns, stores them in `patterns.json`, and starts serving cache hits on subsequent agent actions.

## Prerequisites

- Site already registered (run [`login-then-scrape.md`](login-then-scrape.md) steps 0-3 if not).
- At least one cached archetype (or willingness to record one in step 3 below).

## The full loop in 5 steps

### 1. Navigate (passive observation writes `recent_urls.jsonl`)

```bash
bash scripts/browser-use.sh --set acme
bash scripts/browser-open.sh --url 'https://app.acme.com/orders/1001'
bash scripts/browser-open.sh --url 'https://app.acme.com/orders/1002'
bash scripts/browser-open.sh --url 'https://app.acme.com/orders/1003'
bash scripts/browser-open.sh --url 'https://app.acme.com/customers/jane-doe'
bash scripts/browser-open.sh --url 'https://app.acme.com/customers/john-roe'
bash scripts/browser-open.sh --url 'https://app.acme.com/customers/jim-roe'

cat ~/.browser-skill/memory/recent_urls.jsonl
# → 6 rows; each {ts, url, verb:"open", site:"acme", schema_version:1}
```

The tee is automatic on successful `browser-open` (PR #125 Pick A6).

### 2. Propose patterns from the observation log

```bash
bash scripts/browser-do.sh propose --site acme --from-recent
# → 2 _kind:proposal events:
#   {url_pattern:"/orders/:id",      archetype_id:"orders-id",      count:3}
#   {url_pattern:"/customers/:slug", archetype_id:"customers-slug", count:3}
# → summary: proposals:2 auto_recorded:0 skipped_known:0
```

`:id` from PR #97 (11-2-ii numeric heuristic); `:slug` from PR #127 (Pick A2). Neither row written to `patterns.json` yet — `propose` is read-only by default (C5 invariant from 11-2-ii).

### 3. Auto-record the proposals

```bash
bash scripts/browser-do.sh propose --site acme --from-recent --auto-record
# → same 2 proposals, but now auto_recorded:2 in summary
# → patterns.json gains 2 rows

cat ~/.browser-skill/memory/acme/patterns.json | jq '.patterns'
# → [
#     {url_pattern:"/orders/:id",      archetype_id:"orders-id",      hit_count:1, ...},
#     {url_pattern:"/customers/:slug", archetype_id:"customers-slug", hit_count:1, ...}
#   ]
```

Re-running with `--auto-record` is idempotent (filter-before-write pattern from PR #121).

### 4. Record an intent against the archetype

Need a cached selector for an action. Snapshot a real page + pick a ref:

```bash
bash scripts/browser-open.sh --url 'https://app.acme.com/orders/1001'
bash scripts/browser-snapshot.sh
# → eN list; find the "cancel order" button's ref, e.g. e12

# Record the intent → selector binding. browser-do record auto-derives
# the archetype-id from the URL pattern.
bash scripts/browser-do.sh record \
  --site acme \
  --intent "cancel order" \
  --selector 'button[data-action="cancel"]' \
  --url 'https://app.acme.com/orders/1001'
# → patterns.json + archetypes/orders-id.json updated
```

### 5. Cache hit dispatch (zero LLM tokens)

```bash
bash scripts/browser-do.sh \
  --site acme --verb click \
  --intent "cancel order" \
  --url 'https://app.acme.com/orders/1002'
# → cache_hit:true; dispatches click with --selector button[data-action="cancel"]
# → no snapshot needed; no LLM ref-resolution
```

Same intent across different URLs of the same archetype → all served by one cached selector.

## Observation

The cache hit + write events both tee into `events.jsonl` (PR #115 Pick A1):

```bash
jq -c 'select(.cache_hit==true)' ~/.browser-skill/memory/events.jsonl | wc -l
# → count of cache hits across all browser-do --intent runs

bash scripts/browser-doctor.sh | grep "memory cache hit"
# → memory cache hit rate: X% (H/T events)
```

Run the loop on enough URLs and the hit-rate climbs. Design target: ≥70% after 20+ same-archetype actions.

## Self-heal

If a selector breaks (4 consecutive failures), `disabled:true` flips in the archetype JSON + an entry appends to `self_heal_history[]` (PR #119 Pick A5):

```bash
jq '.interactions[] | select(.self_heal_history | length > 0)' \
  ~/.browser-skill/memory/acme/archetypes/orders-id.json
# → array of {ts, event:"disabled"|"healed", fail_count, selector_at_time}
```

Next `browser-do --intent "cancel order"` returns `cache_miss reason:intent_not_cached` (disabled is indistinguishable from never-cached per D3); agent re-resolves + re-records via step 4, which appends a `"healed"` entry.

## Next steps

- Run [`cache-driven-bulk-operation.md`](cache-driven-bulk-operation.md) to see ROI at scale.
- Tweak the slug heuristic (`scripts/lib/node/url-pattern-cluster.mjs`) if your site uses non-standard patterns.

## Don't

- **Don't manually edit `patterns.json` or archetype JSONs.** Use `browser-do record` / `memory_record_pattern` (the lib API). Hand edits bypass the canonical-pattern compare (PR #123 Pick A4) and may create redundant rows.
- **Don't auto-record without reviewing.** First-time run on a new site: omit `--auto-record`, read the proposals, decide. `--auto-record` shines after the heuristics have been validated on the site.
