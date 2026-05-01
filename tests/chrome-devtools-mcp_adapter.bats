load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

# --- Contract conformance ---

@test "chrome-devtools-mcp adapter: file exists and is readable" {
  [ -f "${LIB_TOOL_DIR}/chrome-devtools-mcp.sh" ] || fail "adapter file missing"
  [ -r "${LIB_TOOL_DIR}/chrome-devtools-mcp.sh" ] || fail "adapter not readable"
}

@test "chrome-devtools-mcp adapter: tool_metadata returns valid JSON" {
  run adapter_run_query chrome-devtools-mcp tool_metadata
  assert_status 0
  printf '%s' "${output}" | jq -e . >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_metadata.name == 'chrome-devtools-mcp' (matches filename)" {
  result="$(adapter_run_query chrome-devtools-mcp tool_metadata)"
  [ "$(printf '%s' "${result}" | jq -r .name)" = "chrome-devtools-mcp" ]
}

@test "chrome-devtools-mcp adapter: tool_metadata.abi_version == BROWSER_SKILL_TOOL_ABI" {
  result="$(adapter_run_query chrome-devtools-mcp tool_metadata)"
  expected="$(bash -c "source '${LIB_DIR}/common.sh'; printf '%s' \"\${BROWSER_SKILL_TOOL_ABI}\"")"
  [ "$(printf '%s' "${result}" | jq -r .abi_version)" = "${expected}" ]
}

@test "chrome-devtools-mcp adapter: tool_metadata has version_pin and cheatsheet_path" {
  result="$(adapter_run_query chrome-devtools-mcp tool_metadata)"
  printf '%s' "${result}" | jq -e '.version_pin and .cheatsheet_path' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_capabilities returns valid JSON with .verbs" {
  result="$(adapter_run_query chrome-devtools-mcp tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs' >/dev/null
}

# --- Capability surface — declares the differentiator verbs (Appendix B) ---

@test "chrome-devtools-mcp adapter: tool_capabilities.verbs.inspect exists (flagship verb per Appendix B)" {
  result="$(adapter_run_query chrome-devtools-mcp tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.inspect' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_capabilities.verbs.audit exists" {
  result="$(adapter_run_query chrome-devtools-mcp tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.audit' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_capabilities.verbs.extract exists" {
  result="$(adapter_run_query chrome-devtools-mcp tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.extract' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_capabilities.verbs.fill declares --secret-stdin (cdt-mcp accepts stdin)" {
  result="$(adapter_run_query chrome-devtools-mcp tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.fill.flags | index("--secret-stdin")' >/dev/null
}

# --- Doctor + ABI ---

@test "chrome-devtools-mcp adapter: tool_doctor_check returns valid JSON with .ok boolean" {
  result="$(adapter_run_query chrome-devtools-mcp tool_doctor_check)"
  printf '%s' "${result}" | jq -e '.ok | type == "boolean"' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_doctor_check is ok=true when stub bin is on PATH" {
  result="$(CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" adapter_run_query chrome-devtools-mcp tool_doctor_check)"
  printf '%s' "${result}" | jq -e '.ok == true' >/dev/null
}

@test "chrome-devtools-mcp adapter: all 8 verb-dispatch functions are defined" {
  for fn in tool_open tool_click tool_fill tool_snapshot tool_inspect tool_audit tool_extract tool_eval; do
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh' >/dev/null 2>&1; type ${fn} >/dev/null 2>&1"
    [ "${status}" = "0" ] || fail "function ${fn} is not defined"
  done
}

# --- Verb dispatch via stub binary (happy paths) ---

@test "chrome-devtools-mcp adapter: tool_open --url shells to bin with translated argv (no --url leak)" {
  STUB_LOG_FILE="$(mktemp)"
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_open --url https://example.com"
  assert_status 0
  grep -q '^open$' "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  if grep -q '^--url$' "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"
    fail "adapter must translate --url to positional; --url leaked to bin argv"
  fi
  rm -f "${STUB_LOG_FILE}"
}

@test "chrome-devtools-mcp adapter: tool_open echoes the canned navigate fixture" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_open --url https://example.com"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "navigate"' >/dev/null
  printf '%s' "${output}" | jq -e '.url == "https://example.com"' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_snapshot returns refs array (length 2)" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_snapshot"
  assert_status 0
  printf '%s' "${output}" | jq -e '.refs | length == 2' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_click translates --ref to positional target" {
  STUB_LOG_FILE="$(mktemp)"
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_click --ref e3"
  assert_status 0
  grep -q '^click$' "${STUB_LOG_FILE}"
  grep -q '^e3$'    "${STUB_LOG_FILE}"
  if grep -q '^--ref$' "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"
    fail "adapter must translate --ref to positional"
  fi
  rm -f "${STUB_LOG_FILE}"
}

@test "chrome-devtools-mcp adapter: tool_inspect --capture-console echoes inspect fixture (flagship verb)" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_inspect --capture-console"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "inspect"' >/dev/null
  printf '%s' "${output}" | jq -e '.console_messages == 2' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_audit --lighthouse echoes audit fixture" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_audit --lighthouse"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "audit"' >/dev/null
  printf '%s' "${output}" | jq -e '.lighthouse_score == 0.92' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_extract --selector echoes extract fixture" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_extract --selector .title"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "extract"' >/dev/null
  printf '%s' "${output}" | jq -e '.matches | length == 2' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_eval --expression translates to positional" {
  STUB_LOG_FILE="$(mktemp)"
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_eval --expression '1+1'"
  assert_status 0
  grep -q '^eval$' "${STUB_LOG_FILE}"
  grep -q '^1+1$'  "${STUB_LOG_FILE}"
  if grep -q '^--expression$' "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"
    fail "adapter must translate --expression to positional"
  fi
  rm -f "${STUB_LOG_FILE}"
  printf '%s' "${output}" | jq -e '.value == 2' >/dev/null
}

@test "chrome-devtools-mcp adapter: tool_fill --secret-stdin accepts stdin (does NOT 41 like playwright-cli)" {
  STUB_LOG_FILE="$(mktemp)"
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "printf 'pass' | bash -c 'source \"${LIB_TOOL_DIR}/chrome-devtools-mcp.sh\"; tool_fill --ref e3 --secret-stdin'"
  assert_status 0
  grep -q '^fill$' "${STUB_LOG_FILE}"
  grep -q '^e3$'   "${STUB_LOG_FILE}"
  grep -q '^--secret-stdin$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
  printf '%s' "${output}" | jq -e '.event == "fill"' >/dev/null
  printf '%s' "${output}" | jq -e '.secret == true' >/dev/null
}

@test "chrome-devtools-mcp adapter: missing-fixture path propagates exit 41 from stub" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
  CHROME_DEVTOOLS_MCP_FIXTURES_DIR="${FIXTURES_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_open --url https://no-such-fixture.example"
  [ "${status}" = "41" ] || fail "expected exit 41 (no fixture), got ${status}"
}

@test "chrome-devtools-mcp adapter: tool_click without --ref returns 41 (TOOL_UNSUPPORTED_OP)" {
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
    run bash -c "source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'; tool_click"
  [ "${status}" = "41" ] || fail "expected exit 41 (missing target), got ${status}"
}
