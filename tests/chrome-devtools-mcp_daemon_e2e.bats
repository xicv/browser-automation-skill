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
  # GNU first (Linux), BSD fallback (macOS). Reverse order is broken on Linux:
  # `stat -f` there means "filesystem status" — succeeds and dumps verbose
  # filesystem block instead of failing → fallback never runs (see common.sh:186).
  perms="$(stat -c '%a' "${state_file}" 2>/dev/null || stat -f '%Lp' "${state_file}" 2>/dev/null)"
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

# --- Inspect via daemon (Phase 5 part 1e-ii) --------------------------------

@test "daemon: inspect --capture-console via daemon emits console_messages" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" inspect --capture-console
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "inspect"' >/dev/null
  printf '%s' "${output}" | jq -e '.console_messages | length == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true' >/dev/null
}

@test "daemon: inspect --capture-console --capture-network multi-flag aggregation" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" inspect --capture-console --capture-network
  assert_status 0
  printf '%s' "${output}" | jq -e '.console_messages | length == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.network_requests | length == 1' >/dev/null
}

@test "daemon: inspect --screenshot returns screenshot_path" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" inspect --screenshot
  assert_status 0
  printf '%s' "${output}" | jq -e '.screenshot_path | type == "string"' >/dev/null
}

# --- Extract via daemon -----------------------------------------------------

@test "daemon: extract --selector .x returns value" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" extract --selector .x
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "extract"' >/dev/null
  printf '%s' "${output}" | jq -e '.selector == ".x"' >/dev/null
  printf '%s' "${output}" | jq -e '.value | type == "string"' >/dev/null
}

@test "daemon: extract --eval document.title returns value" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" extract --eval "document.title"
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "extract"' >/dev/null
  printf '%s' "${output}" | jq -e '.value | contains("document.title")' >/dev/null
}

# --- Phase 5 part 1f: CHROME_USER_DATA_DIR passthrough -----------------------

@test "daemon (Phase 6 part 2): select --value via daemon translates ref → uid + select_option" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" select e1 --value alpha
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "select"' >/dev/null
  printf '%s' "${output}" | jq -e '.ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.uid == "cdp-uid-1234"' >/dev/null
  printf '%s' "${output}" | jq -e '.value == "alpha"' >/dev/null
  grep -q '"name":"select_option"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=select_option"
  grep -q '"value":"alpha"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing value passthrough"
}

@test "daemon (Phase 6 part 2): select --label routes correctly" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" select e1 --label "Big Beta"
  assert_status 0
  printf '%s' "${output}" | jq -e '.label == "Big Beta"' >/dev/null
  grep -q '"label":"Big Beta"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing label passthrough"
}

@test "daemon (Phase 6 part 2): select --index routes correctly" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" select e1 --index 2
  assert_status 0
  printf '%s' "${output}" | jq -e '.index == 2' >/dev/null
  grep -q '"index":2' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing index passthrough"
}

@test "daemon (Phase 6 part 2): select without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' select e1 --value alpha"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 2): select on unknown ref returns error event (no MCP call)" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" select e99 --value alpha
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when ref unknown"
  printf '%s' "${output}" | grep -q "e99" || fail "error must name the missing ref"
}

@test "daemon (Phase 6 part 3): hover via daemon translates ref → uid + hover MCP tool" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" hover e1
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "hover"' >/dev/null
  printf '%s' "${output}" | jq -e '.ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.uid == "cdp-uid-1234"' >/dev/null
  grep -q '"name":"hover"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=hover"
  grep -q '"uid":"cdp-uid-1234"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing uid passthrough"
}

@test "daemon (Phase 6 part 3): hover without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' hover e1"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 3): hover on unknown ref returns error event (no MCP call)" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" hover e99
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when ref unknown"
  printf '%s' "${output}" | grep -q "e99" || fail "error must name the missing ref"
}

@test "daemon (Phase 6 part 7): route block via daemon registers rule + emits ack" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" route "https://*.tracking.com/*" block
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "route"' >/dev/null
  printf '%s' "${output}" | jq -e '.pattern == "https://*.tracking.com/*"' >/dev/null
  printf '%s' "${output}" | jq -e '.action == "block"' >/dev/null
  printf '%s' "${output}" | jq -e '.rule_count == 1' >/dev/null
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true' >/dev/null
  grep -q '"name":"route_url"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=route_url"
}

@test "daemon (Phase 6 part 7): two route calls accumulate in daemon's routeRules" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" route "https://a.com/*" block >/dev/null
  run node "${BRIDGE}" route "https://b.com/*" allow
  assert_status 0
  printf '%s' "${output}" | jq -e '.rule_count == 2' >/dev/null
}

@test "daemon (Phase 6 part 7): route with invalid action returns error event" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" route "https://x.com/*" ghost
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when action invalid"
  printf '%s' "${output}" | jq -e '.event == "error"' >/dev/null
  printf '%s' "${output}" | grep -q "ghost" || fail "error must name the bad action"
}

