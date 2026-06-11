load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "verb_helpers: parse_verb_globals strips --site, --tool, --dry-run, --raw from argv" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --tool playwright-cli --foo --bar --dry-run --raw
    printf 'site=%s|tool=%s|dry=%s|raw=%s|rest=%s\n' \"\${ARG_SITE}\" \"\${ARG_TOOL}\" \"\${ARG_DRY_RUN}\" \"\${ARG_RAW}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=prod"
  assert_output_contains "tool=playwright-cli"
  assert_output_contains "dry=1"
  assert_output_contains "raw=1"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals leaves ARG_* unset when flags absent" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --foo --bar
    printf 'site=[%s]|tool=[%s]|dry=[%s]|raw=[%s]|rest=%s\n' \"\${ARG_SITE:-}\" \"\${ARG_TOOL:-}\" \"\${ARG_DRY_RUN:-}\" \"\${ARG_RAW:-}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=[]"
  assert_output_contains "tool=[]"
  assert_output_contains "dry=[]"
  assert_output_contains "raw=[]"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals errors on --site without value" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "site"
}

@test "verb_helpers: source_picked_adapter exits EXIT_TOOL_MISSING when adapter file missing" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter ghost-tool
  "
  assert_status "$EXIT_TOOL_MISSING"
  assert_output_contains "ghost-tool"
}

@test "verb_helpers: source_picked_adapter loads the adapter and exposes tool_metadata" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter playwright-cli
    tool_metadata
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.name == "playwright-cli"' >/dev/null
}

@test "verb_helpers: resolve_session_storage_state fails early when session TTL expired and auto-relogin is unavailable" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    profile=\$(jq -nc '{name:\"app\",url:\"https://app.example.com\",default_session:\"app--admin\",schema_version:1}')
    site_save app \"\${profile}\" '{}'
    ss=\$(jq -nc '{cookies:[],origins:[{origin:\"https://app.example.com\",localStorage:[]}]}')
    meta=\$(jq -nc '{name:\"app--admin\",site:\"app\",origin:\"https://app.example.com\",captured_at:\"2000-01-01T00:00:00Z\",expires_in_hours:1,schema_version:1}')
    session_save app--admin \"\${ss}\" \"\${meta}\"
    ARG_SITE=app
    resolve_session_storage_state
  "
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "expired by TTL"
}

@test "verb_helpers: resolve_session_storage_state refreshes expired TTL via auto-relogin" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    profile=\$(jq -nc '{name:\"app\",url:\"https://app.example.com\",default_session:\"app--admin\",schema_version:1}')
    site_save app \"\${profile}\" '{}'
    ss=\$(jq -nc '{cookies:[],origins:[{origin:\"https://app.example.com\",localStorage:[]}]}')
    old_meta=\$(jq -nc '{name:\"app--admin\",site:\"app\",origin:\"https://app.example.com\",captured_at:\"2000-01-01T00:00:00Z\",expires_in_hours:1,schema_version:1}')
    session_save app--admin \"\${ss}\" \"\${old_meta}\"
    _can_auto_relogin() { return 0; }
    _silent_relogin() {
      fresh_meta=\$(jq -nc '{name:\"app--admin\",site:\"app\",origin:\"https://app.example.com\",captured_at:\"2999-01-01T00:00:00Z\",expires_in_hours:1,schema_version:1}')
      session_delete app--admin
      session_save app--admin \"\${ss}\" \"\${fresh_meta}\"
    }
    ARG_SITE=app
    resolve_session_storage_state
    printf '%s\n' \"\${BROWSER_SKILL_STORAGE_STATE}\"
  "
  assert_status 0
  assert_output_contains "${BROWSER_SKILL_HOME}/sessions/app--admin.json"
}
