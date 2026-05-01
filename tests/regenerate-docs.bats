load helpers

@test "regenerate-docs: --to-stdout tool-versions emits a markdown table including playwright-cli" {
  run bash "${SCRIPTS_DIR}/regenerate-docs.sh" --to-stdout tool-versions
  assert_status 0
  assert_output_contains "playwright-cli"
  assert_output_contains "Version pin"
  assert_output_contains "Cheatsheet"
}

@test "regenerate-docs: --to-stdout skill-md emits a tools table including playwright-cli" {
  run bash "${SCRIPTS_DIR}/regenerate-docs.sh" --to-stdout skill-md
  assert_status 0
  assert_output_contains "playwright-cli"
}

@test "regenerate-docs: writing tool-versions.md is reproducible (idempotent)" {
  bash "${SCRIPTS_DIR}/regenerate-docs.sh" tool-versions
  first="$(cat "${REPO_ROOT}/references/tool-versions.md")"
  bash "${SCRIPTS_DIR}/regenerate-docs.sh" tool-versions
  second="$(cat "${REPO_ROOT}/references/tool-versions.md")"
  [ "${first}" = "${second}" ] || fail "regenerate-docs is not idempotent"
}

@test "regenerate-docs: SKILL.md marker block is replaced verbatim (idempotent)" {
  bash "${SCRIPTS_DIR}/regenerate-docs.sh" skill-md
  first="$(grep -A 100 'BEGIN AUTOGEN: tools-table' "${REPO_ROOT}/SKILL.md" | grep -B 100 'END AUTOGEN: tools-table')"
  bash "${SCRIPTS_DIR}/regenerate-docs.sh" skill-md
  second="$(grep -A 100 'BEGIN AUTOGEN: tools-table' "${REPO_ROOT}/SKILL.md" | grep -B 100 'END AUTOGEN: tools-table')"
  [ "${first}" = "${second}" ] || fail "SKILL.md marker block is not idempotent"
}
