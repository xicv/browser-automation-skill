load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-open: --url passes through to picked adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  grep -q '^open$' "${STUB_LOG_FILE}"
  grep -q '^--url$' "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-open: emits a single-line JSON summary as the last line of stdout" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "open" and .tool == "playwright-cli" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-open: --tool override propagates as ARG_TOOL into router" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --tool playwright-cli --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.why == "user-specified"' >/dev/null
}

@test "browser-open: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --tool ghost-tool --url https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-open: missing --url fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--url"
}

@test "browser-open: --dry-run prints planned action and writes nothing" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --dry-run --url https://example.com
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "ok" and .dry_run == true' >/dev/null
}
