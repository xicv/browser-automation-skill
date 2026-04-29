load helpers

setup() {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null 2>&1
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com >/dev/null
}

teardown() { teardown_temp_home; }

@test "login: writes session JSON + meta from a hand-edited storageState fixture" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status 0
  local ss="${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json"
  local meta="${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json"
  jq -e '.cookies[0].name == "sid"' "${ss}" >/dev/null
  jq -e '.origin == "https://app.example.com"' "${meta}" >/dev/null
  jq -e '.site == "prod-app"'                  "${meta}" >/dev/null
  jq -e '.schema_version == 1'                 "${meta}" >/dev/null
  # Final line is summary.
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "login" and .status == "ok" and .session == "prod-app--admin"' >/dev/null
}

@test "login: requires --site, --as, and --storage-state-file (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod-app --as x
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-login.sh" --as x --storage-state-file /tmp/x
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod-app --storage-state-file /tmp/x
  assert_status "$EXIT_USAGE_ERROR"
}

@test "login: --auto refused in Phase 2 (clear error message)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as x --auto
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "Phase 5"
}

@test "login: missing storage-state-file path exits 2" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as x --storage-state-file /no/such/path.json
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "not found"
}

@test "login: unknown site exits 23" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site ghost --as x \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "login: --dry-run does not write a session" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json" \
    --dry-run
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}
