load helpers

# Phase 5 part 1e-i: un-skipped + re-aimed at chrome-devtools-mcp lib-stub mode.
# Pre-1d, `pick_tool inspect` died EXIT_TOOL_MISSING (no rule). Post-1d the
# router promotes inspect → chrome-devtools-mcp. The adapter shells to the
# bridge; with BROWSER_SKILL_LIB_STUB=1 the bridge resolves a sha256(argv)
# fixture under tests/fixtures/chrome-devtools-mcp/ instead of spawning a real
# MCP server. Real-mode dispatch (no BROWSER_SKILL_LIB_STUB=1) for inspect is
# still exit 41 — bridge daemon dispatch lands in part 1e-ii.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-inspect: --capture-console routes to cdt-mcp via lib-stub fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q '"event":"inspect"' \
    || fail "expected inspect event in output"
}

@test "browser-inspect: emits summary with verb=inspect, tool=chrome-devtools-mcp, status=ok" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "inspect" and .tool == "chrome-devtools-mcp" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-inspect: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-inspect.sh" --tool ghost-tool --capture-console
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-inspect: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-inspect.sh" --dry-run --capture-console
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "inspect" and .dry_run == true' >/dev/null
}
