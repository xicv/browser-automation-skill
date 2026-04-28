load helpers

@test "common.sh: exit codes are exported as readonly constants" {
  run bash -c "source '${LIB_DIR}/common.sh'; printf '%s\n' \"\${EXIT_OK}\" \"\${EXIT_USAGE_ERROR}\" \"\${EXIT_PREFLIGHT_FAILED}\" \"\${EXIT_TOOL_MISSING}\" \"\${EXIT_NETWORK_ERROR}\" \"\${EXIT_CAPTURE_WRITE_FAILED}\""
  assert_status 0
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "20" ]
  [ "${lines[3]}" = "21" ]
  [ "${lines[4]}" = "30" ]
  [ "${lines[5]}" = "31" ]
}

@test "common.sh: EXIT_OK is readonly (cannot be reassigned)" {
  run bash -c "source '${LIB_DIR}/common.sh'; EXIT_OK=99"
  assert_status 1
  assert_output_contains "readonly"
}

@test "common.sh: ok() prints to stderr with green prefix when TTY" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=1 ok 'hello'"
  assert_status 0
  assert_output_contains "hello"
}

@test "common.sh: warn() prints to stderr with yellow prefix" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=0 warn 'careful' 2>&1"
  assert_status 0
  assert_output_contains "careful"
  assert_output_contains "warn:"
}

@test "common.sh: die() prints to stderr and exits with given code" {
  run bash -c "source '${LIB_DIR}/common.sh'; die 23 'site not found'; echo 'after-die-should-not-print'"
  assert_status 23
  assert_output_contains "site not found"
  assert_output_not_contains "after-die-should-not-print"
}

@test "common.sh: NO_COLOR=1 suppresses ANSI escapes" {
  run bash -c "source '${LIB_DIR}/common.sh'; NO_COLOR=1 ok 'plain' 2>&1"
  assert_output_not_contains "$(printf '\033')"
}

@test "common.sh: resolve_browser_skill_home — explicit env var wins" {
  setup_temp_home
  BROWSER_SKILL_HOME="/tmp/explicit-override-xyz" \
    run bash -c "source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  [ "${output}" = "/tmp/explicit-override-xyz" ]
}

@test "common.sh: resolve_browser_skill_home — walks up to find .browser-skill/" {
  setup_temp_home
  mkdir -p "${TEST_HOME}/proj/sub/deeper"
  mkdir "${TEST_HOME}/proj/.browser-skill"
  unset BROWSER_SKILL_HOME
  run bash -c "cd '${TEST_HOME}/proj/sub/deeper'; source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  assert_output_contains "/proj/.browser-skill"
}

@test "common.sh: resolve_browser_skill_home — falls back to user-level" {
  setup_temp_home
  unset BROWSER_SKILL_HOME
  run bash -c "cd '${TEST_HOME}'; source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  [ "${output}" = "${HOME}/.browser-skill" ]
}

@test "common.sh: summary_json emits valid single-line JSON with required keys" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=doctor tool=none why=health-check status=ok duration_ms=42"
  assert_status 0
  # Must be a single line.
  [ "${#lines[@]}" -eq 1 ]
  # Must be valid JSON.
  printf '%s' "${output}" | jq -e . >/dev/null
  # Must have all keys.
  [ "$(printf '%s' "${output}" | jq -r .verb)" = "doctor" ]
  [ "$(printf '%s' "${output}" | jq -r .tool)" = "none" ]
  [ "$(printf '%s' "${output}" | jq -r .status)" = "ok" ]
  [ "$(printf '%s' "${output}" | jq -r .duration_ms)" = "42" ]
}

@test "common.sh: summary_json escapes embedded quotes in values" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=test why='quote\"inside' status=ok"
  assert_status 0
  printf '%s' "${output}" | jq -e . >/dev/null
  [ "$(printf '%s' "${output}" | jq -r .why)" = 'quote"inside' ]
}

@test "common.sh: summary_json rejects key without =value" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=doctor lonely_key status=ok"
  assert_status "${EXIT_USAGE_ERROR:-2}"
}
