#!/usr/bin/env bats
# tests/daemon-registry.bats — P0a: implicit daemon auto-start + page-ownership
# registry. All tests mock node/browser — no real browsers launched.
# See: P0a design (scripts/lib/node/daemon-registry.mjs, verb_helpers.sh, router.sh)

load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# ---------------------------------------------------------------------------
# Test 1: open with session + dead daemon → auto-start invoked, registry written
# ---------------------------------------------------------------------------

@test "daemon-registry: open with session + no daemon → auto-start, registry entry created mode 0600" {
  # Fake storage state to satisfy _ensure_session_cdp_endpoint session guard.
  printf '%s\n' '{"cookies":[],"origins":[]}' > "${BROWSER_SKILL_HOME}/sess.json"

  local stub="${TEST_HOME}/node-stub"
  cat > "${stub}" <<EOF
#!/usr/bin/env bash
# Stub: writes daemon state + registry entry, logs calls.
printf '%s\n' "\$*" >> "${BROWSER_SKILL_HOME}/node.log"
case "\${2:-}" in
  daemon-start)
    printf '%s\n' "{\"pid\":$$,\"cdp_endpoint\":\"http://127.0.0.1:65100\",\"ipc_port\":65100}" \
      > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
    mkdir -p "${BROWSER_SKILL_HOME}/runtime"
    printf '%s\n' "{\"testsess\":{\"adapter\":\"playwright-lib\",\"pid\":$$,\"ipc_port\":65100,\"cdp_endpoint\":\"http://127.0.0.1:65100\",\"started_at\":\"2026-01-01T00:00:00.000Z\",\"last_used_at\":\"2026-01-01T00:00:00.000Z\"}}" \
      > "${BROWSER_SKILL_HOME}/runtime/registry.json"
    chmod 0600 "${BROWSER_SKILL_HOME}/runtime/registry.json"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${stub}"

  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE='${BROWSER_SKILL_HOME}/sess.json'
    export BROWSER_SKILL_SESSION_NAME='testsess'
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
  "
  assert_status 0

  # Stub was called with daemon-start.
  grep -q 'daemon-start' "${BROWSER_SKILL_HOME}/node.log" \
    || fail "expected daemon-start call; log: $(cat "${BROWSER_SKILL_HOME}/node.log" 2>/dev/null)"

  # Registry file exists.
  [ -f "${BROWSER_SKILL_HOME}/runtime/registry.json" ] \
    || fail "registry.json not written"

  # Registry has testsess entry with pid and ipc_port.
  jq -e '.testsess | (.pid | type == "number") and (.ipc_port | type == "number")' \
    "${BROWSER_SKILL_HOME}/runtime/registry.json" >/dev/null \
    || fail "registry entry shape wrong: $(cat "${BROWSER_SKILL_HOME}/runtime/registry.json")"

  # File mode 0600 (octal 33152 decimal = rw-------).
  local mode
  mode="$(stat -c '%a' "${BROWSER_SKILL_HOME}/runtime/registry.json" 2>/dev/null \
    || stat -f '%Lp' "${BROWSER_SKILL_HOME}/runtime/registry.json" 2>/dev/null)"
  [ "${mode}" = "600" ] || fail "expected mode 600, got: ${mode}"
}

# ---------------------------------------------------------------------------
# Test 2: no session + no BROWSER_SKILL_AUTO_DAEMON → no daemon start
# ---------------------------------------------------------------------------

@test "daemon-registry: open without session + no BROWSER_SKILL_AUTO_DAEMON → no daemon start" {
  local stub="${TEST_HOME}/node-stub"
  cat > "${stub}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${BROWSER_SKILL_HOME}/node.log"
exit 0
EOF
  chmod +x "${stub}"
  touch "${BROWSER_SKILL_HOME}/node.log"

  run bash -c "
    unset BROWSER_SKILL_STORAGE_STATE
    unset BROWSER_SKILL_AUTO_DAEMON
    export BROWSER_SKILL_NODE_BIN='${stub}'
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
  "
  assert_status 0

  # Stub must NOT have been called.
  ! grep -q 'daemon-start' "${BROWSER_SKILL_HOME}/node.log" \
    || fail "daemon-start must not be called without session or AUTO_DAEMON=1; log: $(cat "${BROWSER_SKILL_HOME}/node.log")"
}

