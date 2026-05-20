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

@test "mcp-server: tools/list — browser_open schema requires url + has additionalProperties:false" {
  # Tool-count + tool-name set are tested in the Stage 2 block below; this
  # test focuses on the input-schema discipline (required keys, no stealth
  # extras) which is the load-bearing contract for MCP clients.
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  [ -n "${call_resp}" ] || fail "no id=2 response in: ${result}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools[] | select(.name == "browser_open") | .inputSchema.required == ["url"]' >/dev/null \
    || fail "browser_open should require url: ${call_resp}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools[] | select(.name == "browser_open") | .inputSchema.additionalProperties == false' >/dev/null \
    || fail "browser_open should set additionalProperties=false: ${call_resp}"
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

# ---------- Phase 14 (MCP Stage 2): click + fill + extract ---------------

@test "mcp-server: tools/list returns 5 tools (open + snapshot + click + fill + extract)" {
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools | length == 5' >/dev/null \
    || fail "expected 5 tools; got: ${call_resp}"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools | map(.name) | sort == ["browser_click","browser_extract","browser_fill","browser_open","browser_snapshot"]' >/dev/null \
    || fail "tool names wrong: ${call_resp}"
}

@test "mcp-server: tools/call browser_click forwards --ref to browser-click.sh" {
  STUB_LOG_FILE="$(mktemp)"
  export STUB_LOG_FILE
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_click","arguments":{"ref":"e3"}}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" \
    | jq -e '.result.content[0].text | fromjson | .verb == "click" and .status == "ok"' >/dev/null \
    || fail "click summary not parsed: ${call_resp}"
  grep -q '^click$' "${STUB_LOG_FILE}" \
    || fail "stub never saw 'click'; log: $(cat "${STUB_LOG_FILE}")"
  grep -q '^e3$' "${STUB_LOG_FILE}" \
    || fail "stub never saw 'e3'; log: $(cat "${STUB_LOG_FILE}")"
  rm -f "${STUB_LOG_FILE}"
  unset STUB_LOG_FILE PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}

@test "mcp-server: tools/call browser_fill forwards --ref + --text" {
  STUB_LOG_FILE="$(mktemp)"
  export STUB_LOG_FILE
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_fill","arguments":{"ref":"e3","text":"hello"}}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" \
    | jq -e '.result.content[0].text | fromjson | .verb == "fill" and .status == "ok"' >/dev/null \
    || fail "fill summary not parsed: ${call_resp}"
  grep -q '^fill$'  "${STUB_LOG_FILE}" || fail "stub never saw 'fill'"
  grep -q '^e3$'    "${STUB_LOG_FILE}" || fail "stub never saw 'e3'"
  grep -q '^hello$' "${STUB_LOG_FILE}" || fail "stub never saw 'hello'"
  rm -f "${STUB_LOG_FILE}"
  unset STUB_LOG_FILE PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}

@test "mcp-server: browser_fill REJECTS attempts to pass secrets via MCP (no secret tunnel)" {
  # MCP has no stdin-stream channel — secrets MUST never travel through tool
  # arguments. The schema disallows a 'secret' field; passing it should be a
  # protocol-level error, not a stealth pass-through.
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | node "${MCP_BIN}")"
  local fill_schema
  fill_schema="$(printf '%s' "${result}" | jq -c 'select(.id==2) | .result.tools[] | select(.name == "browser_fill") | .inputSchema')"
  printf '%s' "${fill_schema}" \
    | jq -e '.properties | has("secret") | not' >/dev/null \
    || fail "browser_fill must NOT expose a 'secret' property (AP-7); got: ${fill_schema}"
  printf '%s' "${fill_schema}" \
    | jq -e '.additionalProperties == false' >/dev/null \
    || fail "browser_fill schema must reject unknown props; got: ${fill_schema}"
}

@test "mcp-server: tools/call browser_extract forwards --selector" {
  STUB_LOG_FILE="$(mktemp)"
  export STUB_LOG_FILE
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  # extract routes to chrome-devtools-mcp by default; force playwright-cli via tool override.
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_extract","arguments":{"selector":".title","tool":"playwright-cli"}}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  # playwright-cli adapter returns rc=41 (no extract support) — content should report status=error w/ that signal.
  printf '%s' "${call_resp}" | jq -e '.result._meta.exitCode | type == "number"' >/dev/null \
    || fail "missing exitCode meta: ${call_resp}"
  rm -f "${STUB_LOG_FILE}"
  unset STUB_LOG_FILE PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}

# ---------- Phase 14 (MCP Path 2): env-var whitelist passthrough ---------

@test "mcp-server: PLAYWRIGHT_CLI_BIN passes through to child (whitelist allows)" {
  # If this fails, our existing snapshot/open/click/fill tests above would
  # also fail, but the assertion here makes the contract explicit.
  STUB_LOG_FILE="$(mktemp)"
  export STUB_LOG_FILE
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' \
    | node "${MCP_BIN}")"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" | jq -e '.result.content[0].text | fromjson | .status == "ok"' >/dev/null \
    || fail "child didn't get PLAYWRIGHT_CLI_BIN: ${call_resp}"
  rm -f "${STUB_LOG_FILE}"
  unset STUB_LOG_FILE PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}

