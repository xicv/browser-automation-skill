load helpers

# Phase 6 part 8-i: browser-tab-list verb (read-only enumeration foundation).
# Daemon-required (mirrors route precedent — caches tabs[] for 8-ii / 8-iii).
# Routes to chrome-devtools-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-tab-list: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-tab-list.sh" --tool ghost-tool
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-tab-list: --tool=playwright-cli fails (capability filter rejects tab-list)" {
  run bash "${SCRIPTS_DIR}/browser-tab-list.sh" --tool playwright-cli
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-tab-list: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-tab-list.sh" --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "tab-list" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 8-i): pick_tool tab-list routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool tab-list
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "tab-list default"
}

@test "tool capabilities: chrome-devtools-mcp declares tab-list" {
  run bash -c "
    source '${LIB_TOOL_DIR}/chrome-devtools-mcp.sh'
    tool_capabilities | jq -e '.verbs | has(\"tab-list\")'
  "
  assert_status 0
}
