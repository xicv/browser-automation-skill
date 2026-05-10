# Phase 10 — Schema migration tooling

> Design doc. Captures decisions before code lands. Sequenced **after Phase 11 part 1 + part 2** (memory cache + auto-cluster propose). Implementation begins when first v1→v2 schema bump is needed (not blocking today; all schemas still v1).

## 1. Why this exists

Every on-disk schema in the skill carries a `schema_version: 1` field — a frozen v1 contract. The design assumed migration tooling would land before the first bump; nine schemas later, all still v1, no bump has happened, and tooling hasn't been built. **The first time anyone needs to add a non-additive field**, they'll need to migrate users in flight without losing state.

Goal: ship a `lib/migrate.sh` foundation + a one-command `browser-migrate` verb that:
1. Detects which schemas need migration on the user's disk.
2. Runs registered v1→v2 (and beyond) migration functions in order.
3. Backs up + atomic-swaps + supports rollback.
4. Reports state changes via the standard JSON event stream.

**This is necessary infrastructure but currently not blocking.** No urgent demand. Prioritize when first non-additive change is on the horizon.

## 2. Scope

**In scope:**
- `scripts/lib/migrate.sh` — pure read/write API for schema-version detection + migration dispatch + atomic swap + rollback.
- New verb `scripts/browser-migrate.sh` — agent + user surface; `check` / `run` / `rollback` / `status` / `clean-backups` sub-modes.
- Per-schema migration functions registered in `lib/migrate.sh` — opt-in registry (each schema declares its migrators).
- `~/.browser-skill/version` semantics — currently a marker file containing `1`; gets richer (per-schema versions or a single global version).
- Backup retention — keep N backups before discarding; defaults to 5.

**Out of scope:**
- Auto-migrate on every verb invocation. **Migration is opt-in via `browser-migrate run`** — silent state mutation is unacceptable.
- Schema downgrade beyond rollback to immediate-prior version. Cross-version downgrades (v3 → v1) require multiple `rollback` invocations; not auto-chained.
- Schema migration for state outside `~/.browser-skill/` (e.g. user-edited `.flow.yaml` files). Out of scope; user owns their own files.
- Backwards-compatible schema reads. Migrators are mandatory — old code reading new shape OR new code reading old shape is **not supported**. Run `browser-migrate run` first.

## 3. Architectural decisions (locked at design ship; no implementation yet)

### MIG1: Per-schema versions, not global

Each schema (sites, sessions, credentials, captures, baselines, memory, config) carries its own `schema_version` field. Migrating one schema doesn't touch the others. **Rejected:** global-version-bump everywhere — couples unrelated subsystems; one-line change to memory schema would force re-validation of credential storage.

**Storage shape change:** `~/.browser-skill/version` (currently a single integer) becomes `~/.browser-skill/versions.json`:

```json
{
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

Old `version` file kept as compatibility marker (contents `"1"` → migrate script reads + creates the new `versions.json`).

### MIG2: Migrators registered per schema; manifest-driven

Each schema has a `lib/migrators/<schema>/v1_to_v2.sh` (and `v2_to_v3.sh` etc) sourcing pattern. `lib/migrate.sh` reads `versions.json`, walks the migrator manifest, and runs each registered fn in version-order:

```bash
# scripts/lib/migrators/memory/v1_to_v2.sh
migrate_memory_v1_to_v2() {
  local archetype_path="$1"
  jq '.interactions |= map(. + {priority: 0})' "${archetype_path}" > "${archetype_path}.tmp"
  mv "${archetype_path}.tmp" "${archetype_path}"
}
```

Registry pattern reuses `scripts/lib/tool/` precedent (one-file-per-adapter; basename minus `.sh` is the canonical name).

**Rejected:** in-line all migrators in `lib/migrate.sh` — file would balloon as schemas evolve; per-schema-per-version isolation matches PR-review boundaries.

### MIG3: Atomic write + automatic backup; manual rollback

For each migration target file:
1. Read current state into `${file}.bak.v${current_version}`.
2. Apply migrator → write to `${file}.tmp.$$`.
3. Validate: `jq -e .` on the result.
4. Atomic swap: `mv ${file}.tmp.$$ ${file}`.
5. Update `versions.json` for this schema.

Backup retention: keep last 5 versions per file (default; configurable in `config.json`). Rollback: `browser-migrate rollback --schema NAME` reads `${file}.bak.v${prior_version}` and atomic-swaps back; updates `versions.json`. Discard backups older than the last 5 only on `browser-migrate clean-backups`.

**Rejected:** silent-fail-with-warn on validation error — leaves user in indeterminate state. Migration is all-or-nothing per file.

### MIG4: Verb shape: `browser-migrate {check,run,rollback,status,clean-backups}`

```
browser-migrate check                          # dry-run; reports schemas needing migration; exit 0 always
browser-migrate run [--schema NAME] [--yes]    # actually migrates; --yes skips confirmation; --schema NAME limits scope
browser-migrate rollback --schema NAME [--yes] # rollback ONE schema to prior version
browser-migrate status                         # show current versions for all schemas
browser-migrate clean-backups [--keep N]       # discard backups older than last N versions; default 5
```

`check` is read-only safe; agents can call it on every session start. `run` is destructive (changes state); requires `--yes` confirmation OR interactive typed-phrase ("migrate now").

**Rejected:** auto-migrate on `browser-doctor` invocation. Doctor is read-only diagnostic; conflating it with state mutation breaks the "doctor never changes state" invariant.

### MIG5: Migrators are pure bash + jq; no side effects beyond the target file

Migrators read the target file path + current version, mutate the file in-place via atomic swap. **No network calls. No environment modifications. No cross-file state.** Each migrator is unit-testable with a fixture file + expected output.

**Rejected:** node-based migrators — adds Node version constraints to migration tooling that bash + jq don't have.

## 4. Storage shape evolution

```
~/.browser-skill/                                    # mode 0700
├── version                                          # legacy v1 marker (kept for compat; reads as fallback)
├── versions.json                                    # mode 0600; new — per-schema versions + skill_version
├── config.json                                      # +schema_version field added during migration
├── baselines.json                                   # +schema_version field
├── sites/<name>.json                                # +schema_version field per file (or once at sites/.version)
├── sessions/<name>.json                             # same
├── credentials/...                                  # same
├── captures/<NNN>/meta.json                         # already has schema_version: 1
├── memory/<site>/{patterns.json,archetypes/<id>.json} # already has schema_version: 1
└── backups/                                         # mode 0700; new
    └── <schema>/<file>.bak.v<N>                     # mode 0600; rollback source
