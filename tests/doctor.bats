load helpers

@test "doctor: prints resolved BROWSER_SKILL_HOME at top" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "${BROWSER_SKILL_HOME}"
}

@test "doctor: passes when bash, jq, python3 are present" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "all checks passed"
}

@test "doctor: emits a final JSON summary line on stdout" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  # Find the final line that's valid JSON
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "doctor"' >/dev/null
}
