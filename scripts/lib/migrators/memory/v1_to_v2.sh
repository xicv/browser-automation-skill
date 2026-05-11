# scripts/lib/migrators/memory/v1_to_v2.sh
# Phase 10 part 1-iii: first real migrator. No-op identity for memory schema.
# Validates the registry + dispatch end-to-end without risking data corruption.
#
# Migrates every JSON file under ${BROWSER_SKILL_HOME}/memory/ (both
# patterns.json + archetype JSONs). The change is purely the schema_version
# bump from 1 to 2; data shape is unchanged.
#
# Future migrators (v2_to_v3 and beyond) ship per actual schema-shape changes.

migrate_memory_v1_to_v2() {
  local file_path="$1"
  jq '.schema_version = 2' "${file_path}" > "${file_path}.tmp"
  mv "${file_path}.tmp" "${file_path}"
}
