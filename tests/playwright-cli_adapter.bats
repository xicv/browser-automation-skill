load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "playwright-cli adapter: file exists and is readable" {
  [ -f "${LIB_TOOL_DIR}/playwright-cli.sh" ] || fail "adapter file missing"
  [ -r "${LIB_TOOL_DIR}/playwright-cli.sh" ] || fail "adapter not readable"
}

@test "playwright-cli adapter: tool_metadata returns valid JSON" {
  run adapter_run_query playwright-cli tool_metadata
  assert_status 0
  printf '%s' "${output}" | jq -e . >/dev/null
}

@test "playwright-cli adapter: tool_metadata.name == 'playwright-cli' (matches filename)" {
  result="$(adapter_run_query playwright-cli tool_metadata)"
  [ "$(printf '%s' "${result}" | jq -r .name)" = "playwright-cli" ]
}

@test "playwright-cli adapter: tool_metadata.abi_version == BROWSER_SKILL_TOOL_ABI" {
  result="$(adapter_run_query playwright-cli tool_metadata)"
  expected="$(bash -c "source '${LIB_DIR}/common.sh'; printf '%s' \"\${BROWSER_SKILL_TOOL_ABI}\"")"
  [ "$(printf '%s' "${result}" | jq -r .abi_version)" = "${expected}" ]
}

@test "playwright-cli adapter: tool_metadata has version_pin and cheatsheet_path" {
  result="$(adapter_run_query playwright-cli tool_metadata)"
  printf '%s' "${result}" | jq -e '.version_pin and .cheatsheet_path' >/dev/null
}

@test "playwright-cli adapter: tool_capabilities returns valid JSON with .verbs" {
  result="$(adapter_run_query playwright-cli tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs' >/dev/null
}

@test "playwright-cli adapter: tool_capabilities.verbs.open exists (declares default-navigation support)" {
  result="$(adapter_run_query playwright-cli tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.open' >/dev/null
}

@test "playwright-cli adapter: tool_doctor_check returns valid JSON with .ok boolean" {
  result="$(adapter_run_query playwright-cli tool_doctor_check)"
  printf '%s' "${result}" | jq -e '.ok | type == "boolean"' >/dev/null
}

@test "playwright-cli adapter: all 8 verb-dispatch functions are defined" {
  for fn in tool_open tool_click tool_fill tool_snapshot tool_inspect tool_audit tool_extract tool_eval; do
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh' >/dev/null 2>&1; type ${fn} >/dev/null 2>&1"
    [ "${status}" = "0" ] || fail "function ${fn} is not defined"
  done
}

@test "playwright-cli adapter: tool_open shells to PLAYWRIGHT_CLI_BIN with verb='open'" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_open --url https://example.com"
  assert_status 0
  grep -q '^open$' "${STUB_LOG_FILE}"
  grep -q '^--url$' "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "playwright-cli adapter: tool_open echoes the canned fixture JSON" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_open --url https://example.com"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "navigate"' >/dev/null
  printf '%s' "${output}" | jq -e '.url == "https://example.com"' >/dev/null
}

@test "playwright-cli adapter: tool_snapshot returns refs array" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_snapshot"
  assert_status 0
  printf '%s' "${output}" | jq -e '.refs | length == 2' >/dev/null
}

@test "playwright-cli adapter: tool_click logs argv with --ref" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_click --ref e3"
  assert_status 0
  grep -q '^click$' "${STUB_LOG_FILE}"
  grep -q '^--ref$' "${STUB_LOG_FILE}"
  grep -q '^e3$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "playwright-cli adapter: tool_audit returns 41 (TOOL_UNSUPPORTED_OP)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_audit"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
}

@test "playwright-cli adapter: tool_extract returns 41 (TOOL_UNSUPPORTED_OP)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-cli.sh'; tool_extract"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
}

@test "playwright-cli adapter: secret never appears in argv (uses --secret-stdin)" {
  result="$(adapter_run_query playwright-cli tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.fill.flags | index("--secret-stdin")' >/dev/null \
    || fail "tool_capabilities.verbs.fill must declare --secret-stdin support"
}
