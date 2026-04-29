# tests/site.bats
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sites"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/sites"
}

teardown() { teardown_temp_home; }

@test "site.sh: source guard prevents double-source" {
  run bash -c "source '${LIB_DIR}/site.sh'; source '${LIB_DIR}/site.sh'; printf '%s\n' \"\${BROWSER_SKILL_SITE_LOADED:-unset}\""
  assert_status 0
  [ "${output}" = "1" ]
}

@test "site.sh: _site_path echoes <SITES_DIR>/<name>.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; _site_path prod-app"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sites/prod-app.json" ]
}

@test "site.sh: _site_meta_path echoes <SITES_DIR>/<name>.meta.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; _site_meta_path prod-app"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" ]
}

@test "site.sh: site_exists returns 1 when no profile written" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_exists prod-app"
  assert_status 1
}

@test "site.sh: site_exists returns 0 when profile file present" {
  printf '{}\n' > "${BROWSER_SKILL_HOME}/sites/prod-app.json"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_exists prod-app"
  assert_status 0
}
