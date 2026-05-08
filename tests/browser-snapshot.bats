load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-snapshot: passes 'snapshot' through to picked adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  grep -q '^snapshot$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-snapshot: emits summary with verb=snapshot, tool=playwright-cli, status=ok" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "snapshot" and .tool == "playwright-cli" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-snapshot: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --tool ghost-tool
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-snapshot: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "ok" and .dry_run == true' >/dev/null
}

# ---------- Phase 7 part 1-i: --capture wire-up ----------

@test "browser-snapshot --capture: writes captures/001/snapshot.json + meta.json + summary has capture_id" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/001/snapshot.json" ] || fail "snapshot.json not written"
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ]     || fail "meta.json not written"
  jq -e '.status == "ok"'                  "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  jq -e '.verb == "snapshot"'              "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.capture_id == "001"' >/dev/null
}

@test "browser-snapshot --capture: dir mode 0700, meta.json mode 0600" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  dir_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null)"
  meta_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001/meta.json" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001/meta.json" 2>/dev/null)"
  [ "${dir_perms}" = "700" ]  || fail "expected dir mode 700, got ${dir_perms}"
  [ "${meta_perms}" = "600" ] || fail "expected meta mode 600, got ${meta_perms}"
}

@test "browser-snapshot --capture: _index.json updated after capture" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/_index.json" ] || fail "_index.json not written"
  jq -e '.latest == "001"'  "${BROWSER_SKILL_HOME}/captures/_index.json" >/dev/null
  jq -e '.count == 1'       "${BROWSER_SKILL_HOME}/captures/_index.json" >/dev/null
}

@test "browser-snapshot (no --capture): captures dir not created (clean state)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] || fail "captures dir created without --capture flag"
}

@test "browser-snapshot --capture: adapter failure → meta.json status=error (still finalized)" {
  # Force failure by pointing at a non-existent stub binary.
  PLAYWRIGHT_CLI_BIN="/nonexistent/playwright-cli-binary" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when adapter fails"
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ] || fail "meta.json not finalized after error"
  jq -e '.status == "error"' "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
}
