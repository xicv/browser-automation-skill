load helpers

# Phase 10 part 1-i — lib/migrate.sh foundation.
# Pure lib tests; no verb integration. Test-only fixture migrators registered
# via BROWSER_SKILL_MIGRATORS_DIR env override (mirrors BROWSER_DO_DISPATCH_OVERRIDE
# pattern from 11-1-iii self-heal).

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # shellcheck disable=SC1091
  source "${LIB_DIR}/migrate.sh"
}
teardown() { teardown_temp_home; }

# Helper: write an identity v1→v2 fixture migrator that adds a `priority` field.
_seed_identity_migrator() {
  local schema="$1"
  local migrators_dir="${BATS_TEST_TMPDIR}/migrators-${BATS_TEST_NUMBER}"
  mkdir -p "${migrators_dir}/${schema}"
  cat > "${migrators_dir}/${schema}/v1_to_v2.sh" <<'EOF'
# shellcheck disable=SC2034
migrate_test_v1_to_v2() {
  local file_path="$1"
  jq '. + {priority: 0}' "${file_path}" > "${file_path}.tmp"
  mv "${file_path}.tmp" "${file_path}"
}
EOF
  printf '%s' "${migrators_dir}"
}

# Helper: write a fixture target file (the thing we'll migrate).
_seed_target_file() {
  local schema="$1" basename="$2" content="$3"
  local schema_dir="${BROWSER_SKILL_HOME}/${schema}"
  mkdir -p "${schema_dir}"
  printf '%s' "${content}" > "${schema_dir}/${basename}"
  chmod 600 "${schema_dir}/${basename}"
  printf '%s' "${schema_dir}/${basename}"
}

# --- migrate_init ---

@test "migrate_init: creates versions.json mode 0600 + backups/ mode 0700; idempotent" {
  migrate_init
  [ -f "${BROWSER_SKILL_HOME}/versions.json" ] || fail "versions.json not created"
  vm="$(file_mode "${BROWSER_SKILL_HOME}/versions.json")"
  [ "${vm}" = "600" ] || fail "expected versions.json mode 600; got ${vm}"
  [ -d "${BROWSER_SKILL_HOME}/backups" ] || fail "backups/ not created"
  bm="$(file_mode "${BROWSER_SKILL_HOME}/backups")"
  [ "${bm}" = "700" ] || fail "expected backups/ mode 700; got ${bm}"
  jq -e '.schema_version == 1 and (.schema_versions | type == "object")' \
    "${BROWSER_SKILL_HOME}/versions.json" >/dev/null || fail "versions.json shape wrong"

  # Idempotent: second call doesn't fail or wipe.
  migrate_init
  bm2="$(file_mode "${BROWSER_SKILL_HOME}/backups")"
  [ "${bm2}" = "700" ] || fail "mode changed on idempotent re-call: ${bm2}"
}

@test "migrate_init: legacy 'version' file (containing '1') seeds versions.json with all known schemas at v1" {
  printf '1\n' > "${BROWSER_SKILL_HOME}/version"
  migrate_init
  jq -e '
    .schema_versions.sites == 1 and
    .schema_versions.sessions == 1 and
    .schema_versions.credentials == 1 and
    .schema_versions.captures == 1 and
    .schema_versions.baselines == 1 and
    .schema_versions.memory == 1 and
    .schema_versions.config == 1
  ' "${BROWSER_SKILL_HOME}/versions.json" >/dev/null \
    || fail "expected all 7 known schemas seeded at v1; got $(jq -c '.schema_versions' "${BROWSER_SKILL_HOME}/versions.json")"
}

# --- migrate_get_version + migrate_set_version ---

@test "migrate_get_version: returns 1 for unknown schema (default)" {
  migrate_init
  v="$(migrate_get_version unknown-schema)"
  [ "${v}" = "1" ] || fail "expected default 1; got '${v}'"
}

@test "migrate_set_version + migrate_get_version: round-trip" {
  migrate_init
  migrate_set_version test-schema 5
  v="$(migrate_get_version test-schema)"
  [ "${v}" = "5" ] || fail "expected 5; got '${v}'"
}

# --- migrate_check ---

@test "migrate_check: empty registry → no schemas needing migration; exit 0; pending:0" {
  migrate_init
  run migrate_check
  assert_status 0
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb == "migrate" and .pending == 0' >/dev/null \
    || fail "expected pending:0 summary; got ${last}"
}

