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

@test "install.sh: creates BROWSER_SKILL_HOME with subdirs at mode 0700" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    teardown_temp_home
    fail "install failed (exit ${rc}): ${output}"
  fi
  for d in "" sites sessions credentials captures flows; do
    [ -d "${BROWSER_SKILL_HOME}/${d}" ] || { teardown_temp_home; fail "expected dir: ${BROWSER_SKILL_HOME}/${d}"; }
  done
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}" 2>/dev/null || stat -c '%a' "${BROWSER_SKILL_HOME}" 2>/dev/null)"
  teardown_temp_home
  [ "${mode}" = "700" ]
}

@test "install.sh: writes version marker file" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  [ "$(cat "${BROWSER_SKILL_HOME}/version")" = "1" ]
  teardown_temp_home
}

@test "install.sh: writes defense-in-depth .gitignore inside state dir" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  [ "$(cat "${BROWSER_SKILL_HOME}/.gitignore")" = "*" ]
  teardown_temp_home
}

@test "install.sh: idempotent (second run does not fail or wipe)" {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null
  echo '{"name":"prod"}' > "${BROWSER_SKILL_HOME}/sites/prod.json"
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  teardown_temp_home
}
