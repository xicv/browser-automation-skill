load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-fill: --text hello passes through to adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  grep -q '^fill$'   "${STUB_LOG_FILE}"
  grep -q '^--ref$'  "${STUB_LOG_FILE}"
  grep -q '^e3$'     "${STUB_LOG_FILE}"
  grep -q '^--text$' "${STUB_LOG_FILE}"
  grep -q '^hello$'  "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-fill: emits summary with verb=fill, ref=e3, status=ok (text path)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "fill" and .ref == "e3" and .status == "ok"' >/dev/null
}

@test "browser-fill: --secret-stdin reads secret from stdin (argv has --secret-stdin flag, NO secret)" {
  STUB_LOG_FILE="$(mktemp)"
  local secret="hunter2-NEVER-IN-ARGV"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "printf '%s' '${secret}' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --secret-stdin"
  assert_status 0
  grep -q '^fill$'           "${STUB_LOG_FILE}"
  grep -q '^--secret-stdin$' "${STUB_LOG_FILE}"
  # CRITICAL: the secret string must NEVER appear in argv (anti-pattern AP-7).
  if grep -q "${secret}" "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"
    fail "secret leaked into argv log: ${STUB_LOG_FILE}"
  fi
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-fill: missing --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --text hello
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "ref"
}

@test "browser-fill: neither --text nor --secret-stdin fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "text"
}

@test "browser-fill: both --text and --secret-stdin supplied fails EXIT_USAGE_ERROR" {
  run bash -c "printf 'x' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --text hello --secret-stdin"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}
