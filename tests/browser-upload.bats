load helpers

# Phase 6 part 6: browser-upload verb.
# Stateful — requires daemon (refMap precondition).
# Path security: file-exists + regular-file + readable + sensitive-pattern reject.

setup() {
  setup_temp_home
  init_paths
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # Test fixture: a normal uploadable file.
  TEST_FILE="${TEST_HOME}/normal.txt"
  printf 'hello world\n' > "${TEST_FILE}"
  chmod 644 "${TEST_FILE}"
}
teardown() { teardown_temp_home; }

@test "browser-upload: missing --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --path "${TEST_FILE}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --ref"
}

@test "browser-upload: missing --path fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --path"
}

@test "browser-upload: nonexistent path fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3 --path "${TEST_HOME}/nonexistent.bin"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not exist"
}

@test "browser-upload: directory instead of file fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3 --path "${TEST_HOME}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "not a regular file"
}

@test "browser-upload: unreadable file fails EXIT_USAGE_ERROR" {
  unreadable="${TEST_HOME}/unreadable.bin"
  printf 'secret\n' > "${unreadable}"
  chmod 000 "${unreadable}"
  # Some test harnesses run as root which can read mode-000 files; skip if so.
  if [ -r "${unreadable}" ]; then
    skip "test environment can read mode-000 files (likely running as root)"
  fi
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3 --path "${unreadable}"
  chmod 600 "${unreadable}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "not readable"
}

@test "browser-upload: SSH-key path rejected without --allow-sensitive" {
  ssh_path="${TEST_HOME}/.ssh/id_rsa"
  mkdir -p "$(dirname "${ssh_path}")"
  printf 'fake-key\n' > "${ssh_path}"
  chmod 600 "${ssh_path}"
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3 --path "${ssh_path}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "sensitive pattern"
}

@test "browser-upload: .env path rejected without --allow-sensitive" {
  env_path="${TEST_HOME}/.env"
  printf 'API_KEY=fake\n' > "${env_path}"
  chmod 600 "${env_path}"
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --ref e3 --path "${env_path}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "sensitive pattern"
}

@test "browser-upload: --allow-sensitive bypasses sensitive-pattern reject (dry-run)" {
  ssh_path="${TEST_HOME}/.ssh/id_rsa_sensitive"
  mkdir -p "$(dirname "${ssh_path}")"
  printf 'fake-key\n' > "${ssh_path}"
  chmod 600 "${ssh_path}"
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --dry-run --ref e3 --path "${ssh_path}" --allow-sensitive
  assert_status 0
  assert_output_contains "dry-run"
}

@test "browser-upload: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --tool ghost-tool --ref e3 --path "${TEST_FILE}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-upload: --tool=playwright-cli fails (capability filter rejects upload)" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --tool playwright-cli --ref e3 --path "${TEST_FILE}"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-upload: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-upload.sh" --dry-run --ref e3 --path "${TEST_FILE}"
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "upload" and .ref == "e3" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 6): pick_tool upload routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool upload --ref e1 --path /tmp/x
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "upload default"
}