@test "mcp-server: arbitrary env var (FOO_RANDOM_SECRET) is BLOCKED from child (whitelist denies)" {
  # The MCP server's env whitelist must filter unknown vars — otherwise an MCP
  # client can leak its own secrets into our verb subprocess env (and thence
  # into stats.jsonl observed-snapshots if the verb echoes env back).
  export FOO_RANDOM_SECRET="this-must-never-reach-the-child"
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  # Custom stub binary that DUMPS its env to a logfile so we can inspect it.
  local env_dump child_stub
  env_dump="$(mktemp)"
  child_stub="$(mktemp)"
  cat > "${child_stub}" <<EOF
#!/usr/bin/env bash
env > "${env_dump}"
exec "${STUBS_DIR}/playwright-cli" "\$@"
EOF
  chmod +x "${child_stub}"
  export PLAYWRIGHT_CLI_BIN="${child_stub}"
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' \
    | node "${MCP_BIN}")"
  if grep -q "FOO_RANDOM_SECRET" "${env_dump}" 2>/dev/null; then
    fail "FOO_RANDOM_SECRET leaked into child env (whitelist failure); env_dump: $(cat "${env_dump}")"
  fi
  rm -f "${env_dump}" "${child_stub}"
  unset FOO_RANDOM_SECRET PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}

@test "mcp-server A1: discovery loop reads mcp-tools.json + exposes new verb when added" {
  # Proof that auto-discovery is the live source of truth — add a tmp JSON
  # with browser_inspect, point the server at it via env override,
  # verify tools/list includes inspect.
  tmp_json="$(mktemp).json"
  jq '. + {"inspect": {"description":"test-only","required":[]}}' \
    "${LIB_DIR}/node/mcp-tools.json" > "${tmp_json}"
  BROWSER_SKILL_MCP_TOOLS_JSON="${tmp_json}" \
    result="$(printf '%s\n%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      | BROWSER_SKILL_MCP_TOOLS_JSON="${tmp_json}" node "${MCP_BIN}" 2>/dev/null)"
  rm -f "${tmp_json}"
  local call_resp
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools | map(.name) | index("browser_inspect") != null' >/dev/null \
    || fail "auto-discovery didn't expose new verb 'browser_inspect'; got: ${call_resp}"
  # Also: tool enum for browser_inspect should be derived from adapters that
  # declare 'inspect' (chrome-devtools-mcp). Proves capability discovery
  # actually ran (not legacy fallback).
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools[] | select(.name == "browser_inspect") | .inputSchema.properties.tool.enum | index("chrome-devtools-mcp") != null' >/dev/null \
    || fail "tool enum should include chrome-devtools-mcp (only adapter that declares inspect); got: ${call_resp}"
}

@test "mcp-server A1: verb NOT in mcp-tools.json is NOT exposed (allowlist gate)" {
  # browser-audit.sh exists + chrome-devtools-mcp.sh declares 'audit' verb in
  # tool_capabilities. But mcp-tools.json does NOT have an entry. → tools/list
  # MUST NOT include browser_audit. This is the security boundary for new
  # adapter verbs (no accidental exposure).
  result="$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | node "${MCP_BIN}" 2>/dev/null)"
  local call_resp names
  call_resp="$(printf '%s' "${result}" | jq -c 'select(.id==2)')"
  names="$(printf '%s' "${call_resp}" | jq -c '.result.tools | map(.name) | sort')"
  printf '%s' "${call_resp}" \
    | jq -e '.result.tools | map(.name) | (index("browser_audit") == null) and (index("browser_eval") == null)' >/dev/null \
    || fail "allowlist gate broken — audit/eval should NOT appear; got: ${names}"
}

@test "mcp-server: MIDSCENE_MODEL_* envvar passes through to child (whitelist allows local-VLM config)" {
  export MIDSCENE_MODEL_BASE_URL="http://127.0.0.1:8080/v1"
  export PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli"
  export PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli"
  local env_dump child_stub
  env_dump="$(mktemp)"
  child_stub="$(mktemp)"
  cat > "${child_stub}" <<EOF
#!/usr/bin/env bash
env > "${env_dump}"
exec "${STUBS_DIR}/playwright-cli" "\$@"
EOF
  chmod +x "${child_stub}"
  export PLAYWRIGHT_CLI_BIN="${child_stub}"
  printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' \
    | node "${MCP_BIN}" >/dev/null
  grep -q "MIDSCENE_MODEL_BASE_URL=" "${env_dump}" 2>/dev/null \
    || fail "MIDSCENE_MODEL_BASE_URL did NOT reach child (whitelist too strict); env_dump: $(cat "${env_dump}")"
  rm -f "${env_dump}" "${child_stub}"
  unset MIDSCENE_MODEL_BASE_URL PLAYWRIGHT_CLI_BIN PLAYWRIGHT_CLI_FIXTURES_DIR
}
