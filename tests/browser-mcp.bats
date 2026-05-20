load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  MCP_BIN="${LIB_DIR}/node/mcp-server.mjs"
  export MCP_BIN
}
teardown() {
  teardown_temp_home
}

# --- Phase 14 (Proposal 2): MCP server protocol contract ----------------

@test "mcp-server: initialize returns protocolVersion 2024-11-05 + serverInfo" {
  result="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | node "${MCP_BIN}")"
  printf '%s' "${result}" | jq -e '.jsonrpc == "2.0" and .id == 1' >/dev/null \
    || fail "envelope wrong: ${result}"
  printf '%s' "${result}" | jq -e '.result.protocolVersion == "2024-11-05"' >/dev/null \
    || fail "missing protocolVersion: ${result}"
  printf '%s' "${result}" | jq -e '.result.serverInfo.name == "browser-skill"' >/dev/null \
    || fail "missing serverInfo.name: ${result}"
  printf '%s' "${result}" | jq -e '.result.capabilities.tools | type == "object"' >/dev/null \
    || fail "missing capabilities.tools: ${result}"
}

@test "mcp-server: tools/list returns browser_open + browser_snapshot with input schemas" {
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  [ -n "${call_resp}" ] || fail "no id=2 response in: ${result}"
  printf '%s' "${call_resp}" | jq -e '.result.tools | length == 2' >/dev/null \
    || fail "expected 2 tools; got: ${call_resp}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools | map(.name) | sort == ["browser_open","browser_snapshot"]' >/dev/null \
    || fail "tool names wrong: ${call_resp}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools[] | select(.name == "browser_open") | .inputSchema.required == ["url"]' >/dev/null \
    || fail "browser_open should require url: ${call_resp}"
}

@test "mcp-server: tools/call browser_snapshot shells to browser-snapshot.sh and returns summary" {
  # Export env so the env vars reach BOTH printf AND node (env-prefix in a
  # pipeline only attaches to the first command; export propagates to all).
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' \
    | node "${MCP_BIN}")"
  unset PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  [ -n "${call_resp}" ] || fail "no id=2 response in: ${result}"
  printf '%s' "${call_resp}" | jq -e '.result.content[0].type == "text"' >/dev/null \
    || fail "wrong content type: ${call_resp}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.content[0].text | fromjson | .verb == "snapshot" and .status == "ok"' >/dev/null \
    || fail "summary not parsed as snapshot ok: ${call_resp}"
}

@test "mcp-server: tools/call unknown tool returns -32602 invalid params" {
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ghost_tool","arguments":{}}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" | jq -e '.error.code == -32602' >/dev/null \
    || fail "expected -32602; got: ${call_resp}"
  printf '%s' "${call_resp}" | jq -e '.error.message | test("Unknown tool")' >/dev/null \
    || fail "expected 'Unknown tool' message; got: ${call_resp}"
}

@test "mcp-server: unknown method returns -32601 method not found" {
  result="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":42,"method":"resources/list","params":{}}' \
    | node "${MCP_BIN}")"
  printf '%s' "${result}" | jq -e '.id == 42 and .error.code == -32601' >/dev/null \
    || fail "expected -32601; got: ${result}"
}

# --- browser-mcp.sh entry point ------------------------------------------

@test "browser-mcp.sh: --help prints usage and exits 0" {
  run bash "${SCRIPTS_DIR}/browser-mcp.sh" --help
  assert_status 0
  assert_output_contains "browser_open"
  assert_output_contains "browser_snapshot"
}

@test "browser-mcp.sh: serve subcommand exec's node with the bridge file" {
  # Verify serve actually starts a server that responds to initialize.
  result="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | bash "${SCRIPTS_DIR}/browser-mcp.sh" serve)"
  printf '%s' "${result}" | jq -e '.result.protocolVersion == "2024-11-05"' >/dev/null \
    || fail "serve did not invoke mcp-server.mjs: ${result}"
}

@test "browser-mcp.sh: unknown subcommand exits EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-mcp.sh" bogus
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "unknown subcommand"
}
