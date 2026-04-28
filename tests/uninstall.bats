load helpers

@test "uninstall.sh: --help prints usage" {
  run bash "${REPO_ROOT}/uninstall.sh" --help
  assert_status 0
  assert_output_contains "Usage:"
}

@test "uninstall.sh: removes symlink, keeps state by default" {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null
  run bash "${REPO_ROOT}/uninstall.sh" --keep-state
  assert_status 0
  [ ! -L "${HOME}/.claude/skills/browser-automation-skill" ]
  [ -d "${BROWSER_SKILL_HOME}" ]
  teardown_temp_home
}
