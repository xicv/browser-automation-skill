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
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "does not exist"
}

@test "doctor: warns when ~/.browser-skill mode is not 0700" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 0755 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
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

@test "doctor: missing node is advisory only (still exits 0)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # Build a stub bin dir with bash + jq + python3 symlinked from real locations.
  # Crucially: NO `node` symlink. We restrict PATH to the stub so node lookup fails
  # while bash 4+ (required) and the doctor's other deps still work.
  local stub="${TEST_HOME}/bin"
  mkdir -p "${stub}"
  ln -s "$(command -v bash)" "${stub}/bash"
  ln -s "$(command -v jq)" "${stub}/jq"
  ln -s "$(command -v python3)" "${stub}/python3"
  # /usr/sbin needed for fdesetup (disk encryption check).
  PATH="${stub}:/usr/sbin:/bin:/usr/bin" run "${stub}/bash" "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  # node is missing but it's advisory — doctor must still exit 0.
  assert_status 0
  assert_output_contains "node NOT FOUND"
  assert_output_contains "advisory"
}
