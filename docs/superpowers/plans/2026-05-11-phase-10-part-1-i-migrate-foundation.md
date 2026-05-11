# Phase 10 part 1-i — `lib/migrate.sh` foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First sub-part of Phase 10. Ships `scripts/lib/migrate.sh` (pure read/write API for schema-version detection + migration dispatch + atomic-swap + rollback) plus `scripts/lib/migrators/` directory scaffold (empty registry — no actual migrators register here; that's 10-1-iii). NO verb integration (deferred to 10-1-ii `browser-migrate`).

**Branch:** `phase-10-part-1-i-migrate-foundation`
**Tag:** `v0.57.0-phase-10-part-1-i-migrate-foundation`

---

## Locked decisions (carry-through from design doc 2026-05-11)

- **MIG1** Per-schema versions in `${BROWSER_SKILL_HOME}/versions.json`.
- **MIG2** Migrators registered per schema; registry directory `scripts/lib/migrators/<schema>/v<from>_to_<to>.sh`.
- **MIG3** Atomic write + automatic backup at `${BROWSER_SKILL_HOME}/backups/<schema>/<file>.bak.v<N>`. Validation via `jq -e .` before atomic-swap.
- **MIG5** Pure bash + jq; no Node.

## Storage shape (frozen at v1)

```
${BROWSER_SKILL_HOME}/
├── version                                # legacy v1 marker (kept for compat; reads as fallback)
├── versions.json                          # mode 0600; new — per-schema versions
└── backups/                               # mode 0700, lazy-created
    └── <schema>/                          # mode 0700
        └── <basename>.bak.v<N>            # mode 0600
```

**`versions.json` schema (frozen at v1):**

```json
{
  "schema_version": 1,
  "schema_versions": {
    "sites": 1,
    "sessions": 1,
    "credentials": 1,
    "captures": 1,
    "baselines": 1,
    "memory": 1,
    "config": 1
  },
  "skill_version": "v0.56.0"
}
```

**Lazy creation.** `versions.json` not created at install time; first `migrate_init` call creates it (defaults all known schemas to v1 if absent OR reads from legacy `version` file). `backups/` similarly lazy-created on first `_migrate_backup` call.

## API additions

### `scripts/lib/migrate.sh` (new lib helper)

```bash
# Public API
migrate_init                    # mkdir backups/; create versions.json mode 0600 if missing; idempotent
migrate_get_version SCHEMA      # echoes current schema_version for SCHEMA (defaults to 1 if missing)
migrate_set_version SCHEMA N    # writes SCHEMA → N in versions.json (atomic)
migrate_check                   # echoes JSON listing schemas needing migration; reads registry to determine target versions
migrate_run [SCHEMA] [TARGET_FN_OVERRIDE_VAR_NAME]  # dispatches registered migrators in version-order; SCHEMA optional (limit to one); TARGET_FN_OVERRIDE_VAR_NAME = test-only seam for fixture migrators
migrate_rollback SCHEMA         # restores latest backup for SCHEMA's first migrated file; bumps version back
migrate_status                  # echoes JSON of all schema versions
migrate_clean_backups [N]       # discards backups beyond last N versions per schema (default 5)

# Internal helpers
_migrate_register SCHEMA FROM TO FN    # adds migrator fn to in-process registry table
_migrate_load_registry                 # sources every scripts/lib/migrators/*/v*_to_v*.sh under BROWSER_SKILL_MIGRATORS_DIR (defaults to repo lib/migrators/)
_migrate_backup SCHEMA FILE            # creates ${BROWSER_SKILL_HOME}/backups/<schema>/<basename>.bak.v<current_version>; mode 0600
_migrate_atomic_write FILE NEW_JSON    # validates via jq -e; atomic-swap; returns 1 + warns on validation failure
_migrate_load_versions                 # reads versions.json (or legacy version file); echoes JSON
_migrate_save_versions JSON            # atomic-write versions.json
```

All functions:
- Source-only — no CLI entry point in this PR (verb is 10-1-ii).
- Use `assert_safe_name SCHEMA "schema-name"` to constrain schema names.
- Atomic write pattern: `tmp.$$ → chmod 600 → mv` (mirror `lib/site.sh` precedent).

