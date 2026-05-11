# lib/migrators/recent_urls/

Schema migrator directory for the `recent_urls.jsonl` observation log
(Phase 11 v2 Pick A6, PR introducing schema_version:1).

**Currently empty.** The log ships at `schema_version:1` from inception; no
migrator is needed until the line shape changes. Future shape bumps land
a `v1_to_v2.sh` here following the precedent in `lib/migrators/memory/v1_to_v2.sh`
(PR #111).

The directory exists so the migrate-registry mechanism (`lib/migrate.sh`)
walks the `recent_urls` schema namespace alongside other schemas — even with
no migrators registered, the schema's `versions.json` slot is tracked.
