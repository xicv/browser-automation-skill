load helpers

# Phase 6 part 5: browser-drag verb.
# Stateful — requires daemon (refMap precondition for both src + dst).
# Routes to cdt-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-drag: missing --src-ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-drag.sh" --dst-ref e2
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --src-ref"
}

@test "browser-drag: missing --dst-ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-drag.sh" --src-ref e1
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --dst-ref"
}

@test "browser-drag: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-drag.sh" --tool ghost-tool --src-ref e1 --dst-ref e2
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-drag: --tool=playwright-cli fails (capability filter rejects drag)" {
  run bash "${SCRIPTS_DIR}/browser-drag.sh" --tool playwright-cli --src-ref e1 --dst-ref e2
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-drag: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-drag.sh" --dry-run --src-ref e1 --dst-ref e2
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "drag" and .src_ref == "e1" and .dst_ref == "e2" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 5): pick_tool drag routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool drag --src-ref e1 --dst-ref e2
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "drag default"
}
