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

@test "login: refuses storageState whose origins do not match the site (exit 22)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-bad-origin.json"
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "origin mismatch"
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "login: empty origins[] is allowed (cookie-only storageState)" {
  local fixture="${TEST_HOME}/empty-origins.json"
  printf '{"cookies":[{"name":"x","value":"y","domain":"app.example.com","path":"/","expires":-1,"httpOnly":true,"secure":true,"sameSite":"Lax"}],"origins":[]}' > "${fixture}"
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as p \
    --storage-state-file "${fixture}"
  assert_status 0
}

@test "login: --as falls back to site.default_session when omitted" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com \
    --default-session prod-app--admin --force >/dev/null
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "login: missing --as AND missing site.default_session is a usage error" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name no-default --url https://x.test --force >/dev/null
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site no-default \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "default_session"
}
