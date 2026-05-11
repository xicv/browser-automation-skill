load helpers

# Phase 10 part 1-iii — first real migrator: no-op v1_to_v2 for memory.
# Validates registry+dispatch end-to-end against production code (not fixtures).

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # shellcheck disable=SC1091
  source "${LIB_DIR}/memory.sh"
}
teardown() { teardown_temp_home; }

# Helper: seed a memory archetype + pattern via lib API.
_seed_memory_archetype() {
  memory_init_dir
  memory_save_archetype prod-app devices-detail "$(jq -nc \
    '{schema_version:1, archetype_id:"devices-detail", url_pattern:"/devices/:id",
      first_seen:"2026-05-11T00:00:00Z", last_seen:"2026-05-11T00:00:00Z",
      use_count:0, interactions:[]}')"
  memory_record_pattern prod-app '/devices/:id' devices-detail
}

@test "migrators-memory: registry auto-loads memory v1_to_v2 + check reports migration_needed" {
  _seed_memory_archetype
  # Initialize migrate state with memory schema at v1.
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" check
  assert_status 0
  found="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(._kind=="migration_needed" and .schema=="memory")) | length')"
  [ "${found}" = "1" ] || fail "expected migration_needed for memory schema; got events: ${output}"
  shape="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(._kind=="migration_needed" and .schema=="memory"))[0]')"
  printf '%s' "${shape}" | jq -e '.from == 1 and .to == 2' >/dev/null \
    || fail "expected from:1 to:2; got ${shape}"
}

@test "migrators-memory: browser-migrate run --yes --schema memory bumps versions.json + archetype + creates backup" {
  _seed_memory_archetype
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes --schema memory
  assert_status 0

  # versions.json bumped.
  jq -e '.schema_versions.memory == 2' "${BROWSER_SKILL_HOME}/versions.json" >/dev/null \
    || fail "expected memory bumped to v2; got $(jq -c '.schema_versions' "${BROWSER_SKILL_HOME}/versions.json")"

  # Archetype JSON's schema_version bumped.
  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.schema_version == 2' "${arch_path}" >/dev/null \
    || fail "expected archetype.schema_version == 2; got $(jq -c . "${arch_path}")"

  # Backup created.
  bk_path="${BROWSER_SKILL_HOME}/backups/memory/devices-detail.json.bak.v1"
  [ -f "${bk_path}" ] || fail "backup not created at ${bk_path}"
  bm="$(file_mode "${bk_path}")"
  [ "${bm}" = "600" ] || fail "expected backup mode 600; got ${bm}"
}

@test "migrators-memory: patterns.json AND archetype JSON both migrated" {
  _seed_memory_archetype
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null
  bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes --schema memory >/dev/null

  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.schema_version == 2' "${patterns_path}" >/dev/null \
    || fail "patterns.json schema_version not bumped; got $(jq -c . "${patterns_path}")"
  jq -e '.schema_version == 2' "${arch_path}" >/dev/null \
    || fail "archetype.schema_version not bumped"
}
