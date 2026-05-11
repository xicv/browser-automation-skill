load helpers

# Phase 10 part 1-ii — browser-migrate verb.
# Sub-mode dispatch over migrate_* APIs from 10-1-i lib/migrate.sh.
# Tests use BROWSER_SKILL_MIGRATORS_DIR to inject fixture migrators.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# Helper: write an identity v1→v2 fixture migrator that adds a `priority` field.
_seed_identity_migrator() {
  local schema="$1"
  local migrators_dir="${BATS_TEST_TMPDIR}/migrators-${BATS_TEST_NUMBER}"
  mkdir -p "${migrators_dir}/${schema}"
  cat > "${migrators_dir}/${schema}/v1_to_v2.sh" <<'EOF'
migrate_test_v1_to_v2() {
  local file_path="$1"
  jq '. + {priority: 0}' "${file_path}" > "${file_path}.tmp"
  mv "${file_path}.tmp" "${file_path}"
}
EOF
  printf '%s' "${migrators_dir}"
}

# Helper: write a fixture target file under the schema's state dir.
_seed_target_file() {
  local schema="$1" basename="$2" content="$3"
  local schema_dir="${BROWSER_SKILL_HOME}/${schema}"
  mkdir -p "${schema_dir}"
  printf '%s' "${content}" > "${schema_dir}/${basename}"
  chmod 600 "${schema_dir}/${basename}"
}

# --- check ---

@test "browser-migrate check: empty registry → pending:0; exit 0" {
  # Override migrators dir to empty so the production memory v1_to_v2 (10-1-iii)
  # doesn't fire — preserves the original "empty registry" semantic.
  empty_dir="${BATS_TEST_TMPDIR}/empty-migrators"
  mkdir -p "${empty_dir}"
  BROWSER_SKILL_MIGRATORS_DIR="${empty_dir}" \
    run bash "${SCRIPTS_DIR}/browser-migrate.sh" check
  assert_status 0
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb == "migrate" and .mode == "check" and .pending == 0' >/dev/null \
    || fail "expected pending:0 summary; got ${last}"
}

# --- status ---

@test "browser-migrate status: echoes versions.json (after init)" {
  run bash "${SCRIPTS_DIR}/browser-migrate.sh" status
  assert_status 0
  printf '%s' "${output}" | jq -e '.schema_version == 1 and (.schema_versions | length >= 7)' >/dev/null \
    || fail "expected versions.json shape; got ${output}"
}

# --- run (--yes) ---

@test "browser-migrate run --yes: empty registry → no-op + exit 0 + migrated:0" {
  # Empty migrators dir override (same reason as the check test above).
  empty_dir="${BATS_TEST_TMPDIR}/empty-migrators"
  mkdir -p "${empty_dir}"
  BROWSER_SKILL_MIGRATORS_DIR="${empty_dir}" \
    run bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes
  assert_status 0
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb == "migrate" and .mode == "run" and .migrated == 0' >/dev/null \
    || fail "expected migrated:0 summary; got ${last}"
}

@test "browser-migrate run: no --yes and no TTY → EXIT_TTY_REQUIRED (27)" {
  # bats run hides the TTY by default. Without --yes, verb refuses.
  run bash "${SCRIPTS_DIR}/browser-migrate.sh" run
  assert_status "$EXIT_TTY_REQUIRED"
  assert_output_contains "TTY"
}

@test "browser-migrate run --yes --schema test: identity migrator → version bumped + backup" {
  migrators_dir="$(_seed_identity_migrator test)"
  _seed_target_file test thing.json '{"schema_version":1,"name":"x"}'
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    run bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes --schema test
  assert_status 0
  # Schema version bumped.
  jq -e '.schema_versions.test == 2' "${BROWSER_SKILL_HOME}/versions.json" >/dev/null \
    || fail "expected test schema bumped to v2; got $(jq -c '.schema_versions' "${BROWSER_SKILL_HOME}/versions.json")"
  # Target file migrated.
  jq -e '.priority == 0' "${BROWSER_SKILL_HOME}/test/thing.json" >/dev/null
  # Backup created.
  [ -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v1" ] || fail "backup not created"
}

# --- rollback ---

@test "browser-migrate rollback --schema test --yes: restores from backup" {
  migrators_dir="$(_seed_identity_migrator test)"
  _seed_target_file test thing.json '{"schema_version":1,"name":"original"}'
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes --schema test >/dev/null

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" rollback --schema test --yes
  assert_status 0
  jq -e '.schema_versions.test == 1' "${BROWSER_SKILL_HOME}/versions.json" >/dev/null
  jq -e '.priority == null and .name == "original"' "${BROWSER_SKILL_HOME}/test/thing.json" >/dev/null \
    || fail "rollback didn't restore content"
}

@test "browser-migrate rollback: missing --schema → EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-migrate.sh" rollback --yes
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "schema"
}

# --- clean-backups ---

@test "browser-migrate clean-backups --keep 1 --yes: keeps newest; older discarded" {
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null    # init versions.json + backups/
  mkdir -p "${BROWSER_SKILL_HOME}/backups/test"
  for v in 1 2 3; do
    printf '{"v":%d}' "${v}" > "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}"
    chmod 600 "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v${v}"
  done

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" clean-backups --keep 1 --yes
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v3" ] || fail "expected newest (v3) preserved"
  [ ! -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v1" ] || fail "v1 should be discarded"
  [ ! -f "${BROWSER_SKILL_HOME}/backups/test/thing.json.bak.v2" ] || fail "v2 should be discarded"
}

# --- lock ---

@test "browser-migrate run --yes: refuses when lock held by alive PID" {
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null    # init dirs
  # Write a lock pointing at THIS shell's PID (definitely alive).
  printf '{"pid":%d,"acquired_at":"2026-05-11T00:00:00Z"}' "$$" \
    > "${BROWSER_SKILL_HOME}/.migrate.lock"
  chmod 600 "${BROWSER_SKILL_HOME}/.migrate.lock"

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "in progress"
  # Lock should remain (we didn't own it).
  [ -f "${BROWSER_SKILL_HOME}/.migrate.lock" ] || fail "lock should not be cleared on refusal"
}

@test "browser-migrate run --yes: clears stale lock (PID dead) + proceeds" {
  bash "${SCRIPTS_DIR}/browser-migrate.sh" status >/dev/null
  # PID 999999 is unlikely to be alive on any normal system.
  printf '{"pid":999999,"acquired_at":"2026-05-11T00:00:00Z"}' \
    > "${BROWSER_SKILL_HOME}/.migrate.lock"
  chmod 600 "${BROWSER_SKILL_HOME}/.migrate.lock"

  run bash "${SCRIPTS_DIR}/browser-migrate.sh" run --yes
  assert_status 0
  assert_output_contains "stale lock"
  # Lock cleared after run completes.
  [ ! -f "${BROWSER_SKILL_HOME}/.migrate.lock" ] || fail "lock not cleaned up after run"
}

# --- usage errors ---

@test "browser-migrate: unknown sub-mode → EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-migrate.sh" ghost-mode
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "sub-mode"
}

@test "browser-migrate: missing sub-mode → EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-migrate.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "sub-mode"
}
