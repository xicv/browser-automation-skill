load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sessions"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

# Seed a session with full meta. Mirrors session-loading.bats.
_seed_session() {
  local name="$1" url="$2"
  local origin
  origin="$(bash -c "source '${LIB_DIR}/session.sh'; url_origin '${url}'")"
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/session.sh'
    storage=\$(jq -nc --arg o '${origin}' \
      '{cookies:[{name:\"sid\",value:\"abc\",domain:(\$o|sub(\"https?://\";\"\")|sub(\":.*\";\"\")),path:\"/\"}, {name:\"csrf\",value:\"def\",domain:(\$o|sub(\"https?://\";\"\")|sub(\":.*\";\"\")),path:\"/\"}], origins:[{origin:\$o, localStorage:[]}]}')
    meta=\$(jq -nc --arg n '${name}' --arg s 'prod' --arg o '${origin}' \
      '{name:\$n, site:\$s, origin:\$o, captured_at:\"2026-05-01T00:00:00Z\", expires_in_hours:168, schema_version:1}')
    session_save '${name}' \"\${storage}\" \"\${meta}\"
  "
}

# --- show-session ---

@test "show-session: emits meta + storage_state counts (NEVER cookie values)" {
  _seed_session prod--admin https://app.example.com
  run bash "${SCRIPTS_DIR}/browser-show-session.sh" --as prod--admin
  assert_status 0
  printf '%s' "${output}" | jq -e '.verb == "show-session" and .session == "prod--admin"' >/dev/null
  printf '%s' "${output}" | jq -e '.meta.site == "prod" and .meta.origin == "https://app.example.com"' >/dev/null
  printf '%s' "${output}" | jq -e '.storage_state.cookie_count == 2 and .storage_state.origin_count == 1' >/dev/null
  # Critical: cookie VALUES never leak. Test fixture cookies are "abc" / "def".
  if echo "${output}" | grep -qE '"abc"|"def"'; then
    fail "cookie value leaked into show-session output"
  fi
}

@test "show-session: missing --as fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-show-session.sh"
  assert_status "$EXIT_USAGE_ERROR"
}

@test "show-session: missing session exits EXIT_SESSION_EXPIRED" {
  run bash "${SCRIPTS_DIR}/browser-show-session.sh" --as ghost
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "ghost"
}

@test "show-session: rejects path-traversal in --as" {
  run bash "${SCRIPTS_DIR}/browser-show-session.sh" --as '../evil'
  assert_status "$EXIT_USAGE_ERROR"
}

# --- remove-session ---

@test "remove-session: removes session + meta (typed-name confirm via stdin)" {
  _seed_session prod--admin https://app.example.com
  run bash -c "printf 'prod--admin\n' | bash '${SCRIPTS_DIR}/browser-remove-session.sh' --as prod--admin"
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod--admin.json" ] || fail "storageState file remains"
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod--admin.meta.json" ] || fail "meta file remains"
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "remove-session" and .why == "delete" and .status == "ok"' >/dev/null
}

@test "remove-session: refuses on confirmation mismatch (typed name wrong)" {
  _seed_session prod--admin https://app.example.com
  run bash -c "printf 'wrong\n' | bash '${SCRIPTS_DIR}/browser-remove-session.sh' --as prod--admin"
  assert_status "$EXIT_USAGE_ERROR"
  [ -f "${BROWSER_SKILL_HOME}/sessions/prod--admin.json" ] || fail "storageState file unexpectedly removed"
}

@test "remove-session: --yes-i-know skips the prompt" {
  _seed_session prod--admin https://app.example.com
  run bash "${SCRIPTS_DIR}/browser-remove-session.sh" --as prod--admin --yes-i-know
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod--admin.json" ] || fail "storageState file remains"
}

@test "remove-session: --dry-run does not delete; reports planned action" {
  _seed_session prod--admin https://app.example.com
  run bash "${SCRIPTS_DIR}/browser-remove-session.sh" --as prod--admin --dry-run
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sessions/prod--admin.json" ] || fail "storageState file should remain after dry-run"
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.would_run == true' >/dev/null
}

@test "remove-session: missing session exits 22" {
  run bash "${SCRIPTS_DIR}/browser-remove-session.sh" --as ghost --yes-i-know
  assert_status "$EXIT_SESSION_EXPIRED"
}

@test "remove-session: rejects path-traversal in --as" {
  run bash "${SCRIPTS_DIR}/browser-remove-session.sh" --as '../evil' --yes-i-know
  assert_status "$EXIT_USAGE_ERROR"
}