```

## 5. Sub-part split (3 sub-parts)

| Sub-part | Scope | PR size | Depends on |
|---|---|---|---|
| **10-1-i** | `lib/migrate.sh` foundation — `migrate_check`, `migrate_run`, `migrate_rollback`, `migrate_status`, `migrate_clean_backups`. Pure read/write API; no migrators registered yet (empty registry). Storage shape v1 frozen (`versions.json` + `backups/` dir). Unit-tested with fixture schemas + identity migrators. | medium | — |
| **10-1-ii** | `browser-migrate` verb — sub-mode dispatch (check/run/rollback/status/clean-backups); `--yes` confirmation; typed-phrase fallback for interactive. Bats integration tests against fixture schemas. | small-medium | 10-1-i |
| **10-1-iii** | First real migrator — pick one schema (likely `memory/archetypes/<id>.json`) and ship a no-op `v1_to_v2` migrator (adds `schema_version: 1` field if missing; harmless on already-v1 files). Validates the registry + dispatch end-to-end. | small | 10-1-ii |

**Phase 10 part 1** = sub-parts 10-1-i + 10-1-ii + 10-1-iii. Foundation + verb + first migrator. After this, real migrations land per schema as needed.

**No Phase 10 part 2 planned** — Phase 10 is infrastructure; once part 1 ships, future migrations are case-by-case PRs that just register a new migrator.

## 6. Layered defense — recipe applicability

| Recipe | How it applies to Phase 10 |
|---|---|
| `path-security.md` | Backup files at `~/.browser-skill/backups/` mode 0700 dir + 0600 files; mirrors capture pipeline. |
| `privacy-canary.md` | Migrators must NEVER echo file content to stdout (existing migrators write only the JSON event); canary tests assert post-migration file doesn't carry sentinel through the migrator. |
| `cache-write-security.md` | Migrators that touch memory files (`patterns.json`, `archetypes/<id>.json`) must preserve the canary refusal contract — no PASSWORD-CANARY appears in migrated files. |
| `body-bytes-not-body.md` | n/a — migrators don't deal with HTTP bodies. |
| `model-routing.md` | n/a — migration is bash + jq; no LLM. |

## 7. Interaction with adjacent phases

| Phase | Interaction |
|---|---|
| **Phase 7** (capture pipeline) | `meta.json` already carries `schema_version: 1`. Phase 10 part 1-iii could ship a no-op v1_to_v2 migrator for it. |
| **Phase 9** (flow runner) | `flow record` writes YAML; YAML schema versioning is **out of scope** (user-edited files, not skill-owned). Captures emitted by `flow run` carry `meta.json` versions; covered above. |
| **Phase 11** (memory) | `patterns.json` + `archetypes/<id>.json` carry `schema_version: 1`. **First likely real migration target** — when a new field is needed (e.g. `priority` for ordering proposals), v1_to_v2 migrator adds it with default value 0. |
| **Phase 11 v2 hardening** | Active observation log (`recent_urls.jsonl` per design doc backlog) introduces a NEW schema; gets `schema_version: 1` from inception + a migrator manifest entry from Phase 10. |

## 8. Cost economics (target metrics)

After Phase 10 part 1 ships:
- **Migration overhead per schema bump:** ~30 LOC for the migrator + ~3 bats; ship in same PR as the schema-bumping feature change.
- **Rollback time:** O(1) atomic swap from backup; faster than re-running the migration in reverse.
- **Backup disk usage:** N versions × current file size per schema. Default keep-5 means up to 5× current state. For typical user (~1MB total state), 5MB of backups. Cheap.

These are targets, not measurements. Phase 10 part 1 ships with bats coverage of dispatch + atomic-swap + rollback; real-world numbers come from first production migration.

## 9. Test strategy

**Unit tests (`tests/migrate.bats`):**
- `migrate_check` reports current versions; identifies schemas needing migration.
- `migrate_run` dispatches registered migrators in version-order; updates `versions.json`.
- `migrate_run --schema NAME` limits scope to one schema.
- `migrate_run` validates output via `jq -e .`; refuses to atomic-swap on validation failure.
- Backup created at `${file}.bak.v${prior_version}` before atomic swap.
- `migrate_rollback --schema NAME` reads backup + atomic-swaps + updates versions.json.
- `migrate_clean_backups --keep 3` discards backups older than the last 3.

**Integration tests (`tests/browser-migrate.bats`):**
- `browser-migrate check` exit 0 + reports schemas via `_kind:migration_needed` events.
- `browser-migrate run --yes` end-to-end migrates fixture schemas.
- `browser-migrate run` without `--yes` requires typed-phrase confirmation.
- `browser-migrate rollback --schema X --yes` restores prior version.

**Privacy canary (per recipe):**
- Memory file containing `PASSWORD-CANARY` sentinel can't appear post-migration (migrator should refuse OR strip OR error — TBD in 10-1-iii).

## 10. Acceptance criteria for Phase 10 part 1

- [ ] `lib/migrate.sh` ships with all five fns + atomic-swap + backup pattern.
- [ ] `browser-migrate` verb routed via existing router (no special-case).
- [ ] No-op v1_to_v2 migrator for memory archetype JSONs ships in 10-1-iii (validates registry + dispatch).
- [ ] `tests/migrate.bats` + `tests/browser-migrate.bats` green on macos-latest + ubuntu-latest CI.
- [ ] All five existing recipes cited correctly in plan-doc + CHANGELOG.
- [ ] HANDOFF refresh notes Phase 10 part 1 shipped; documents migration-on-first-bump pattern.

## 11. Open questions (decide during implementation)

1. **Migrator function signature** — `migrate_<schema>_<from>_to_<to> <file_path>` (per-file) OR `migrate_<schema>_<from>_to_<to>` (sweeps all files of that schema)? Lean **per-file** — simpler to reason about + parallelizable.
2. **Backup discard policy** — keep last 5 versions OR keep based on age (last 30 days)? Lean **count-based** (last 5) — predictable disk footprint.
3. **Confirmation phrase** — `migrate now` (typed) OR `--yes-i-know` (flag, mirroring existing `--yes-i-know-plaintext`)? Lean **typed phrase** — destructive op deserves a small friction.
4. **Concurrent-migration safety** — what if user runs `browser-migrate run` in two terminals? Add a lock file at `~/.browser-skill/.migrate.lock` mode 0600; refuse second run.
5. **Migrating across major version gaps** — v1 → v3 directly OR v1 → v2 → v3 chained? **Chained** — each migrator handles only its predecessor → its target; chain is dispatched serially.

## 12. Sequencing (locked)

```
Phase 7 ✅ — capture pipeline
        ↓
Phase 8 ✅ — obscura adapter
        ↓
Phase 9 ✅ — flow runner
        ↓
Phase 11 ✅ — memory (parts 1+2 v1)
        ↓
Phase 10 (this design doc) — schema migration tooling
   ├── 10-1-i: lib/migrate.sh foundation
   ├── 10-1-ii: browser-migrate verb
   └── 10-1-iii: first real migrator (no-op v1_to_v2 for memory)
        ↓
Future: per-schema migrators ship case-by-case as schema bumps land
```

## 13. References

Internal cross-references:
- Parent spec: `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §2.2 (filesystem contract), §13 (maintainability)
- Phase 11 design: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` (memory schemas as first migration candidates)
- Existing schemas with `schema_version: 1`:
  - `scripts/lib/site.sh` (sites profile + meta)
  - `scripts/lib/capture.sh` (`meta.json`, `_index.json`)
  - `scripts/browser-baseline.sh` (`baselines.json`)
  - `scripts/lib/memory.sh` (`patterns.json`, `archetypes/<id>.json`)
  - `install.sh` (`config.json`)

External (none — purely internal infrastructure):
- No third-party migration framework adopted; bash + jq is sufficient + dependency-light.
