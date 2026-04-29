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

@test "site.sh: site_save writes valid JSON with schema_version=1 and mode 0600" {
  local profile_json='{"name":"prod-app","url":"https://app.example.com","viewport":{"width":1280,"height":800},"user_agent":null,"stealth":false,"default_session":null,"default_tool":null,"label":"","schema_version":1}'
  local meta_json='{"name":"prod-app","created_at":"2026-04-29T15:42:00Z","last_used_at":"2026-04-29T15:42:00Z"}'
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '${profile_json}' '${meta_json}'"
  assert_status 0
  # Profile file exists, valid JSON, mode 0600.
  [ -f "${BROWSER_SKILL_HOME}/sites/prod-app.json" ]
  jq -e . "${BROWSER_SKILL_HOME}/sites/prod-app.json" >/dev/null
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}/sites/prod-app.json" 2>/dev/null \
       || stat -c '%a' "${BROWSER_SKILL_HOME}/sites/prod-app.json" 2>/dev/null)"
  [ "${mode}" = "600" ]
  # Meta file likewise.
  [ -f "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" ]
  jq -e . "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" >/dev/null
}

@test "site.sh: site_save rejects malformed profile JSON" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save bad 'not json' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "profile JSON"
}

@test "site.sh: site_save rejects malformed meta JSON" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save bad '{}' 'nope'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "meta JSON"
}

@test "site.sh: site_save is atomic — partial failure leaves no half-written file" {
  # Simulate failure by making sites dir read-only AFTER its parent exists.
  chmod 500 "${BROWSER_SKILL_HOME}/sites"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save x '{}' '{}'"
  chmod 700 "${BROWSER_SKILL_HOME}/sites"
  # Either the save succeeded entirely (some test runners) or no file exists —
  # but never a half-written .tmp.* sitting around.
  ! ls "${BROWSER_SKILL_HOME}/sites/"*.tmp.* 2>/dev/null
}

@test "site.sh: site_load echoes the profile JSON as written" {
  local profile_json='{"name":"prod-app","url":"https://app.example.com","schema_version":1}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '${profile_json}' '{\"name\":\"prod-app\"}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_load prod-app | jq -r .name"
  assert_status 0
  [ "${output}" = "prod-app" ]
}

@test "site.sh: site_load fails (exit 23) when site missing" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_load nope"
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "site not found"
}

@test "site.sh: site_meta_load echoes the meta JSON" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '{\"name\":\"prod-app\"}' '{\"name\":\"prod-app\",\"created_at\":\"2026-04-29T15:42:00Z\"}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_meta_load prod-app | jq -r .created_at"
  assert_status 0
  [ "${output}" = "2026-04-29T15:42:00Z" ]
}

@test "site.sh: site_list_names lists profiles only (excludes .meta.json) sorted" {
  for n in zeta alpha mid; do
    bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save '${n}' '{\"name\":\"${n}\"}' '{\"name\":\"${n}\"}'"
  done
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_list_names"
  assert_status 0
  [ "${lines[0]}" = "alpha" ]
  [ "${lines[1]}" = "mid" ]
  [ "${lines[2]}" = "zeta" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "site.sh: site_list_names returns empty when no sites registered" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_list_names"
  assert_status 0
  [ -z "${output}" ]
}
