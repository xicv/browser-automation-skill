load helpers

@test "install.sh: --help prints usage and exits 0" {
  run bash "${REPO_ROOT}/install.sh" --help
  assert_status 0
  assert_output_contains "Usage:"
  assert_output_contains "--with-hooks"
  assert_output_contains "--dry-run"
}

@test "install.sh: --dry-run does not create state dir" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --dry-run
  local rc=$?
  local existed=0
  [ -d "${BROWSER_SKILL_HOME}" ] && existed=1
  teardown_temp_home
  [ "${existed}" -eq 0 ] || fail "expected --dry-run to NOT create state dir"
  [ "${rc}" -eq 0 ]
}

@test "install.sh: preflight fails (exit 20) when jq missing" {
  setup_temp_home
  # Stub PATH so jq isn't found; bash + python3 still are.
  local stub_dir="${TEST_HOME}/empty-bin"
  mkdir -p "${stub_dir}"
  PATH="${stub_dir}:/usr/bin:/bin" run bash "${REPO_ROOT}/install.sh" --dry-run
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "jq"
}
