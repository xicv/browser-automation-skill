load helpers

setup() {
  setup_temp_home
  init_paths
  BRIDGE="${SCRIPTS_DIR}/lib/node/chrome-devtools-bridge.mjs"
  STUB="${STUBS_DIR}/mcp-server-stub.mjs"
  MCP_STUB_LOG_FILE="${TEST_HOME}/mcp-stub.log"
  export MCP_STUB_LOG_FILE
}
teardown() { teardown_temp_home; }

run_real() {
  CHROME_DEVTOOLS_MCP_BIN="${STUB}" node "${BRIDGE}" "$@"
}

@test "bridge real-mode: file exists and is executable" {
  [ -f "${BRIDGE}" ] || fail "bridge file missing"
  [ -f "${STUB}" ] || fail "mcp stub missing"
  [ -x "${STUB}" ] || fail "mcp stub not executable"
}

@test "bridge real-mode: BROWSER_SKILL_LIB_STUB=1 still works (regression guard for part 1b)" {
  # No CHROME_DEVTOOLS_MCP_BIN set; lib-stub mode reads fixtures.
  out="$(BROWSER_SKILL_LIB_STUB=1 node "${BRIDGE}" inspect --capture-console 2>/dev/null)"
  printf '%s' "${out}" | jq -e '.event == "inspect"' >/dev/null
}

@test "bridge real-mode: open dispatches navigate_page with URL" {
  out="$(run_real open https://example.com)"
  printf '%s' "${out}" | jq -e '.verb == "open"' >/dev/null
  printf '%s' "${out}" | jq -e '.tool == "chrome-devtools-mcp"' >/dev/null
  printf '%s' "${out}" | jq -e '.why == "mcp/navigate_page"' >/dev/null
  printf '%s' "${out}" | jq -e '.url == "https://example.com"' >/dev/null
  printf '%s' "${out}" | jq -e '.message | contains("navigated to https://example.com")' >/dev/null
}

@test "bridge real-mode: initialize handshake exchanged BEFORE tools/call (verify stub log order)" {
  run_real open https://example.com >/dev/null
  # Stub log should have: initialize line FIRST, then tools/call line.
  init_line="$(grep -n '"method":"initialize"' "${MCP_STUB_LOG_FILE}" | head -1 | cut -d: -f1)"
  call_line="$(grep -n '"method":"tools/call"' "${MCP_STUB_LOG_FILE}" | head -1 | cut -d: -f1)"
  [ -n "${init_line}" ] || fail "no initialize line in stub log"
  [ -n "${call_line}" ] || fail "no tools/call line in stub log"
  [ "${init_line}" -lt "${call_line}" ] || fail "initialize must come before tools/call (init=${init_line}, call=${call_line})"
}

@test "bridge real-mode: snapshot returns eN-translated refs" {
  out="$(run_real snapshot)"
  printf '%s' "${out}" | jq -e '.verb == "snapshot"' >/dev/null
  printf '%s' "${out}" | jq -e '.refs | length == 2' >/dev/null
  printf '%s' "${out}" | jq -e '.refs[0].id == "e1"' >/dev/null
  printf '%s' "${out}" | jq -e '.refs[1].id == "e2"' >/dev/null
  printf '%s' "${out}" | jq -e '.refs[0].role == "button"' >/dev/null
  printf '%s' "${out}" | jq -e '.refs[0].name == "Submit"' >/dev/null
  # uid kept for traceability (per token-efficient-output §5 — translate at boundary)
  printf '%s' "${out}" | jq -e '.refs[0].uid == "cdp-uid-1234"' >/dev/null
}

@test "bridge real-mode: eval returns the evaluated value" {
  out="$(run_real eval "1+1")"
  printf '%s' "${out}" | jq -e '.verb == "eval"' >/dev/null
  printf '%s' "${out}" | jq -e '.value | contains("1+1")' >/dev/null
}

@test "bridge real-mode: audit returns lighthouse scores" {
  out="$(run_real audit)"
  printf '%s' "${out}" | jq -e '.verb == "audit"' >/dev/null
  printf '%s' "${out}" | jq -e '.scores.performance == 0.95' >/dev/null
}

@test "bridge real-mode: click without daemon returns exit 41 with daemon hint" {
  run bash -c "CHROME_DEVTOOLS_MCP_BIN='${STUB}' node '${BRIDGE}' click e1"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "error must mention 'requires running daemon'"
}