# ---------------------------------------------------------------------------
# Test 3: BROWSER_SKILL_AUTO_DAEMON=0 → never auto-starts even with session
# ---------------------------------------------------------------------------

@test "daemon-registry: BROWSER_SKILL_AUTO_DAEMON=0 → never auto-starts even with session" {
  printf '%s\n' '{"cookies":[],"origins":[]}' > "${BROWSER_SKILL_HOME}/sess.json"

  local stub="${TEST_HOME}/node-stub"
  cat > "${stub}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${BROWSER_SKILL_HOME}/node.log"
exit 0
EOF
  chmod +x "${stub}"
  touch "${BROWSER_SKILL_HOME}/node.log"

  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE='${BROWSER_SKILL_HOME}/sess.json'
    export BROWSER_SKILL_AUTO_DAEMON=0
    export BROWSER_SKILL_NODE_BIN='${stub}'
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
  "
  assert_status 0

  ! grep -q 'daemon-start' "${BROWSER_SKILL_HOME}/node.log" \
    || fail "AUTO_DAEMON=0 must prevent daemon-start; log: $(cat "${BROWSER_SKILL_HOME}/node.log")"
}

# ---------------------------------------------------------------------------
# Test 4: BROWSER_SKILL_AUTO_DAEMON=1 + no session → starts daemon for "default"
# ---------------------------------------------------------------------------

@test "daemon-registry: BROWSER_SKILL_AUTO_DAEMON=1 + no session → starts daemon for default session" {
  local stub="${TEST_HOME}/node-stub"
  cat > "${stub}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${BROWSER_SKILL_HOME}/node.log"
case "\${2:-}" in
  daemon-start)
    printf '%s\n' "{\"pid\":$$,\"cdp_endpoint\":\"http://127.0.0.1:65200\",\"ipc_port\":65200}" \
      > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
    mkdir -p "${BROWSER_SKILL_HOME}/runtime"
    printf '%s\n' "{\"default\":{\"adapter\":\"playwright-lib\",\"pid\":$$,\"ipc_port\":65200,\"cdp_endpoint\":\"http://127.0.0.1:65200\",\"started_at\":\"2026-01-01T00:00:00.000Z\",\"last_used_at\":\"2026-01-01T00:00:00.000Z\"}}" \
      > "${BROWSER_SKILL_HOME}/runtime/registry.json"
    chmod 0600 "${BROWSER_SKILL_HOME}/runtime/registry.json"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${stub}"

  run bash -c "
    unset BROWSER_SKILL_STORAGE_STATE
    export BROWSER_SKILL_AUTO_DAEMON=1
    export BROWSER_SKILL_NODE_BIN='${stub}'
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
  "
  assert_status 0

  grep -q 'daemon-start' "${BROWSER_SKILL_HOME}/node.log" \
    || fail "expected daemon-start for AUTO_DAEMON=1 sessionless; log: $(cat "${BROWSER_SKILL_HOME}/node.log")"

  [ -f "${BROWSER_SKILL_HOME}/runtime/registry.json" ] \
    || fail "registry.json not written"

  jq -e '.default | .adapter == "playwright-lib"' \
    "${BROWSER_SKILL_HOME}/runtime/registry.json" >/dev/null \
    || fail "expected default entry in registry: $(cat "${BROWSER_SKILL_HOME}/runtime/registry.json")"
}

# ---------------------------------------------------------------------------
# Test 5: stale registry entry (dead pid) → _registry_has_live_daemon returns 1
# ---------------------------------------------------------------------------

@test "daemon-registry: stale registry entry (dead pid) → _registry_has_live_daemon returns 1" {
  mkdir -p "${BROWSER_SKILL_HOME}/runtime"
  # pid 2147483647 is guaranteed dead on all platforms.
  printf '%s\n' '{"testsess":{"adapter":"playwright-lib","pid":2147483647,"ipc_port":65300,"cdp_endpoint":"http://127.0.0.1:65300","started_at":"2026-01-01T00:00:00.000Z","last_used_at":"2026-01-01T00:00:00.000Z"}}' \
    > "${BROWSER_SKILL_HOME}/runtime/registry.json"

  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _registry_has_live_daemon 'testsess'
  "
  assert_status 1
}

