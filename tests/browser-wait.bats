load helpers

# Phase 6 part 4: browser-wait verb.
# Stateless — works one-shot or daemon-routed. Routes to cdt-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-wait: missing --selector fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-wait.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --selector"
}

@test "browser-wait: --state with invalid value fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-wait.sh" --selector ".x" --state ghost
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "must be one of"
}

@test "browser-wait: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-wait.sh" --tool ghost-tool --selector ".x"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-wait: --tool=playwright-cli fails (capability filter rejects wait)" {
  run bash "${SCRIPTS_DIR}/browser-wait.sh" --tool playwright-cli --selector ".x"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-wait: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-wait.sh" --dry-run --selector ".x" --state hidden --timeout 3000
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "wait" and .selector == ".x" and .state == "hidden" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 4): pick_tool wait routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool wait --selector '.x'
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "wait default"
}
