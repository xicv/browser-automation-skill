load helpers

# Phase 6 part 8-ii: browser-tab-switch verb (first state-mutation on tabs[]).
# Mutex flags: --by-index N | --by-url-pattern STR (exactly one). Daemon-required.
# Routes to chrome-devtools-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-tab-switch: missing both flags fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires exactly one of"
}

@test "browser-tab-switch: both --by-index and --by-url-pattern fails (mutex)" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --by-index 1 --by-url-pattern "example"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-tab-switch: --by-index 0 fails (1-based)" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --by-index 0
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "1-based"
}

@test "browser-tab-switch: --by-url-pattern empty fails" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --by-url-pattern ""
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--by-url-pattern requires a value"
}

@test "browser-tab-switch: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --tool ghost-tool --by-index 1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-tab-switch: --tool=playwright-cli fails (capability filter)" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --tool playwright-cli --by-index 1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-tab-switch: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-tab-switch.sh" --dry-run --by-index 2
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "tab-switch" and .by_index == 2 and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 8-ii): pick_tool tab-switch routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool tab-switch --by-index 1
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "tab-switch default"
}