@test "bridge real-mode: fill without daemon returns exit 41 with daemon hint" {
  run bash -c "CHROME_DEVTOOLS_MCP_BIN='${STUB}' node '${BRIDGE}' fill e3 hello"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "error must mention 'requires running daemon'"
}

@test "bridge real-mode: inspect --capture-console emits console_messages (one-shot)" {
  out="$(run_real inspect --capture-console)"
  printf '%s' "${out}" | jq -e '.verb == "inspect"' >/dev/null
  printf '%s' "${out}" | jq -e '.tool == "chrome-devtools-mcp"' >/dev/null
  printf '%s' "${out}" | jq -e '.console_messages | length == 2' >/dev/null
}

@test "bridge real-mode: inspect --capture-network emits network_requests (one-shot)" {
  out="$(run_real inspect --capture-network)"
  printf '%s' "${out}" | jq -e '.network_requests | length == 1' >/dev/null
}

@test "bridge real-mode: inspect --screenshot returns screenshot_path (one-shot)" {
  out="$(run_real inspect --screenshot)"
  printf '%s' "${out}" | jq -e '.screenshot_path | type == "string"' >/dev/null
}

@test "bridge real-mode: inspect --capture-console --capture-network aggregates both (one-shot)" {
  out="$(run_real inspect --capture-console --capture-network)"
  printf '%s' "${out}" | jq -e '.console_messages | length == 2' >/dev/null
  printf '%s' "${out}" | jq -e '.network_requests | length == 1' >/dev/null
}

@test "bridge real-mode: extract --selector .x emits value (one-shot)" {
  out="$(run_real extract --selector .x)"
  printf '%s' "${out}" | jq -e '.verb == "extract"' >/dev/null
  printf '%s' "${out}" | jq -e '.tool == "chrome-devtools-mcp"' >/dev/null
  printf '%s' "${out}" | jq -e '.selector == ".x"' >/dev/null
  printf '%s' "${out}" | jq -e '.value | type == "string"' >/dev/null
}

@test "bridge real-mode: extract --eval document.title emits value (one-shot)" {
  out="$(run_real extract --eval "document.title")"
  printf '%s' "${out}" | jq -e '.verb == "extract"' >/dev/null
  printf '%s' "${out}" | jq -e '.value | contains("document.title")' >/dev/null
}

@test "bridge real-mode (Phase 6): press --key Enter dispatches press_key tool (one-shot)" {
  out="$(run_real press Enter)"
  printf '%s' "${out}" | jq -e '.verb == "press"' >/dev/null
  printf '%s' "${out}" | jq -e '.tool == "chrome-devtools-mcp"' >/dev/null
  printf '%s' "${out}" | jq -e '.why == "mcp/press_key"' >/dev/null
  printf '%s' "${out}" | jq -e '.key == "Enter"' >/dev/null
  printf '%s' "${out}" | jq -e '.message | contains("pressed Enter")' >/dev/null
}

@test "bridge real-mode: open with no URL exits non-zero" {
  run bash -c "CHROME_DEVTOOLS_MCP_BIN='${STUB}' node '${BRIDGE}' open"
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when --url missing"
}

@test "bridge real-mode: missing MCP server bin exits non-zero (no spawn)" {
  run bash -c "CHROME_DEVTOOLS_MCP_BIN='/nonexistent/mcp-bin-${RANDOM}' node '${BRIDGE}' open https://example.com"
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when MCP bin missing"
}

@test "bridge real-mode (1f): CHROME_USER_DATA_DIR forwards --user-data-dir DIR to MCP child" {
  CHROME_USER_DATA_DIR=/tmp/test-profile-1f run_real open https://example.com >/dev/null
  grep -- '--user-data-dir' "${MCP_STUB_LOG_FILE}" | grep -q '/tmp/test-profile-1f' \
    || fail "stub spawn-argv did not contain --user-data-dir /tmp/test-profile-1f"
}

@test "bridge real-mode (1f): no CHROME_USER_DATA_DIR set → no --user-data-dir arg in spawn" {
  run_real open https://example.com >/dev/null
  if grep -q -- '--user-data-dir' "${MCP_STUB_LOG_FILE}"; then
    fail "stub spawn-argv unexpectedly contained --user-data-dir"
  fi
}
