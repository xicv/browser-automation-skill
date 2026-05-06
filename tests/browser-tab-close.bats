load helpers

# Phase 6 part 8-iii: browser-tab-close verb (last tab-* verb).
# Mutex flags: --tab-id N | --by-url-pattern STR. Daemon-required.
# Routes to chrome-devtools-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-tab-close: missing both flags fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires exactly one of"
}

@test "browser-tab-close: both --tab-id and --by-url-pattern fails (mutex)" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --tab-id 1 --by-url-pattern "x"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-tab-close: --tab-id 0 fails (1-based)" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --tab-id 0
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "1-based"
}

@test "browser-tab-close: --by-url-pattern empty fails" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --by-url-pattern ""
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--by-url-pattern requires a value"
}

@test "browser-tab-close: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --tool ghost-tool --tab-id 1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-tab-close: --tool=playwright-cli fails (capability filter)" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --tool playwright-cli --tab-id 1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-tab-close: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-tab-close.sh" --dry-run --tab-id 2
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "tab-close" and .tab_id == 2 and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 8-iii): pick_tool tab-close routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool tab-close --tab-id 1
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "tab-close default"
}