@test "daemon (Phase 6 part 7): route without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' route 'https://x.com/*' block"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 8-i): tab-list via daemon returns tabs[] from list_pages" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" tab-list
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "tab-list"' >/dev/null
  printf '%s' "${output}" | jq -e '.tab_count == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs | length == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs[0].tab_id == 1' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs[0].url | type == "string"' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs[0].title | type == "string"' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs[1].tab_id == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true' >/dev/null
  grep -q '"name":"list_pages"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=list_pages"
}

@test "daemon (Phase 6 part 8-i): tab-list is idempotent (cache replaced, not appended)" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" tab-list >/dev/null
  run node "${BRIDGE}" tab-list
  assert_status 0
  # Second call must still return tab_count=2 (replaced, not 4 from accumulation).
  printf '%s' "${output}" | jq -e '.tab_count == 2' >/dev/null
  printf '%s' "${output}" | jq -e '.tabs | length == 2' >/dev/null
}

@test "daemon (Phase 6 part 8-i): tab-list without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' tab-list"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 6): upload via daemon translates ref → uid + upload_file MCP tool" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  TMP_FILE="${TEST_HOME}/upload-target.bin"
  printf 'fake-pdf-content\n' > "${TMP_FILE}"
  run node "${BRIDGE}" upload e1 "${TMP_FILE}"
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "upload"' >/dev/null
  printf '%s' "${output}" | jq -e '.ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.uid == "cdp-uid-1234"' >/dev/null
  printf '%s' "${output}" | jq --arg p "${TMP_FILE}" -e '.path == $p' >/dev/null
  grep -q '"name":"upload_file"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=upload_file"
  grep -q '"uid":"cdp-uid-1234"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing uid passthrough"
}

@test "daemon (Phase 6 part 6): upload without daemon → exit 41 with daemon hint" {
  TMP_FILE="${TEST_HOME}/no-daemon.bin"
  printf 'x\n' > "${TMP_FILE}"
  run bash -c "node '${BRIDGE}' upload e1 '${TMP_FILE}'"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 5): drag via daemon translates both refs → uids + drag MCP tool" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" drag e1 e2
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "drag"' >/dev/null
  printf '%s' "${output}" | jq -e '.src_ref == "e1"' >/dev/null
  printf '%s' "${output}" | jq -e '.dst_ref == "e2"' >/dev/null
  printf '%s' "${output}" | jq -e '.src_uid == "cdp-uid-1234"' >/dev/null
  printf '%s' "${output}" | jq -e '.dst_uid == "cdp-uid-5678"' >/dev/null
  grep -q '"name":"drag"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=drag"
  grep -q '"src_uid":"cdp-uid-1234"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing src_uid passthrough"
  grep -q '"dst_uid":"cdp-uid-5678"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing dst_uid passthrough"
}

@test "daemon (Phase 6 part 5): drag without daemon → exit 41 with daemon hint" {
  run bash -c "node '${BRIDGE}' drag e1 e2"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  printf '%s' "${output}" | grep -q "requires running daemon" \
    || fail "stderr must mention 'requires running daemon'"
}

@test "daemon (Phase 6 part 5): drag with unknown src ref returns error event" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" drag e99 e2
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when src ref unknown"
  printf '%s' "${output}" | grep -q "e99" || fail "error must name the missing src ref"
}

@test "daemon (Phase 6 part 5): drag with unknown dst ref returns error event" {
  node "${BRIDGE}" daemon-start >/dev/null
  node "${BRIDGE}" open https://example.com >/dev/null
  node "${BRIDGE}" snapshot >/dev/null
  run node "${BRIDGE}" drag e1 e99
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when dst ref unknown"
  printf '%s' "${output}" | grep -q "e99" || fail "error must name the missing dst ref"
}

@test "daemon (Phase 6 part 4): wait --selector via daemon dispatches wait_for" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" wait ".x" --state hidden
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "wait"' >/dev/null
  printf '%s' "${output}" | jq -e '.selector == ".x"' >/dev/null
  printf '%s' "${output}" | jq -e '.state == "hidden"' >/dev/null
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true' >/dev/null
  grep -q '"name":"wait_for"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=wait_for"
  grep -q '"selector":".x"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing selector passthrough"
}

@test "daemon (Phase 6): press --key Enter routes through daemon → press_key MCP tool" {
  node "${BRIDGE}" daemon-start >/dev/null
  run node "${BRIDGE}" press Enter
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "press"' >/dev/null
  printf '%s' "${output}" | jq -e '.key == "Enter"' >/dev/null
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true' >/dev/null
  grep -q '"name":"press_key"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing tools/call name=press_key"
  grep -q '"key":"Enter"' "${MCP_STUB_LOG_FILE}" \
    || fail "stub log missing key passthrough"
}

@test "daemon (1f): CHROME_USER_DATA_DIR forwards --user-data-dir DIR to daemon's MCP child" {
  CHROME_USER_DATA_DIR=/tmp/test-profile-daemon-1f \
    node "${BRIDGE}" daemon-start >/dev/null
  grep -- '--user-data-dir' "${MCP_STUB_LOG_FILE}" | grep -q '/tmp/test-profile-daemon-1f' \
    || fail "stub spawn-argv did not contain --user-data-dir for daemon"
}
