load helpers

# Tests for resolve_session_storage_state in verb_helpers.sh — Phase 4 Task 3.
# Validates the --site/--as → BROWSER_SKILL_STORAGE_STATE pipeline that lets
# the router prefer playwright-lib when a session is loaded.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sites" "${BROWSER_SKILL_HOME}/sessions"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

# Build a site profile + matching session storage state file + meta with
# origin (session_origin_check reads .origin from META, not storageState).
_seed_site_and_session() {
  local site_name="$1" url="$2" session_name="$3" default_session="${4:-}"

  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/site.sh'
    profile=\$(jq -nc --arg n '${site_name}' --arg u '${url}' --arg ds '${default_session}' \
      '{name:\$n, url:\$u, label:\"test\", viewport:\"1280x800\", default_session:\$ds, default_tool:null, schema_version:1}')
    site_save '${site_name}' \"\${profile}\" '{}'
  "

  # Compute the URL's origin (scheme://host[:port]) for both storageState
  # origins and the meta.origin field.
  local origin
  origin="$(bash -c "
    source '${LIB_DIR}/session.sh'
    url_origin '${url}'
  ")"

  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/session.sh'
    storage=\$(jq -nc --arg o '${origin}' \
      '{cookies:[{name:\"sid\",value:\"abc\",domain:(\$o|sub(\"https?://\";\"\")|sub(\":.*\";\"\")),path:\"/\"}], origins:[{origin:\$o}]}')
    meta=\$(jq -nc --arg o '${origin}' '{schema_version:1, origin:\$o, captured_at:\"2026-05-01T00:00:00Z\"}')
    session_save '${session_name}' \"\${storage}\" \"\${meta}\"
  "
}

@test "session-loading: no --site, no --as = no-op (BROWSER_SKILL_STORAGE_STATE unset)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    resolve_session_storage_state
    printf 'state=[%s]\n' \"\${BROWSER_SKILL_STORAGE_STATE:-}\"
  "
  assert_status 0
  [ "${output}" = "state=[]" ] || fail "expected state=[], got: ${output}"
}

@test "session-loading: --as without --site fails EXIT_USAGE_ERROR" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --as ghost
    resolve_session_storage_state
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--as requires --site"
}

@test "session-loading: --site for unregistered site fails EXIT_SITE_NOT_FOUND" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site ghost
    resolve_session_storage_state
  "
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "ghost"
}

@test "session-loading: --site without default_session, no --as = no-op" {
  _seed_site_and_session prod https://app.example.com prod--admin ""
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod
    resolve_session_storage_state
    printf 'state=[%s]\n' \"\${BROWSER_SKILL_STORAGE_STATE:-}\"
  "
  assert_status 0
  [ "${output}" = "state=[]" ] || fail "expected state=[], got: ${output}"
}

@test "session-loading: --site with default_session resolves to that storage state" {
  _seed_site_and_session prod https://app.example.com prod--admin prod--admin
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod
    resolve_session_storage_state
    printf 'state=[%s]\n' \"\${BROWSER_SKILL_STORAGE_STATE:-}\"
  "
  assert_status 0
  echo "${output}" | grep -qE '/sessions/prod--admin\.json\]$' \
    || fail "expected sessions/prod--admin.json path, got: ${output}"
}

@test "session-loading: --site --as overrides default_session" {
  _seed_site_and_session prod https://app.example.com prod--admin prod--admin
  _seed_site_and_session prod https://app.example.com prod--readonly prod--admin
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --as prod--readonly
    resolve_session_storage_state
    printf 'state=[%s]\n' \"\${BROWSER_SKILL_STORAGE_STATE:-}\"
  "
  assert_status 0
  echo "${output}" | grep -qE '/sessions/prod--readonly\.json\]$' \
    || fail "expected sessions/prod--readonly.json path, got: ${output}"
}

@test "session-loading: --as session that does not exist fails EXIT_SESSION_EXPIRED" {
  _seed_site_and_session prod https://app.example.com prod--admin ""
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --as ghost-session
    resolve_session_storage_state
  "
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "ghost-session"
}

@test "session-loading: session origins must match site URL (mismatch fails EXIT_SESSION_EXPIRED)" {
  _seed_site_and_session prod https://app.example.com prod--admin ""
  # session_origin_check reads META.origin (NOT storageState.origins). Mutate
  # the meta file to simulate a session captured against a different origin.
  bash -c "
    src='${BROWSER_SKILL_HOME}/sessions/prod--admin.meta.json'
    jq '.origin=\"https://other.example.com\"' \"\${src}\" > \"\${src}.tmp\" && mv \"\${src}.tmp\" \"\${src}\"
  "
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --as prod--admin
    resolve_session_storage_state
  "
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "origins do not match"
}

@test "session-loading: rule_session_required picks playwright-lib when state is set" {
  _seed_site_and_session prod https://app.example.com prod--admin prod--admin
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source '${LIB_DIR}/router.sh'
    parse_verb_globals --site prod
    resolve_session_storage_state
    pick_tool open
  "
  assert_status 0
  assert_output_contains "playwright-lib"
  assert_output_contains "session loading required"
}

@test "session-loading: rule_session_required defers when no storage state (default rule wins)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool open
  "
  assert_status 0
  assert_output_contains "playwright-cli"
  assert_output_contains "default for open"
}
