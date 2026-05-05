load helpers

# E2E tests for the chrome-devtools-mcp bridge daemon (Phase 5 part 1c-ii).
#
# The daemon spawns a long-lived MCP server child (here: tests/stubs/mcp-server-stub.mjs)
# and holds the eN ↔ uid ref map across calls. Client invocations (click, fill)
# connect to the daemon over TCP loopback and translate refs → uids server-side.
#
# Mirrors tests/playwright-lib_daemon_e2e.bats shape but uses the mock MCP stub
# instead of real Chrome — so the suite runs in CI on macos + ubuntu without
# `npx chrome-devtools-mcp@latest` (which needs network + Chrome install).

setup() {
  setup_temp_home
  init_paths
  BRIDGE="${SCRIPTS_DIR}/lib/node/chrome-devtools-bridge.mjs"
  STUB="${STUBS_DIR}/mcp-server-stub.mjs"
  MCP_STUB_LOG_FILE="${TEST_HOME}/mcp-stub.log"
  export MCP_STUB_LOG_FILE
  # Defensive: every invocation in this file uses the stub as the MCP server.
  # Setup-level export per HANDOFF §60 (stubs MUST be exported in setup, not inline).
  export CHROME_DEVTOOLS_MCP_BIN="${STUB}"
}

teardown() {
  # Always reap daemon, even on test failure. Mirrors playwright-lib_daemon_e2e.bats.
  node "${BRIDGE}" daemon-stop >/dev/null 2>&1 || true
  teardown_temp_home
}

# --- Daemon lifecycle ---------------------------------------------------------

@test "daemon: status (no daemon) → daemon-not-running" {
  run node "${BRIDGE}" daemon-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null
}

@test "daemon: start emits daemon-started with pid + port + mcp_bin" {
  run node "${BRIDGE}" daemon-start
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-started"' >/dev/null
  printf '%s' "${output}" | jq -e '.pid | type == "number"' >/dev/null
  printf '%s' "${output}" | jq -e '.port | type == "number"' >/dev/null
  printf '%s' "${output}" | jq -e '.mcp_bin | type == "string"' >/dev/null
  # State file written 0600 under BROWSER_SKILL_HOME.
  state_file="${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json"
  [ -f "${state_file}" ] || fail "state file not written: ${state_file}"
  perms="$(stat -f '%Lp' "${state_file}" 2>/dev/null || stat -c '%a' "${state_file}")"
  [ "${perms}" = "600" ] || fail "expected mode 600, got ${perms}"
}

@test "daemon: status (running) → daemon-running" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" daemon-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-running"' >/dev/null
  printf '%s' "${output}" | jq -e '.pid | type == "number"' >/dev/null
}

@test "daemon: start when already running is idempotent" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" daemon-start
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-already-running"' >/dev/null
}

@test "daemon: stop emits daemon-stopped + unlinks state file" {
  node "${BRIDGE}" daemon-start >/dev/null
  state_file="${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json"
  [ -f "${state_file}" ] || fail "state file should exist after start"
  run node "${BRIDGE}" daemon-stop
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-stopped"' >/dev/null
  [ ! -f "${state_file}" ] || fail "state file should be unlinked after stop"
}

@test "daemon: stop when none running is no-op success" {
  run node "${BRIDGE}" daemon-stop
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null
}

# --- Click via daemon --------------------------------------------------------

@test "daemon: click without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' click e1"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon: snapshot → click e1 translates ref → uid; reply shaped" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" click e1
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "click"' >/dev/null
  printf '%s' "${output}" | jq -e '.ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.uid == "cdp-uid-1234"' >/dev/null
  printf '%s' "${output}" | jq -e '.status == "ok"' >/dev/null
  # Stub log: tools/call for `click` MUST carry uid (NOT ref). Translation happens daemon-side.
  grep -q '"name":"click"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=click"
  grep -q '"uid":"cdp-uid-1234"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing uid translation"
}

@test "daemon: click on unknown ref returns error event (no MCP call)" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" click e99
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when ref unknown"
  printf '%s' "${output}" | grep -q "e99" || fail "error must name the missing ref"
}

# --- Fill via daemon ---------------------------------------------------------

@test "daemon: fill e1 hello translates ref → uid; reply shaped" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" fill e1 hello
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "fill"' >/dev/null
  printf '%s' "${output}" | jq -e '.ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.uid == "cdp-uid-1234"' >/dev/null
  printf '%s' "${output}" | jq -e '.status == "ok"' >/dev/null
  grep -q '"name":"fill"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=fill"
  grep -q '"text":"hello"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing text passthrough"
}

@test "daemon: fill --secret-stdin keeps secret out of skill stdout (privacy canary)" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  CANARY="sekret-do-not-leak-CDT-1c-ii"
  run bash -c "printf '%s\n' '${CANARY}' | node '${BRIDGE}' fill e1 --secret-stdin"
  assert_status 0
  # Skill stdout (what the agent sees) MUST NOT contain the canary.
  printf '%s' "${output}" | grep -q "${CANARY}" \
    && fail "skill stdout leaked the secret canary: ${CANARY}" || true
  # Reply shape still correct.
  printf '%s' "${output}" | jq -e '.verb == "fill"' >/dev/null
  printf '%s' "${output}" | jq -e '.status == "ok"' >/dev/null
}

@test "daemon: fill without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' fill e1 hello"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}
