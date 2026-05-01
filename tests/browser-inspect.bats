load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-inspect: --selector h1 passes through to adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --selector h1
  assert_status 0
  grep -q '^inspect$'    "${STUB_LOG_FILE}"
  grep -q '^--selector$' "${STUB_LOG_FILE}"
  grep -q '^h1$'         "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-inspect: emits summary with verb=inspect, selector=h1, status=ok" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --selector h1
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "inspect" and .selector == "h1" and .status == "ok"' >/dev/null
}

@test "browser-inspect: missing --selector fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-inspect.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "selector"
}

@test "browser-inspect: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-inspect.sh" --tool ghost-tool --selector h1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}
