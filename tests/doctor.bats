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

@test "doctor: warns when ~/.browser-skill missing" {
  setup_temp_home
  # Don't create BROWSER_SKILL_HOME — should be flagged.
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "does not exist"
}

@test "doctor: warns when ~/.browser-skill mode is not 0700" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 0755 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "mode 755"
  assert_output_contains "expected 700"
}

@test "doctor: prints disk-encryption status (advisory, never fails)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  # disk-encryption status is advisory: doctor MUST mention it but MUST NOT fail on it.
  assert_status 0
  assert_output_contains "disk encryption"
}
