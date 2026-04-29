# tests/session.bats
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sessions"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/sessions"
}

teardown() { teardown_temp_home; }

@test "session.sh: source guard prevents double-source" {
  run bash -c "source '${LIB_DIR}/session.sh'; source '${LIB_DIR}/session.sh'; printf '%s\n' \"\${BROWSER_SKILL_SESSION_LOADED:-unset}\""
  assert_status 0
  [ "${output}" = "1" ]
}

@test "session.sh: _session_path echoes <SESSIONS_DIR>/<name>.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; _session_path prod-app--admin"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "session.sh: _session_meta_path echoes <SESSIONS_DIR>/<name>.meta.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; _session_meta_path prod-app--admin"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json" ]
}

@test "session.sh: session_exists is false for missing, true for present" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_exists nope"
  assert_status 1
  printf '{}' > "${BROWSER_SKILL_HOME}/sessions/here.json"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_exists here"
  assert_status 0
}

@test "session.sh: session_save writes storageState + meta atomically at mode 0600" {
  local ss='{"cookies":[{"name":"sid","value":"abc","domain":"app.example.com","path":"/","expires":-1,"httpOnly":true,"secure":true,"sameSite":"Lax"}],"origins":[{"origin":"https://app.example.com","localStorage":[]}]}'
  local meta='{"name":"prod-app--admin","site":"prod-app","origin":"https://app.example.com","captured_at":"2026-04-29T15:42:00Z","source_user_agent":"phase-2 stub","expires_in_hours":168,"schema_version":1}'
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save prod-app--admin '${ss}' '${meta}'"
  assert_status 0
  jq -e '.cookies[0].name == "sid"' "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" >/dev/null
  jq -e '.schema_version == 1' "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json" >/dev/null
  for f in prod-app--admin.json prod-app--admin.meta.json; do
    local mode
    mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}/sessions/${f}" 2>/dev/null \
         || stat -c '%a' "${BROWSER_SKILL_HOME}/sessions/${f}" 2>/dev/null)"
    [ "${mode}" = "600" ] || fail "expected mode 600 on ${f}, got ${mode}"
  done
}

@test "session.sh: session_save rejects malformed storageState JSON (exit 2)" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x 'not json' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
}

@test "session.sh: session_save rejects storageState missing cookies/origins arrays (exit 2)" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[]}' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "origins"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"origins\":[]}' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "cookies"
}

@test "session.sh: session_load echoes the storageState JSON" {
  local ss='{"cookies":[],"origins":[{"origin":"https://app.example.com","localStorage":[]}]}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '${ss}' '{\"name\":\"x\",\"site\":\"y\",\"origin\":\"https://app.example.com\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_load x | jq -r '.origins[0].origin'"
  assert_status 0
  [ "${output}" = "https://app.example.com" ]
}

@test "session.sh: session_load fails (exit 22) when missing" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_load nope"
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "session not found"
}

@test "session.sh: session_meta_load echoes the meta JSON" {
  local ss='{"cookies":[],"origins":[]}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '${ss}' '{\"name\":\"x\",\"origin\":\"https://x.test\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_meta_load x | jq -r .origin"
  assert_status 0
  [ "${output}" = "https://x.test" ]
}
