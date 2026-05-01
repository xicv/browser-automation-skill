load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sites" "${BROWSER_SKILL_HOME}/sessions"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

# Build a site profile + session storageState + meta. Mirrors session-loading.bats.
_seed() {
  local site_name="$1" url="$2" session_name="$3"
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/site.sh'
    profile=\$(jq -nc --arg n '${site_name}' --arg u '${url}' \
      '{name:\$n, url:\$u, label:\"test\", viewport:\"1280x800\", default_session:null, default_tool:null, schema_version:1}')
    site_save '${site_name}' \"\${profile}\" '{}'
  "
  local origin
  origin="$(bash -c "source '${LIB_DIR}/session.sh'; url_origin '${url}'")"
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/session.sh'
    storage=\$(jq -nc --arg o '${origin}' \
      '{cookies:[{name:\"sid\",value:\"abc\",domain:(\$o|sub(\"https?://\";\"\")|sub(\":.*\";\"\")),path:\"/\"}], origins:[{origin:\$o, localStorage:[]}]}')
    meta=\$(jq -nc --arg n '${session_name}' --arg s '${site_name}' --arg o '${origin}' \
      '{name:\$n, site:\$s, origin:\$o, captured_at:\"2026-05-01T00:00:00Z\", expires_in_hours:168, schema_version:1}')
    session_save '${session_name}' \"\${storage}\" \"\${meta}\"
  "
}

@test "list-sessions: empty directory → status=empty, count=0" {
  run bash "${SCRIPTS_DIR}/browser-list-sessions.sh"
  assert_status 0
  printf '%s' "${output}" | jq -e '.status == "empty" and .count == 0 and (.sessions | length == 0)' >/dev/null
}

@test "list-sessions: lists registered sessions with site + origin + expires_in_hours" {
  _seed prod https://app.example.com prod--admin
  _seed prod https://app.example.com prod--readonly
  run bash "${SCRIPTS_DIR}/browser-list-sessions.sh"
  assert_status 0
  printf '%s' "${output}" | jq -e '.status == "ok" and .count == 2' >/dev/null
  printf '%s' "${output}" | jq -e '[.sessions[].session] | sort | . == ["prod--admin","prod--readonly"]' >/dev/null
  printf '%s' "${output}" | jq -e '.sessions[0].site == "prod" and .sessions[0].origin == "https://app.example.com"' >/dev/null
}

@test "list-sessions: --site NAME filters to one site (1-many credentials per site)" {
  _seed prod    https://app.example.com  prod--admin
  _seed prod    https://app.example.com  prod--readonly
  _seed staging https://staging.example.com  staging--admin
  run bash "${SCRIPTS_DIR}/browser-list-sessions.sh" --site prod
  assert_status 0
  printf '%s' "${output}" | jq -e '.count == 2 and .why == "list-by-site" and .site_filter == "prod"' >/dev/null
  printf '%s' "${output}" | jq -e '[.sessions[].session] | sort | . == ["prod--admin","prod--readonly"]' >/dev/null
}

@test "list-sessions: --site NAME on no-match yields status=empty" {
  _seed prod https://app.example.com prod--admin
  run bash "${SCRIPTS_DIR}/browser-list-sessions.sh" --site nowhere
  assert_status 0
  printf '%s' "${output}" | jq -e '.status == "empty" and .count == 0 and .site_filter == "nowhere"' >/dev/null
}

@test "list-sessions: skips orphan storageState (no meta sidecar)" {
  # An orphan .json without .meta.json should be ignored — we can't bind it
  # to a site without meta.site, and emitting half-info would be misleading.
  printf '{}' > "${BROWSER_SKILL_HOME}/sessions/orphan.json"
  run bash "${SCRIPTS_DIR}/browser-list-sessions.sh"
  assert_status 0
  printf '%s' "${output}" | jq -e '.count == 0' >/dev/null
}
