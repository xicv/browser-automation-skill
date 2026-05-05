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

# --- --auto (phase-5 part 3) ---
#
# These tests cover --auto verb-side validation only. Driver-execution
# (real-mode headless chromium login) is gated like --interactive's: deferred
# to manual / future-CI integration testing.
#
# All --auto tests that touch a credential pre-create the plaintext-acknowledged
# marker and stub bins for keychain/libsecret. Defensive: never let a test fall
# through to a real OS vault (lesson from part 2b).

_setup_auto_test() {
  setup_temp_home
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod --url https://app.example.com >/dev/null
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  chmod 700 "${BROWSER_SKILL_HOME}/credentials"
  : > "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
}

_seed_auto_cred() {
  # name, account, auto_relogin (true|false), site, auth_flow
  local name="$1" account="${2:-alice@example.com}" auto="${3:-true}" site="${4:-prod}"
  local auth_flow="${5:-single-step-username-password}"
  local meta
  meta="$(jq -nc --arg n "${name}" --arg s "${site}" --arg a "${account}" \
    --argjson ar "${auto}" --arg af "${auth_flow}" \
    '{schema_version:1, name:$n, site:$s, account:$a, backend:"plaintext",
      auth_flow:$af, auto_relogin:$ar, totp_enabled:false,
      created_at:"2026-05-03T00:00:00Z"}')"
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save '${name}' '${meta}'
    printf '%s' 'sekret' | credential_set_secret '${name}'
  "
}

@test "login --auto: mutually exclusive with --interactive" {
  _setup_auto_test
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as foo --auto --interactive
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "login --auto: mutually exclusive with --storage-state-file" {
  _setup_auto_test
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as foo --auto --storage-state-file /tmp/x.json
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "login --auto: --site is required" {
  _setup_auto_test
  run bash "${SCRIPTS_DIR}/browser-login.sh" --as foo --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "site"
}

@test "login --auto: refuses missing credential (exit 23)" {
  _setup_auto_test
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as never-set --auto
  teardown_temp_home
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "credential not found"
}

@test "login --auto: refuses credential with auto_relogin=false (exit 2)" {
  _setup_auto_test
  _seed_auto_cred prod--no-auto alice@example.com false
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as prod--no-auto --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "auto_relogin=false"
}

@test "login --auto: refuses credential bound to a different site (exit 2)" {
  _setup_auto_test
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name staging --url https://stg.example.com >/dev/null
  _seed_auto_cred staging--admin alice@example.com true staging
  # Try to use a staging-bound cred against the prod site
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as staging--admin --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "bound to site"
}

@test "login --auto --dry-run: skips driver invocation, reports planned action" {
  _setup_auto_test
  _seed_auto_cred prod--admin alice@example.com true
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as prod--admin --auto --dry-run
  teardown_temp_home
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "login" and .why == "auto-relogin-dry-run" and .status == "ok" and .would_run == true' >/dev/null
  printf '%s' "${last_json}" | jq -e '.account == "alice@example.com"' >/dev/null
  printf '%s' "${last_json}" | jq -e '.session == "prod--admin"' >/dev/null
  # Privacy: secret value 'sekret' (set by _seed_auto_cred) MUST NOT appear in output
  if printf '%s\n' "${lines[@]}" | grep -q 'sekret'; then
    fail "secret value leaked in --auto --dry-run output"
  fi
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

@test "login: --interactive and --storage-state-file are mutually exclusive" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as x --interactive --storage-state-file /tmp/x.json
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "login: --interactive --dry-run skips browser launch and reports planned action" {
  setup_temp_home
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/site.sh'
    profile=\$(jq -nc '{name:\"prod\", url:\"https://app.example.com\", label:\"\", viewport:\"1280x800\", default_session:null, default_tool:null, schema_version:1}')
    site_save prod \"\${profile}\" '{}'
  "
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod --as prod--admin --interactive --dry-run
  teardown_temp_home
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "login" and .why == "interactive-dry-run" and .status == "ok"' >/dev/null
}

# --- Phase 5 part 3-iii: --auto refuses non-single-step auth_flow ---------

@test "login --auto (3-iii): refuses cred with auth_flow=multi-step-username-password (exit 2)" {
  _setup_auto_test
  _seed_auto_cred prod--ms alice@example.com true prod multi-step-username-password
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod --as prod--ms --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "auth_flow=multi-step-username-password"
  assert_output_contains "use --interactive"
}

@test "login --auto (3-iii): refuses cred with auth_flow=username-only (exit 2)" {
  _setup_auto_test
  _seed_auto_cred prod--uo alice@example.com true prod username-only
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod --as prod--uo --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "auth_flow=username-only"
}

@test "login --auto (3-iii): refuses cred with auth_flow=custom (exit 2)" {
  _setup_auto_test
  _seed_auto_cred prod--cu alice@example.com true prod custom
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod --as prod--cu --auto
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "auth_flow=custom"
}

@test "login --auto (3-iii): single-step-username-password still works (regression — dry-run path)" {
  _setup_auto_test
  _seed_auto_cred prod--ss alice@example.com true prod single-step-username-password
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod --as prod--ss --auto --dry-run
  teardown_temp_home
  assert_status 0
  printf '%s' "${output}" | grep -q "would auto-relogin" || fail "expected dry-run path to engage"
}

@test "login: requires --interactive OR --storage-state-file (one of them)" {
  setup_temp_home
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/site.sh'
    profile=\$(jq -nc '{name:\"prod\", url:\"https://app.example.com\", label:\"\", viewport:\"1280x800\", default_session:null, default_tool:null, schema_version:1}')
    site_save prod \"\${profile}\" '{}'
  "
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod --as x
  teardown_temp_home
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "interactive"
}

@test "login: rejects path-traversal in --as" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as '../evil' \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status "$EXIT_USAGE_ERROR"
}
