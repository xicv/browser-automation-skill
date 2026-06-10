load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  unset BROWSER_SKILL_CDP_ENDPOINT
  unset BROWSER_SKILL_STORAGE_STATE
  unset BROWSER_SKILL_AUTOSTART_DAEMON
  unset BROWSER_SKILL_NODE_BIN
  unset BROWSER_SKILL_SEED_KEY
}
teardown() {
  teardown_temp_home
}

@test "_ensure: no session -> no endpoint exported" {
  run bash -c "
    unset BROWSER_SKILL_STORAGE_STATE BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  [ -z "${output}" ] || fail "expected no endpoint, got: ${output}"
}

@test "_ensure: session active + running daemon state -> exports cdp_endpoint" {
  run bash -c "
    printf '{\"pid\":%s,\"cdp_endpoint\":\"http://127.0.0.1:65000\"}\n' \"\$\$\" > '${BROWSER_SKILL_HOME}/playwright-lib-daemon.json'
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  [ "${output}" = "http://127.0.0.1:65000" ] || fail "expected endpoint export, got: ${output}"
}

@test "_ensure: AUTOSTART=0 escape hatch -> no endpoint exported" {
  printf '%s\n' '{"pid":1,"cdp_endpoint":"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    export BROWSER_SKILL_AUTOSTART_DAEMON=0
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  [ -z "${output}" ] || fail "expected no endpoint, got: ${output}"
}

@test "_ensure: stale daemon state (dead pid) is NOT exported when restart fails" {
  printf '%s\n' '{"pid":2147483647,"cdp_endpoint":"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    export BROWSER_SKILL_NODE_BIN=/usr/bin/false
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  [ -z "${output}" ] || fail "expected stale endpoint not to export, got: ${output}"
}

@test "_ensure: stale daemon state triggers restart that rewrites a fresh endpoint" {
  printf '%s\n' '{"pid":2147483647,"cdp_endpoint":"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  local stub="${TEST_HOME}/node-stub"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"pid":1,"cdp_endpoint":"http://127.0.0.1:65111"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
exit 0
EOF
  chmod +x "${stub}"
  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  [ "${output}" = "http://127.0.0.1:65111" ] || fail "expected fresh endpoint export, got: ${output}"
}

@test "_ensure: session change (seed_key differs) restarts the daemon" {
  local stub="${BROWSER_SKILL_HOME}/node-stub.sh"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BROWSER_SKILL_HOME}/node.log"
case "${1}:${2}" in
  *playwright-driver.mjs:daemon-start)
    printf '%s\n' '{"pid":1,"seed_key":"NEWKEY","cdp_endpoint":"http://127.0.0.1:65222"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
    exit 0
    ;;
  *playwright-driver.mjs:daemon-stop)
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${stub}"
  printf '%s\n' '{"cookies":[],"origins":[]}' > "${BROWSER_SKILL_HOME}/sess.json"
  jq -n --argjson pid "$$" '{pid:$pid,seed_key:"OLDKEY",cdp_endpoint:"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE='${BROWSER_SKILL_HOME}/sess.json'
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  grep -q 'daemon-stop' "${BROWSER_SKILL_HOME}/node.log" || fail "expected daemon-stop"
  grep -q 'daemon-start' "${BROWSER_SKILL_HOME}/node.log" || fail "expected daemon-start"
  [ "${output}" = "http://127.0.0.1:65222" ] || fail "expected fresh endpoint export, got: ${output}"
}

@test "_ensure: matching seed_key does NOT restart" {
  local stub="${BROWSER_SKILL_HOME}/node-stub.sh"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BROWSER_SKILL_HOME}/node.log"
exit 0
EOF
  chmod +x "${stub}"
  touch "${BROWSER_SKILL_HOME}/node.log"
  printf '%s\n' '{"cookies":[],"origins":[]}' > "${BROWSER_SKILL_HOME}/sess.json"
  local key
  key="$(
    source "${LIB_DIR}/common.sh"; init_paths
    source "${LIB_DIR}/verb_helpers.sh"
    _seed_key "${BROWSER_SKILL_HOME}/sess.json"
  )"
  jq -n --argjson pid "$$" --arg key "${key}" '{pid:$pid,seed_key:$key,cdp_endpoint:"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    export BROWSER_SKILL_STORAGE_STATE='${BROWSER_SKILL_HOME}/sess.json'
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  ! grep -q 'daemon-stop' "${BROWSER_SKILL_HOME}/node.log" || fail "expected no daemon-stop"
  [ "${output}" = "http://127.0.0.1:65000" ] || fail "expected existing endpoint export, got: ${output}"
}

@test "_ensure: cdt-routed verb also starts the chrome-devtools-bridge daemon" {
  local stub="${BROWSER_SKILL_HOME}/node-stub.sh"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BROWSER_SKILL_HOME}/node.log"
exit 0
EOF
  chmod +x "${stub}"
  jq -n --argjson pid "$$" '{pid:$pid,seed_key:"",cdp_endpoint:"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    tool_metadata() { printf '{\"name\":\"chrome-devtools-mcp\"}'; }
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  grep -q 'chrome-devtools-bridge.mjs.*daemon-start' "${BROWSER_SKILL_HOME}/node.log" || fail "expected cdt bridge daemon-start"
  [ "${output}" = "http://127.0.0.1:65000" ] || fail "expected existing endpoint export, got: ${output}"
}

@test "_ensure: non-cdt verb does NOT start the cdt bridge" {
  local stub="${BROWSER_SKILL_HOME}/node-stub.sh"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BROWSER_SKILL_HOME}/node.log"
exit 0
EOF
  chmod +x "${stub}"
  touch "${BROWSER_SKILL_HOME}/node.log"
  jq -n --argjson pid "$$" '{pid:$pid,seed_key:"",cdp_endpoint:"http://127.0.0.1:65000"}' > "${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  run bash -c "
    tool_metadata() { printf '{\"name\":\"playwright-lib\"}'; }
    export BROWSER_SKILL_STORAGE_STATE=/dev/null
    export BROWSER_SKILL_NODE_BIN='${stub}'
    unset BROWSER_SKILL_CDP_ENDPOINT
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    _ensure_session_cdp_endpoint
    printf '%s' \"\${BROWSER_SKILL_CDP_ENDPOINT:-}\"
  "
  assert_status 0
  ! grep -q 'chrome-devtools-bridge.mjs' "${BROWSER_SKILL_HOME}/node.log" || fail "expected no cdt bridge start"
  [ "${output}" = "http://127.0.0.1:65000" ] || fail "expected existing endpoint export, got: ${output}"
}
