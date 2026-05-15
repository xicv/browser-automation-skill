# Migrators — `stats` schema (Phase 12 part 2)

Per-action telemetry log under `${BROWSER_SKILL_HOME}/memory/`:
- `stats.jsonl` — append-only JSONL, one event per adapter call (source of truth)
- `stats.db` — lazy-built SQLite mirror, rebuilt from JSONL on `browser-stats rebuild`

Schema starts at v1. **No migrator needed until shape changes** (mirrors the
`recent_urls/` precedent — registry tolerates a schema with no `v*_to_v*.sh`
file as long as `versions.json` keeps it pinned at v1).

## When a v2 ships

1. Drop `v1_to_v2.sh` here defining `migrate_stats_v1_to_v2(file_path)`.
2. Bump the JSONL writer's `STATS_SCHEMA_VERSION` constant in
   `scripts/lib/stats.sh`.
3. SQLite mirror rebuilds itself on next `browser-stats rebuild` from the
   (now-migrated) JSONL — no SQL DDL migration needed because
   `audit_events.raw_json` carries the source event verbatim.

## Event schema reference

Canonical event shape: [`references/stats-schema.json`](../../../../references/stats-schema.json).
Field naming follows OpenInference + OTel GenAI v1.40 conventions
(snake_case dot-name flattening).