### `scripts/lib/migrators/` (new directory; empty registry)

Empty in 10-1-i. Real migrators ship in 10-1-iii (no-op `v1_to_v2` for memory archetype JSONs). Tests use `BROWSER_SKILL_MIGRATORS_DIR` env override pointing at fixture migrators (mirrors `BROWSER_DO_DISPATCH_OVERRIDE` test-only seam pattern from 11-1-iii self-heal).

## Test cases (RED → GREEN)

`tests/migrate.bats` (new file, ~12 cases):

1. `migrate_init` — creates `versions.json` mode 0600 + `backups/` mode 0700; idempotent on re-call.
2. `migrate_init` — when legacy `version` file exists ("1\n"), reads it + creates versions.json with all schemas at 1.
3. `migrate_get_version` — returns 1 for unknown schema (default).
4. `migrate_set_version` + `migrate_get_version` — round-trip.
5. `migrate_check` with empty registry → no schemas needing migration; exit 0; summary `pending:0`.
6. `migrate_check` with one identity v1→v2 migrator registered for `test` schema (via `BROWSER_SKILL_MIGRATORS_DIR` fixture) + `test` at v1 → reports needs-migration via `_kind:migration_needed` event.
7. `migrate_run` with empty registry → no-op; exit 0; summary `migrated:0`.
8. `migrate_run` with identity migrator → schema bumped to v2; backup created at `backups/test/<file>.bak.v1`; mode 0600.
9. `migrate_run` validates JSON via `jq -e .`; refuses to atomic-swap on validation failure; schema version unchanged.
10. `migrate_rollback test` → restores from latest backup; version bumped back to 1.
11. `migrate_clean_backups 1` — keeps newest backup per schema; older backups discarded.
12. `migrate_status` — echoes JSON of all schema versions; non-empty for known schemas.

## Sub-scope (what 10-1-i does NOT do)

- **No `browser-migrate` verb.** 10-1-ii.
- **No real migrators registered.** Empty registry; tests use fixture migrators via env override.
- **No typed-phrase confirmation.** Verb-layer concern; lands in 10-1-ii.
- **No concurrent-migration lock file.** Lib doesn't enforce single-instance; verb-layer adds `${BROWSER_SKILL_HOME}/.migrate.lock` per design open question §4.
- **No rollback chain.** Single-step rollback only; multi-version chains require multiple `migrate_rollback` invocations.
- **No automatic migration trigger.** All migrations explicit via `migrate_run`.
- **No skill_version write to versions.json beyond initial value.** Updated by future verb invocations.

## Path security + privacy canary

- Backup files at `${BROWSER_SKILL_HOME}/backups/<schema>/<basename>.bak.v<N>` with mode 0700 dir + 0600 files. Mirrors capture pipeline (Phase 7).
- Schema names validated via `assert_safe_name` — constrained to `^[A-Za-z0-9_-]+$`. Prevents path traversal via schema arg.
- Privacy canary: lib doesn't echo any file content to stdout. All output goes through `summary_json` + `printf '%s\n' "$(jq -nc ...)"` for events. Test asserts canary fixture file with `PASSWORD-CANARY` content survives migration without leak.

## Acceptance

- `tests/migrate.bats` 12 cases all green on macos-latest + ubuntu-latest CI.
- `bash tests/lint.sh` exit 0.
- All atomic writes go through `_migrate_atomic_write` (single grep target for reviewers).
- `BROWSER_SKILL_MIGRATORS_DIR` env override documented inline as test-only seam.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.
- HANDOFF refresh: Phase 10 progress section added; 1-i marked ✅; queue 1-ii (`browser-migrate` verb).

## Notes for follow-ups

- **10-1-ii: `browser-migrate` verb** — sub-mode dispatch (check/run/rollback/status/clean-backups); `--yes` confirmation OR typed-phrase fallback; `--schema NAME` filter; lock file.
- **10-1-iii: first real migrator** — no-op `v1_to_v2` for memory archetype JSONs; validates registry + dispatch end-to-end.
- **10-1-iv (if needed)** — concurrent-migration lock file (per design open question §4); could fold into 10-1-ii.
