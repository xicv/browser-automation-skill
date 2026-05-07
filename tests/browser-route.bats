load helpers

# Phase 6 part 7-i: browser-route verb (block + allow actions).
# Phase 6 part 7-ii: extends with --action fulfill + --status + --body[-stdin].
# Daemon-state-mutating. Routes to cdt-mcp.

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

# ---------- Phase 6 part 7-ii: --action fulfill -------------------------------

@test "browser-route (7-ii): --action fulfill --status 200 --body OK dry-run prints fulfill_status + body_bytes" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --dry-run \
    --pattern "https://api.x.com/*" --action fulfill --status 200 --body 'hello world'
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "route" and .action == "fulfill" and .fulfill_status == 200 and .body_bytes == 11 and .dry_run == true' >/dev/null
}

@test "browser-route (7-ii): --action fulfill without --status fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill --body 'x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--status"
}

@test "browser-route (7-ii): --action fulfill without body fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill --status 200
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--body"
}

@test "browser-route (7-ii): --body and --body-stdin mutex" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill --status 200 --body 'x' --body-stdin
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-route (7-ii): --status out-of-range (99) rejected" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill --status 99 --body 'x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "100-599"
}

@test "browser-route (7-ii): --status non-integer rejected" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action fulfill --status notanumber --body 'x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "integer"
}

@test "browser-route (7-ii): --status with --action block rejected (only valid with fulfill)" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action block --status 200
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "fulfill"
}

@test "browser-route (7-ii): --body with --action allow rejected" {
  run bash "${SCRIPTS_DIR}/browser-route.sh" --pattern "https://x.com/*" --action allow --body 'x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "fulfill"
}
