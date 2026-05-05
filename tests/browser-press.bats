load helpers

# Phase 6 part 1: browser-press verb.
# Routes to chrome-devtools-mcp by default (cdt-mcp's press_key MCP tool;
# no other adapter declares press yet).

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-press: --key Enter routes to cdt-mcp via lib-stub fixture" {
  # No fixture exists for this exact argv hash; the lib-stub bridge will
  # exit 41 on miss but the routing path is exercised. Test focuses on
  # router behavior — actual code-path coverage in the daemon e2e tests.
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-press.sh" --key Enter
  # Expect exit 41 (fixture miss) — confirms router picked cdt-mcp + bridge
  # was invoked. The summary line still emits.
  [ "${status}" = "41" ] || fail "expected exit 41 (fixture miss path), got ${status}"
}

@test "browser-press: missing --key fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-press.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --key"
}

@test "browser-press: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-press.sh" --tool ghost-tool --key Enter
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-press: --tool=playwright-cli fails (capability filter rejects press)" {
  run bash "${SCRIPTS_DIR}/browser-press.sh" --tool playwright-cli --key Enter
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-press: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-press.sh" --dry-run --key Tab
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "press" and .key == "Tab" and .dry_run == true' >/dev/null
}

@test "router (Phase 6): pick_tool press routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool press --key Enter
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "press default"
}
