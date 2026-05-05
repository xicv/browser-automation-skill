load helpers

# Phase 5 part 1e-i: new browser-audit.sh routes to chrome-devtools-mcp by
# default (post-1d router promotion). Lib-stub mode resolves sha256(argv)
# fixtures; the audit verb already has a `audit --lighthouse` fixture from
# the part 1 fixture seed.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-audit: --lighthouse routes to cdt-mcp via lib-stub fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-audit.sh" --lighthouse
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q '"event":"audit"' \
    || fail "expected audit event in output"
}

@test "browser-audit: emits summary with verb=audit, tool=chrome-devtools-mcp, status=ok" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-audit.sh" --lighthouse
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "audit" and .tool == "chrome-devtools-mcp" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-audit: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-audit.sh" --tool ghost-tool --lighthouse
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-audit: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-audit.sh" --dry-run --lighthouse
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "audit" and .dry_run == true' >/dev/null
}

@test "browser-audit: --tool=playwright-cli fails (capability filter rejects audit)" {
  run bash "${SCRIPTS_DIR}/browser-audit.sh" --tool playwright-cli --lighthouse
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}
