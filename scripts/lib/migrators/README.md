# Phase 10 — Schema migrators

This directory is intentionally empty in 10-1-i (foundation only).

Real migrators land in 10-1-iii (no-op `v1_to_v2` for memory archetype JSONs) and case-by-case PRs thereafter.

## Convention

Each migrator is a bash file at `<schema>/v<from>_to_<to>.sh`. It must define a function named `migrate_<schema>_v<from>_to_v<to>` that takes a file path argument and mutates the file in-place (atomic-swap via tmp+mv).

Example (post-10-1-iii):

```
scripts/lib/migrators/
└── memory/
    └── v1_to_v2.sh           # defines: migrate_memory_v1_to_v2()
```

The registry auto-loader (`_migrate_load_registry` in `lib/migrate.sh`) sources every `v*_to_v*.sh` file under this dir, parses the version pair from the filename, and registers the fn.

## Test-only seam

Tests override via `BROWSER_SKILL_MIGRATORS_DIR=/tmp/fixture-migrators` env var. Production code never sets this.
