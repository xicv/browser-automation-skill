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
