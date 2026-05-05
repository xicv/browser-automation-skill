load helpers

# Phase 6 part 2: browser-select verb.
# Stateful — requires daemon (refMap precondition). Routes to cdt-mcp.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-select: missing --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --value alpha
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires --ref"
}

@test "browser-select: --ref but no --value/--label/--index fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "requires one of"
}

@test "browser-select: multiple mode flags (mutex) fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --ref e3 --value v --label l
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-select: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --tool ghost-tool --ref e3 --value v
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-select: --tool=playwright-cli fails (capability filter rejects select)" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --tool playwright-cli --ref e3 --value v
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

@test "browser-select: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-select.sh" --dry-run --ref e3 --label "Big"
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "select" and .ref == "e3" and .label == "Big" and .dry_run == true' >/dev/null
}

@test "router (Phase 6 part 2): pick_tool select routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool select --ref e1 --value alpha
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "select default"
}