# ---------------------------------------------------------------------------
# Test 6: live registry entry (own pid) → _registry_has_live_daemon returns 0
# ---------------------------------------------------------------------------

@test "daemon-registry: live registry entry (own pid) → _registry_has_live_daemon returns 0" {
  mkdir -p "${BROWSER_SKILL_HOME}/runtime"
  # Use $$ — current shell pid, guaranteed alive.
  printf '{"testsess":{"adapter":"playwright-lib","pid":%s,"ipc_port":65400,"cdp_endpoint":"http://127.0.0.1:65400","started_at":"2026-01-01T00:00:00.000Z","last_used_at":"2026-01-01T00:00:00.000Z"}}\n' \
    "$$" > "${BROWSER_SKILL_HOME}/runtime/registry.json"

  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _registry_has_live_daemon 'testsess'
  "
  assert_status 0
}

# ---------------------------------------------------------------------------
# Test 7: router snapshot → playwright-lib when registry has live daemon
# ---------------------------------------------------------------------------

@test "daemon-registry router: snapshot routes to playwright-lib when registry shows live daemon" {
  mkdir -p "${BROWSER_SKILL_HOME}/runtime"
  printf '{"default":{"adapter":"playwright-lib","pid":%s,"ipc_port":65500,"cdp_endpoint":"http://127.0.0.1:65500","started_at":"2026-01-01T00:00:00.000Z","last_used_at":"2026-01-01T00:00:00.000Z"}}\n' \
    "$$" > "${BROWSER_SKILL_HOME}/runtime/registry.json"

  run bash -c "
    export BROWSER_SKILL_SESSION_NAME=default
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot
  "
  assert_status 0
  assert_output_contains "playwright-lib"
  assert_output_contains "live daemon in registry"
}

# ---------------------------------------------------------------------------
# Test 8: router extract → chrome-devtools-mcp (registry rule does not cover extract)
# ---------------------------------------------------------------------------

@test "daemon-registry router: extract still routes to chrome-devtools-mcp (registry rule does not cover extract)" {
  # Even with a live registry entry, extract stays with chrome-devtools-mcp
  # because playwright-lib does not declare the extract verb.
  mkdir -p "${BROWSER_SKILL_HOME}/runtime"
  printf '{"default":{"adapter":"playwright-lib","pid":%s,"ipc_port":65510,"cdp_endpoint":"http://127.0.0.1:65510","started_at":"2026-01-01T00:00:00.000Z","last_used_at":"2026-01-01T00:00:00.000Z"}}\n' \
    "$$" > "${BROWSER_SKILL_HOME}/runtime/registry.json"

  run bash -c "
    export BROWSER_SKILL_SESSION_NAME=default
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool extract
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

# ---------------------------------------------------------------------------
# Test 9: daemon-status via real node driver (no daemon running → not-running)
# ---------------------------------------------------------------------------

@test "daemon-registry: daemon-status returns daemon-not-running event when no daemon" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  run node "${SCRIPTS_DIR}/lib/node/playwright-driver.mjs" daemon-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null \
    || fail "expected daemon-not-running event; output: ${output}"
}

# ---------------------------------------------------------------------------
# Test 10: registry-status verb returns entry shape from live registry file
# ---------------------------------------------------------------------------

@test "daemon-registry: registry-status verb reads registry and returns entries" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not on PATH"
  fi
  mkdir -p "${BROWSER_SKILL_HOME}/runtime"
  printf '{"mysess":{"adapter":"playwright-lib","pid":%s,"ipc_port":65600,"cdp_endpoint":"http://127.0.0.1:65600","started_at":"2026-01-01T00:00:00.000Z","last_used_at":"2026-01-01T00:00:00.000Z"}}\n' \
    "$$" > "${BROWSER_SKILL_HOME}/runtime/registry.json"
  chmod 0600 "${BROWSER_SKILL_HOME}/runtime/registry.json"

  run node "${SCRIPTS_DIR}/lib/node/playwright-driver.mjs" registry-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "registry-status" and (.entries | type == "object")' >/dev/null \
    || fail "expected registry-status event with entries; output: ${output}"
  # Entry for mysess should be present (pid = $$ is alive).
  printf '%s' "${output}" | jq -e '.entries.mysess.adapter == "playwright-lib"' >/dev/null \
    || fail "expected mysess entry in registry-status; output: ${output}"
}
