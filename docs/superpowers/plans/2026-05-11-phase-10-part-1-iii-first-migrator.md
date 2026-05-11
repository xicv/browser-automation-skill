# Phase 10 part 1-iii — first real migrator (no-op v1_to_v2 for memory archetype JSONs) — CLOSES Phase 10 part 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close Phase 10 part 1 with the first real migrator. Validates the registry + dispatch end-to-end against production code (not test fixtures). Picks the lowest-risk target: memory archetype JSONs (Phase 11 schema; not user-facing UI; safe to ship a no-op identity migrator that bumps the schema_version field).

**Branch:** `phase-10-part-1-iii-first-migrator`
**Tag:** `v0.59.0-phase-10-part-1-iii-first-migrator`

---

## Locked decisions

- **F1 — First migrator is identity (no-op + version bump only).** No data shape change. The migrator simply reads each archetype JSON, ensures `schema_version: 1` field is present (defensive — already true for all current archetypes), atomic-swaps. Validates the dispatch path without risking data corruption.
- **F2 — Memory archetype JSONs are the target.** Reasons:
  - Already-isolated state under `${BROWSER_SKILL_HOME}/memory/<site>/archetypes/<id>.json` (Phase 11 1-i shape).
  - Single-file pattern (each archetype is one JSON file); easy to migrate per-file.
  - Clean schema_version field already present (frozen at v1 in Phase 11 1-i); migrator just bumps to v2.
  - **Not** user-facing data — corruption would only break cache hits, not user-typed credentials/sessions.
- **F3 — Wire `versions.json::schema_versions.memory` semantics.** When migrator runs, the lib's `migrate_set_version memory 2` is invoked by `migrate_run` (already happens automatically per 10-1-i). Subsequent `migrate_check` reports the schema as up-to-date.
- **F4 — Migrator file location:** `scripts/lib/migrators/memory/v1_to_v2.sh` defining `migrate_memory_v1_to_v2 <archetype_json_path>`. Per the registry convention from 10-1-i.
- **F5 — Migration scope:** every `*.json` under `${BROWSER_SKILL_HOME}/memory/` (sub-find). The lib's `migrate_run` already does this via `find ... -type f -name '*.json'`. **Includes patterns.json + archetype JSONs both.** Migrator is a no-op for any JSON that doesn't have an `interactions` array (patterns.json has `patterns:[]`); we just bump `schema_version`.

## Implementation strategy

### `scripts/lib/migrators/memory/v1_to_v2.sh`

```bash
# Phase 10 1-iii: first real migrator. No-op identity for memory schema.
# Validates the registry + dispatch end-to-end without risking data corruption.
# Future v2_to_v3 (or beyond) will land per actual schema-shape changes.
migrate_memory_v1_to_v2() {
  local file_path="$1"
  jq '.schema_version = 2' "${file_path}" > "${file_path}.tmp"
  mv "${file_path}.tmp" "${file_path}"
}
```

That's it. ~10 LOC. The lib does atomic-swap + validation + backup automatically.

## Test cases (RED → GREEN)

`tests/migrators-memory.bats` (new file, ~3 cases):

1. Registry auto-loads memory v1_to_v2 — `migrate_check` after seeding a memory archetype reports `_kind:migration_needed schema:memory from:1 to:2`.
2. `browser-migrate run --yes --schema memory` end-to-end: bumps `versions.json::schema_versions.memory` to 2; archetype JSON's `.schema_version` field bumped to 2; backup at `backups/memory/<id>.json.bak.v1` mode 0600.
3. patterns.json + archetype JSON both migrated (find walks both).

## Sub-scope (what 10-1-iii does NOT do)

- **No data shape change.** Identity migrator only.
- **No new lib helpers.** Reuses 10-1-i (lib/migrate.sh) + 10-1-ii (browser-migrate verb) entirely.
- **No `--auto-migrate` flag on doctor.** Migration stays opt-in.
- **No documentation of the v2 shape** — there isn't one yet beyond `schema_version: 2`. When a real shape change ships, that PR's plan-doc documents the new shape.
- **No migration of existing user state.** Tests use fresh fixtures; production users on v1 will see "1 migration needed" on first `browser-migrate check` post-upgrade.

## Acceptance

- `tests/migrators-memory.bats` 3 cases all green.
- Existing `tests/memory.bats` + `tests/migrate.bats` + `tests/browser-migrate.bats` still green (no regressions).
- `bash scripts/browser-migrate.sh check` against an existing v1 memory state → emits `_kind:migration_needed schema:memory from:1 to:2`.
- `bash scripts/browser-migrate.sh run --yes` migrates memory schema to v2 without errors.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.
- HANDOFF refresh: closes Phase 10 part 1 (3/3 sub-parts shipped); queue Phase 10 status as ✅ COMPLETE for v1.

## Notes for follow-ups

- **Future migrators** ship case-by-case as schema shapes change. Each PR adds one `lib/migrators/<schema>/v<from>_to_<to>.sh` file + 3 bats. ~30 LOC + ~3 bats per real migration.
- **Phase 10 part 2 is NOT planned** — Phase 10 is infrastructure; per-schema migrations are case-by-case PRs from here on.
- **Consider promoting `_acquire_migrate_lock`** to `lib/lock.sh` if a 2nd verb ever needs file-locking. Defer.
- **Doctor integration** — `doctor` could optionally call `migrate_check` (read-only) and surface pending migrations. **Don't auto-migrate**; just signal. Future tiny PR.
