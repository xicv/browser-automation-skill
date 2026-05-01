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
  # Stub PATH containing only bash + python3 — NOT jq. /usr/bin / /bin would
  # still expose jq if installed system-wide (Linux apt package), so we build
  # a minimal symlinked bin and point PATH at it exclusively.
  local stub_dir="${TEST_HOME}/stub-bin"
  mkdir -p "${stub_dir}"
  ln -s "$(command -v bash)"    "${stub_dir}/bash"
  ln -s "$(command -v python3)" "${stub_dir}/python3"
  ln -s "$(command -v stat)"    "${stub_dir}/stat"
  ln -s "$(command -v dirname)" "${stub_dir}/dirname"
  ln -s "$(command -v mkdir)"   "${stub_dir}/mkdir"
  ln -s "$(command -v ln)"      "${stub_dir}/ln"
  ln -s "$(command -v rm)"      "${stub_dir}/rm"
  PATH="${stub_dir}" run "${stub_dir}/bash" "${REPO_ROOT}/install.sh" --dry-run
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
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
  mode="$(stat -c '%a' "${BROWSER_SKILL_HOME}" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}" 2>/dev/null)"
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

@test "install.sh: creates symlink ~/.claude/skills/browser-automation-skill -> repo" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  local link="${HOME}/.claude/skills/browser-automation-skill"
  [ -L "${link}" ]
  [ "$(readlink "${link}")" = "${REPO_ROOT}" ]
  teardown_temp_home
}

@test "install.sh: refuses to overwrite a non-symlink at the target path" {
  setup_temp_home
  mkdir -p "${HOME}/.claude/skills"
  echo "hand-written content" > "${HOME}/.claude/skills/browser-automation-skill"
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "not a symlink"
  teardown_temp_home
}

@test "install.sh: runs doctor at the end and reports its result" {
  setup_temp_home
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp" \
    run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  assert_output_contains "running doctor"
  assert_output_contains "all checks passed"
  teardown_temp_home
}

@test "install.sh --with-hooks wires core.hooksPath" {
  setup_temp_home
  # The repo we're testing IS a git repo; just verify hookspath gets set.
  cd "${REPO_ROOT}"
  bash "${REPO_ROOT}/install.sh" --user --with-hooks >/dev/null
  local result
  result="$(git -C "${REPO_ROOT}" config --get core.hooksPath || true)"
  teardown_temp_home
  [ "${result}" = ".githooks" ]
}

@test "SKILL.md: exists and has frontmatter with required fields" {
  [ -f "${REPO_ROOT}/SKILL.md" ]
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^name: browser-automation-skill$'
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^description:'
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^allowed-tools:'
}

@test "README.md: has install + first-flow sections" {
  grep -q '^## Install' "${REPO_ROOT}/README.md"
  grep -q '^### Personal' "${REPO_ROOT}/README.md"
  grep -q '/browser doctor' "${REPO_ROOT}/README.md"
}
