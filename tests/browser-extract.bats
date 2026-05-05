load helpers

# Phase 5 part 1e-i: new browser-extract.sh routes to chrome-devtools-mcp by
# default (post-1d router promotion). Existing fixture covers
# `extract --selector .title`.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-extract: --selector .title routes to cdt-mcp via lib-stub fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --selector .title
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q '"event":"extract"' \
    || fail "expected extract event in output"
}

@test "browser-extract: emits summary with verb=extract, tool=chrome-devtools-mcp, status=ok" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --selector .title
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .tool == "chrome-devtools-mcp" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.selector == ".title"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-extract: missing --selector AND --eval fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "selector"
}

@test "browser-extract: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool ghost-tool --selector .title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-extract: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --dry-run --selector .title
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .dry_run == true' >/dev/null
}

@test "browser-extract: --tool=playwright-cli fails (capability filter rejects extract)" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool playwright-cli --selector .title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}
