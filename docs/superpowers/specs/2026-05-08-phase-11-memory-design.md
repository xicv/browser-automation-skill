# Phase 11 — Memory: auto-learned per-archetype selector/action cache

> Design doc. Captures decisions before code lands. Sequenced **after Phase 9** (flow runner). Implementation begins when Phase 9 ships.

## 1. Why this exists

Today, every browser action by an agent flows: snapshot → LLM picks `eN` ref → bash dispatches verb → repeat. **Every action costs LLM tokens, even on actions the agent has performed many times before.**

Goal: cache learned `(url-pattern, intent) → selector` mappings so repeated actions execute without re-reasoning. Agents get measurably faster + cheaper the more they use the skill.

State of the art (May 2026) confirms the pattern works. Skyvern: "auto-caching remembers element locations to skip LLM calls on repeat visits". Stagehand: "after the framework learns how to interact with a site, it caches those actions and runs them without LLM inference." Agent-E "Skill Harvesting" — 40% faster on domain-similar tasks after 20+ skills accumulated. Cumulative skill memory is a real, proven primitive.

## 2. Scope of Phase 11

**In scope:**
- Per-site, per-URL-pattern, per-intent selector cache.
- URL-pattern recognition via [URLPattern](https://developer.mozilla.org/en-US/docs/Web/API/URL_Pattern_API) (web standard, Node 20+).
- New high-level verb `browser-do --intent "..."` that consults memory first, falls back to snapshot+reasoning on miss.
- Self-healing: cached selector failure → invalidate + re-resolve + write back.
- Pure-filesystem persistence under `~/.browser-skill/memory/` (mode 0700, mode 0600 files).

**Out of scope:**
- Cross-site memory sharing (each site's memory is isolated).
- Cross-user memory sharing (memory inherits the per-user `~/.browser-skill/` boundary).
- Vision-based element resolution (this skill is DOM/snapshot-based; vision is Phase 12+ if it lands).
- Auto-generation of selectors before any human/agent observation (Phase 11 is record-from-use, not synthesize-from-page).

## 3. Architectural decisions (locked)

Per the option-table the user accepted on 2026-05-08:

### M1: Cache key = `(site, url_pattern, intent_phrase)`

The cache lookup is composable: site (already a first-class skill concept), URL pattern (URLPattern-derived), and intent phrase (the agent's natural-language description of what to do). Two `/devices/123` and `/devices/456` URLs both hit the same archetype if the pattern resolved them as `/devices/:id`.

**Rejected:** M2 (literal URL — loses generalization); M3 (eN-index — brittle, snapshot-order-dependent).

**Open: intent canonicalization.** Same action phrased differently misses the cache. Not in scope for Phase 11 part 1; revisit in part 2 if cache-hit-rate disappoints. Possible mitigations: small intent-normalizer (strip articles, lowercase, lemmatize) or embed-vector similarity. Both add complexity; ship without first, measure, revisit.

### U1: URL pattern via URLPattern API

`URLPattern` ships in Node 20+. Syntax: `/devices/:id` (named group), `/users/:userId(\d+)` (regex constraint), `/api/*` (wildcard segment). Web standard; no rolling-our-own.

**Rejected:** U2 (path-to-regexp — npm dep, behind URLPattern); U3 (manual user-defined — high friction); U4 (auto-cluster — complex; defer to part 2).

### E1: Engagement via new high-level `browser-do` verb

```
bash scripts/browser-do.sh --site prod-app --intent "click delete button"
# → looks up cache for (prod-app, current_archetype, "click delete button")
# → on hit: execute cached action directly (zero LLM tokens)
# → on miss: snapshot + LLM picks eN + click + writes back to cache
```

Existing verbs (`browser-click.sh`, `browser-fill.sh`, etc.) are untouched. `browser-do` is the memory-aware orchestrator that calls into the existing primitives.

**Rejected:** E2 (auto-augment snapshot output — implicit; risks cache poisoning); E3 (both — too many failure modes).

### H1: Self-healing — mark fail then invalidate

On cached-selector failure:
1. Increment `fail_count` on the interaction record.
2. If `fail_count > 3`, invalidate (mark `disabled: true`).
3. On next invocation with same intent, re-snapshot + re-resolve via LLM.
4. Write new selector with `fail_count = 0`.

**Rejected:** H2 (multiple selector strategies per intent — robust but doubles storage and complicates tests); H3 (no self-healing — fails loud; pushes burden onto user).

H2 remains a Phase 11 part 3 follow-up if H1 isn't robust enough.

## 4. Storage shape

```
~/.browser-skill/memory/                       # mode 0700 (lazy-created on first cache write)
├── _index.json                                # mode 0600
│     {schema_version: 1, sites: ["prod-app", "staging"], total_archetypes: N, total_interactions: M}
└── <site>/                                    # mode 0700
    ├── patterns.json                          # mode 0600
    │     {patterns: [{url_pattern: "/devices/:id", archetype_id: "devices-detail", first_seen, last_seen, hit_count}]}
    └── archetypes/
        └── <archetype_id>.json                # mode 0600
              {schema_version, archetype_id, url_pattern, first_seen, last_seen, use_count, interactions: [...]}
```

Per-archetype JSON shape (frozen at Phase 11 part 1 ship; field additions non-breaking, removals/renames bump `schema_version`):

```json
{
  "schema_version": 1,
  "archetype_id": "devices-detail",
  "url_pattern": "/devices/:id",
  "first_seen": "2026-05-09T10:00:00Z",
  "last_seen": "2026-05-09T11:30:00Z",
  "use_count": 17,
  "interactions": [
    {
      "intent": "click delete button",
      "selector": "button[data-testid='delete-device']",
      "first_used": "2026-05-09T10:15:00Z",
      "last_used": "2026-05-09T11:30:00Z",
      "success_count": 14,
      "fail_count": 0,
      "disabled": false,
      "self_heal_history": []
    }
  ]
}
```

**Lazy creation.** `~/.browser-skill/memory/` is not created at install time. First `browser-do` invocation that needs to write the cache calls `memory_init_dir`. Mirrors `captures/` lazy-creation precedent from Phase 7.

**No cross-site `_index.json` writes during fast paths.** `_index.json` updates are best-effort/coalesced; per-site `patterns.json` is the authoritative path-resolution data.

## 5. Sub-part split (5 sub-parts)

User accepted the split:

| Sub-part | Scope | PR size | Depends on |
|---|---|---|---|
| **11-1-i** | `lib/memory.sh` foundation — read/write archetype JSON, URL→archetype resolution via URLPattern in node-helper. Pure read/write API; no verb integration. Unit-tested with fixture URLs/archetypes. | medium-small | — |
| **11-1-ii** | `browser-do --intent "..."` verb — looks up cache; on hit runs cached action; on miss runs snapshot+reasoning+write-back. Integration test against stub adapter. | medium | 11-1-i |
| **11-1-iii** | Self-healing — H1: cached-selector failure → mark fail → invalidate (`fail_count > 3`) → re-resolve → write back. Cache decay TBD (TTL? success thresholds? not in scope unless H1 misbehaves). | small-medium | 11-1-ii |
| 11-2-i | Manual user-defined URL patterns — `--pattern '/devices/:id'` flag on `browser-do` first-pass. Skips auto-detection. | small | 11-1-iii |
| 11-2-ii | Auto-cluster URL patterns — observe N visits to a site; if URL paths diverge only at numeric/UUID segments, propose pattern; user/agent confirms. Optional. | medium | 11-2-i |

**Phase 11 part 1** = sub-parts 11-1-i + 11-1-ii + 11-1-iii (the memory foundation + verb + self-heal). MVP shippable after these three.

**Phase 11 part 2** = sub-parts 11-2-i + 11-2-ii (URL-pattern handling, manual then auto). Layered on top of part 1.

## 6. Layered defense — prior recipe corpus applies

Existing recipes (privacy-canary, path-security, body-bytes-not-body, model-routing) all apply to Phase 11. New recipe candidate:

- `references/recipes/cache-write-security.md` (post-Phase-11 part 1) — codifies: never cache a selector containing JS injection or unusual characters; lint the cache write side; cache-write goes through path-security validation; privacy-canary tests on cache-write paths to prove cached entries never carry credential bytes. **Per user direction: ships AFTER Phase 11 part 1, not with it.**

Per-recipe applicability:

| Recipe | How it applies to Phase 11 |
|---|---|
| `privacy-canary.md` | Cache-write paths get sentinel canary tests proving no credential bytes leak into cached interaction records. Login-related interactions (username/password fields) carry only the **selector**, never the credential. |
| `path-security.md` | `~/.browser-skill/memory/` mode 0700; archetype JSON files mode 0600. Mirrors capture pipeline. No `--path PATH` accepted from user; all paths constructed by the skill. |
| `body-bytes-not-body.md` | If a cached action involves a body (route fulfill memoization — speculative), reply ships `body_bytes` not `body`. Same discipline as Phase 6 part 7-ii. |
| `model-routing.md` | Memory hits skip LLM inference entirely — zero tokens. Compounds with `model: sonnet` + `effort: low` skill default + `/model opusplan` parent session. **Memory is the largest cost lever in the roadmap when fully realized.** |

## 7. Interaction with adjacent phases

| Phase | Interaction with memory |
|---|---|
| **Phase 7** (capture pipeline) | Independent. Captures are per-run artifacts; memory is cross-run. Memory may eventually consult capture artifacts (e.g. learn from previous snapshot.json files), but not in Phase 11. |
| **Phase 8** (obscura adapter) | Memory is adapter-agnostic. `browser-do` dispatches via the same router; whichever adapter resolves the cached selector, the cache works. Test with multiple adapters before declaring stable. |
| **Phase 9** (flow runner — `flow record` / `flow run`) | **Overlap zone.** Phase 9's `flow record` produces YAML flows manually (one shot, deliberate). Phase 11's memory auto-records per-action (incidental, accumulating). They're complementary: flows are deliberate macros; memory is incidental shortcuts. **Sequencing: Phase 11 ships after Phase 9** (per user decision) so flow record's manual semantics establish first; auto-recording layered on. **Open question: do flows write to memory? Does memory propose flows when N similar interactions accumulate?** Not for Phase 11 part 1; revisit when both layers are in place. |
| **Phase 10** (schema migration) | Memory schemas (`_index.json`, `patterns.json`, archetype JSONs) participate in Phase 10's migration tooling. `schema_version: 1` is the v1 contract; v2 needs a migration. Standard. |

## 8. Daemon state implications

Today the bridge daemon holds (`refMap`, `routeRules`, `tabs`, `currentTab`) — all in-memory closures. Memory is **not daemon-resident**: it's filesystem-persisted, read at verb-invocation time. This means:

- Memory survives daemon restarts (good — that's the point).
- Memory does not need IPC plumbing into the bridge.
- The deferred `DaemonState` object refactor (per HANDOFF) is independent of memory.

**Possible exception:** if Phase 11 part 1 wants per-tab `currentTab → archetype_id` resolution (e.g. switching tabs changes the active archetype), that *would* touch daemon state. **Defer this until needed.** Single-tab-archetype assumption holds for v1.

## 9. Cost economics (target metrics)

After 20+ similar actions per archetype (Agent-E benchmark threshold), expected behavior:

- **Cache hit rate:** ≥ 70% on routine flows (login, navigate, click "common" buttons).
- **Tokens per hit:** ~0 (no LLM call; bash + bridge dispatch only).
- **Tokens per miss:** same as today (snapshot + LLM picks ref + write-back).
- **Average cost reduction at 70% hit rate:** ~70% of action-side LLM tokens eliminated. Compounds with skill `model: sonnet` (3× cheaper than Opus) → ~21× cheaper than no-memory + Opus baseline.

These are targets, not measurements. Phase 11 part 1 ships with bats/e2e to verify hit-rate behavior; real-world numbers come from production use.

## 10. Test strategy

**Unit tests (`tests/memory.bats`):**
- `memory_init_dir` mode 0700, idempotent.
- `memory_resolve_archetype <site> <url>` — URL→archetype lookup; URLPattern resolution.
- `memory_lookup <site> <archetype> <intent>` — returns cached selector or null.
- `memory_record <site> <archetype> <intent> <selector>` — writes interaction record.
- `memory_record_failure <site> <archetype> <intent>` — increments fail_count; invalidates after threshold.
- Schema-version round-trip (v1 reader on v1 writer).

**E2E tests (`tests/browser-do.bats`):**
- First invocation: cache miss → snapshot + LLM-mode (stubbed) → cache write → `meta.cache_hit: false`.
- Second invocation same intent: cache hit → no snapshot → `meta.cache_hit: true` + zero stub-MCP calls.
- Different `/devices/N` URL → same archetype → cache hit.
- Stale selector → cached fails 4 times → invalidates → re-resolves on 5th run.

**Privacy canary (per recipe):**
- Login-flow interaction record never carries credential bytes (cache-write-side canary).

## 11. Acceptance criteria for Phase 11 part 1

- [ ] `lib/memory.sh` ships with all three sub-parts (foundation + verb + self-heal).
- [ ] `browser-do --intent "..."` verb routed via existing router (no special-case).
- [ ] Cache hit rate ≥ 70% on a synthetic 100-action loop against the stub adapter.
- [ ] `tests/memory.bats` + `tests/browser-do.bats` green on macos-latest + ubuntu-latest CI.
- [ ] All four existing recipes cited correctly in plan-doc + CHANGELOG.
- [ ] HANDOFF refresh notes Phase 11 part 1 shipped; queues part 2 (URL pattern handling).

## 12. Open questions (decide during implementation)

1. **Intent canonicalization** — strip articles? Lowercase? Lemmatize? Embed-vector match? Defer until cache-hit-rate measurements warrant complexity.
2. **Cache TTL/decay** — should successful selectors expire after N days unused? (Counter-argument: if it still works, why expire?) Defer; H1's fail-counter already invalidates broken selectors.
3. **Cross-site memory** — never. Hard boundary at the per-site level. (Re-evaluate only if user demand surfaces.)
4. **Memory as input to `flow record`** — could `flow record` propose flows by clustering N similar memory interactions? Phase 11 part 2 question.
5. **Privacy: memory in git?** — `~/.browser-skill/memory/` is gitignored same as `sessions/`, `credentials/`, `captures/`. **Memory is `[PERSONAL]`** — selectors aren't credentials but they reveal the user's flows. Default-private. Document in install.sh's `.gitignore` template.

## 13. Sequencing (locked)

```
Phase 7 (in progress: 1/5 sub-parts shipped) — capture pipeline
        ↓
Phase 8 — obscura adapter
        ↓
Phase 9 — flow runner (flow record + flow run + history + replay)
        ↓
Phase 10 — schema migration tooling
        ↓
Phase 11 — memory (this design doc)
   ├── part 1: sub-parts 11-1-i, ii, iii
   └── part 2: sub-parts 11-2-i, ii
        ↓
Recipe doc: cache-write-security.md (after Phase 11 part 1 ships)
```

## 14. References

Prior art:
- [Skyvern auto-caching + self-healing](https://www.skyvern.com/blog/layout-resistant-browser-automation-tools/)
- [Browserless 2026 SOTA review](https://www.browserless.io/blog/state-of-ai-browser-automation-2026)
- [Browser Harness — self-healing selectors](https://openflows.org/currency/currents/browser-harness/)
- [Agent-E + Skill Harvesting (WebVoyager 73.1%)](https://aimultiple.com/open-source-web-agents)
- [Hermes Agent — persistent MEMORY.md](https://hermes-agent.org/)
- [Autobrowse skill graduation pattern](https://www.browserbase.com/blog/autobrowse)

Web standards:
- [URL Pattern API — MDN](https://developer.mozilla.org/en-US/docs/Web/API/URL_Pattern_API)

Internal cross-references:
- Parent spec: `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §3.4 (storage layout), §4.5 (capture pipeline), §8 (security), §12 (sequencing)
- Phase 7 plan: `docs/superpowers/plans/2026-05-08-phase-07-part-1-i-capture-foundation.md`
- Recipe corpus: `references/recipes/{privacy-canary,path-security,body-bytes-not-body,model-routing}.md`
