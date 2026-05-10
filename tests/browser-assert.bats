load helpers

# Phase 9 part 1-ii — assert verb tests.
# `assert` is a thin wrapper over `extract --selector`; bash-side compares the
# extracted text against --text-contains predicate. NO new tool_assert ABI.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-assert: missing --selector fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-assert.sh" --text-contains "x"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--selector"
}

@test "browser-assert: missing --text-contains fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-assert.sh" --selector ".title"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--text-contains"
}

@test "browser-assert: --dry-run prints planned action and exits 0; no extract subprocess" {
  run bash "${SCRIPTS_DIR}/browser-assert.sh" --dry-run \
    --selector ".title" --text-contains "Hello"
  assert_status 0
  assert_output_contains "dry-run"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "assert" and .dry_run == true' >/dev/null
}

@test "browser-assert: predicate matches the stub-fixture's matches[] → status:ok exit 0" {
  # Stub fixture matches: ["Welcome", "Hello"].
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-assert.sh" --selector ".title" --text-contains "Welcome"
  assert_status 0
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "assert" and .status == "ok"' >/dev/null
}

@test "browser-assert: predicate fails to match → status:error exit 13 (ASSERTION_FAILED) + expected/got" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-assert.sh" --selector ".title" --text-contains "NeverPresentText"
  assert_status "$EXIT_ASSERTION_FAILED"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "assert" and .status == "error" and .expected == "NeverPresentText"' >/dev/null
}
