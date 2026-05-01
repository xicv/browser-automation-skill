load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-fill: --ref e3 --text hello translates to positional target+text at adapter boundary" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  grep -q '^fill$'   "${STUB_LOG_FILE}"
  grep -q '^e3$'     "${STUB_LOG_FILE}"
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

@test "browser-fill: --secret-stdin returns 41 (playwright-cli has no stdin-secret mode; routed to playwright-lib in Phase 4)" {
  # The adapter rejects --secret-stdin BEFORE invoking the binary — this is the
  # correct behavior because playwright-cli only takes the secret as a positional
  # arg (which would leak it via argv, AP-7). Phase 4's playwright-lib adapter
  # reads stdin natively in Node, where it never reaches argv.
  STUB_LOG_FILE="$(mktemp)"
  local secret="hunter2-NEVER-IN-ARGV"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "printf '%s' '${secret}' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --secret-stdin"
  [ "${status}" = "41" ] || fail "expected EXIT_TOOL_UNSUPPORTED_OP (41), got ${status}"
  # Argv-leak guard: even though adapter rejects, verify the secret never reached
  # the (would-be) binary. The stub log must be empty (binary never invoked) OR
  # if invoked must not contain the secret.
  if [ -s "${STUB_LOG_FILE}" ] && grep -q "${secret}" "${STUB_LOG_FILE}"; then
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
