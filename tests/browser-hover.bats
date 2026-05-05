load helpers

# Phase 6 part 3: browser-hover verb.
# Stateful — requires daemon (refMap precondition). Routes to cdt-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-hover: missing --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-hover.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --ref"
}

@test "browser-hover: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-hover.sh" --tool ghost-tool --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-hover: --tool=playwright-cli fails (capability filter rejects hover)" {
  run bash "${SCRIPTS_DIR}/browser-hover.sh" --tool playwright-cli --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-hover: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-hover.sh" --dry-run --ref e3
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "hover" and .ref == "e3" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 3): pick_tool hover routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool hover --ref e1
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "hover default"
}