@test "migrate_check: identity v1→v2 migrator registered for test schema → reports needs-migration" {
  migrate_init
  migrators_dir="$(_seed_identity_migrator test)"
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/migrate.sh'; migrate_check"
  assert_status 0
  found="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(._kind=="migration_needed")) | length')"
  [ "${found}" = "1" ] || fail "expected 1 migration_needed event; got ${found}"
}

# --- migrate_run ---

@test "migrate_run: empty registry → no-op; exit 0; migrated:0" {
  migrate_init
  run migrate_run
  assert_status 0
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb == "migrate" and .migrated == 0' >/dev/null \
    || fail "expected migrated:0 summary; got ${last}"
}

@test "migrate_run: identity v1→v2 migrator → schema bumped + backup created mode 0600" {
  migrate_init
  migrators_dir="$(_seed_identity_migrator test)"
  target_file="$(_seed_target_file test thing.json '{"schema_version":1,"name":"x"}')"
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/migrate.sh'; migrate_run test" >/dev/null

  # Schema version bumped to 2.
  v="$(migrate_get_version test)"
  [ "${v}" = "2" ] || fail "expected schema bumped to 2; got '${v}'"

  # Migrator applied (priority field added).
  jq -e '.priority == 0 and .name == "x"' "${target_file}" >/dev/null \
    || fail "migrator did not apply; got $(cat "${target_file}")"

  # Backup created at backups/test/thing.json.bak.v1; mode 0600.
  bk="${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v1"
  [ -f "${bk}" ] || fail "backup not created at ${bk}"
  bm="$(file_mode "${bk}")"
  [ "${bm}" = "600" ] || fail "expected backup mode 600; got ${bm}"
}

@test "migrate_run: validation failure (migrator emits invalid JSON) refuses atomic-swap; version unchanged" {
  migrate_init
  # Write a bad migrator that emits non-JSON.
  migrators_dir="${BATS_TEST_TMPDIR}/migrators-bad-${BATS_TEST_NUMBER}"
  mkdir -p "${migrators_dir}/test"
  cat > "${migrators_dir}/test/v1_to_v2.sh" <<'EOF'
migrate_test_v1_to_v2() {
  local file_path="$1"
  printf 'not valid json' > "${file_path}.tmp"
  mv "${file_path}.tmp" "${file_path}"
}
EOF
  target_file="$(_seed_target_file test thing.json '{"schema_version":1,"name":"x"}')"
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/migrate.sh'; migrate_run test" >/dev/null 2>&1 || true

  # Version should NOT have bumped (validation failed; refused to atomic-swap).
  v="$(migrate_get_version test)"
  [ "${v}" = "1" ] || fail "expected version unchanged after invalid migration; got '${v}'"
}

# --- migrate_rollback ---

@test "migrate_rollback: restores latest backup; version bumped back" {
  migrate_init
  migrators_dir="$(_seed_identity_migrator test)"
  target_file="$(_seed_target_file test thing.json '{"schema_version":1,"name":"original"}')"
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/migrate.sh'; migrate_run test" >/dev/null

  # Sanity: bumped to 2; priority added.
  jq -e '.priority == 0' "${target_file}" >/dev/null

  migrate_rollback test
  v="$(migrate_get_version test)"
  [ "${v}" = "1" ] || fail "expected version 1 after rollback; got '${v}'"
  jq -e '.priority == null and .name == "original"' "${target_file}" >/dev/null \
    || fail "rollback didn't restore original content; got $(cat "${target_file}")"
}

# --- migrate_clean_backups ---

@test "migrate_clean_backups: keep newest N; older discarded" {
  migrate_init
  mkdir -p "${BROWSER_SKILL_HOME}/backups/test"
  # Seed 4 versioned backups.
  for v in 1 2 3 4; do
    printf '{"v":%d}' "${v}" > "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}"
    chmod 600 "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}"
  done

  migrate_clean_backups 2

  for v in 3 4; do
    [ -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}" ] \
      || fail "expected newest backup v${v} to survive"
  done
  for v in 1 2; do
    [ ! -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}" ] \
      || fail "expected old backup v${v} to be discarded"
  done
}

# --- migrate_status ---

@test "migrate_status: echoes JSON of all schema versions" {
  migrate_init
  out="$(migrate_status)"
  printf '%s' "${out}" | jq -e '
    .schema_versions.sites == 1 and
    .schema_versions.memory == 1 and
    (.schema_versions | length >= 7)
  ' >/dev/null || fail "expected 7+ schemas in status; got ${out}"
}
