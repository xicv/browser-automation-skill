load helpers

# Phase 6 part 7-i: browser-route verb (block + allow actions only).
# Daemon-state-mutating. Routes to cdt-mcp. fulfill is part 7-ii.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-route: missing --pattern fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --action block
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --pattern"
}

@test "browser-route: missing --action fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://*.example.com/*"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --action"
}

@test "browser-route: --action fulfill rejected with hint about part 7-ii" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "fulfill is part 7-ii"
}

@test "browser-route: --action ghost (invalid) rejected" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action ghost
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "must be one of"
}

@test "browser-route: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --tool ghost-tool --pattern "https://x.com/*" --action block
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-route: --tool=playwright-cli fails (capability filter rejects route)" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --tool playwright-cli --pattern "https://x.com/*" --action block
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-route: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --dry-run --pattern "https://*.tracking.com/*" --action block
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "route" and .pattern == "https://*.tracking.com/*" and .action == "block" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 7): pick_tool route routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool route --pattern 'https://x.com/*' --action block
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "route default"
}
