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

# ---------- Phase 7 part 1-iii: --capture wire-up ----------

@test "browser-inspect --capture: writes captures/001/{console.json,network.har,meta.json} + capture_id in summary" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/001/console.json" ] || fail "console.json not written"
  [ -f "${BROWSER_SKILL_HOME}/captures/001/network.har" ] || fail "network.har not written"
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ]   || fail "meta.json not written"
  jq -e '.status == "ok"'      "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  jq -e '.verb == "inspect"'   "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.capture_id == "001"' >/dev/null
}

@test "browser-inspect --capture: dir mode 0700, per-aspect files mode 0600" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  dir_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null)"
  console_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001/console.json" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001/console.json" 2>/dev/null)"
  har_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001/network.har" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001/network.har" 2>/dev/null)"
  [ "${dir_perms}" = "700" ]      || fail "expected dir mode 700, got ${dir_perms}"
  [ "${console_perms}" = "600" ]  || fail "expected console mode 600, got ${console_perms}"
  [ "${har_perms}" = "600" ]      || fail "expected har mode 600, got ${har_perms}"
}

@test "browser-inspect --capture: privacy canary (Authorization Bearer redacted on disk + stdout)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  # On disk: canary absent + ***REDACTED*** present
  ! grep -q "HEADER-CANARY-7-1-iii" "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "Authorization canary leaked to network.har"
  grep -q "REDACTED" "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "expected REDACTED sentinel in network.har"
  # On stdout: canary absent
  printf '%s\n' "${lines[@]}" | grep -q "HEADER-CANARY-7-1-iii" \
    && fail "Authorization canary leaked to stdout" || true
}

@test "browser-inspect --capture: privacy canary (URL api_key + Cookie + Set-Cookie redacted)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  ! grep -q "URL-CANARY-7-1-iii"  "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "URL api_key canary leaked"
  ! grep -q "SESS-CANARY-7-1-iii" "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "Cookie canary leaked"
  ! grep -q "NEW-CANARY-7-1-iii"  "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "Set-Cookie canary leaked"
  grep -q "api_key=\\*\\*\\*"     "${BROWSER_SKILL_HOME}/captures/001/network.har" || fail "expected api_key=*** in url"
}

@test "browser-inspect --capture: privacy canary (console password + token redacted)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  ! grep -q "PWD-CANARY-7-1-iii" "${BROWSER_SKILL_HOME}/captures/001/console.json" || fail "console password canary leaked"
  ! grep -q "TOK-CANARY-7-1-iii" "${BROWSER_SKILL_HOME}/captures/001/console.json" || fail "console token canary leaked"
  grep -q "password: \\*\\*\\*"  "${BROWSER_SKILL_HOME}/captures/001/console.json" || fail "expected password: *** in console.json"
  grep -q "token: \\*\\*\\*"     "${BROWSER_SKILL_HOME}/captures/001/console.json" || fail "expected token: *** in console.json"
}

@test "browser-inspect (no --capture): captures dir not created (clean state)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console
  assert_status 0
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] || fail "captures dir created without --capture flag"
}

# ---------- Phase 7 part 1-iv: --unsanitized typed-phrase opt-out ----------

@test "browser-inspect --unsanitized: typed-phrase mismatch → EXIT_USAGE_ERROR; no captures dir" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "printf '%s\n' 'wrong phrase' | bash '${SCRIPTS_DIR}/browser-inspect.sh' --capture-console --capture-network --capture --unsanitized"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "confirmation mismatch"
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] || fail "captures dir created despite phrase mismatch"
}

@test "browser-inspect --unsanitized: correct phrase → meta.sanitized=false + canary survives raw" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "printf '%s\n' 'I want raw network/console data including auth tokens' | bash '${SCRIPTS_DIR}/browser-inspect.sh' --capture-console --capture-network --capture --unsanitized"
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ] || fail "meta.json not written"
  jq -e '.sanitized == false' "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  # Canaries from the 7-1-iii fixture must survive raw (no redaction applied).
  grep -q "HEADER-CANARY-7-1-iii" "${BROWSER_SKILL_HOME}/captures/001/network.har" \
    || fail "expected raw Authorization canary to survive in unsanitized network.har"
  grep -q "PWD-CANARY-7-1-iii"    "${BROWSER_SKILL_HOME}/captures/001/console.json" \
    || fail "expected raw password canary to survive in unsanitized console.json"
}

@test "browser-inspect --unsanitized: confirmed mode → stdout also RAW (consistent with disk)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "printf '%s\n' 'I want raw network/console data including auth tokens' | bash '${SCRIPTS_DIR}/browser-inspect.sh' --capture-console --capture-network --capture --unsanitized"
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q "HEADER-CANARY-7-1-iii" \
    || fail "expected raw Authorization canary on stdout in --unsanitized mode"
}

@test "browser-inspect (no --unsanitized, default): meta.sanitized=true" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-inspect.sh" --capture-console --capture-network --capture
  assert_status 0
  jq -e '.sanitized == true' "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
}

@test "browser-inspect --unsanitized: leading-whitespace phrase mismatch → error (strict equality)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "printf '%s\n' ' I want raw network/console data including auth tokens' | bash '${SCRIPTS_DIR}/browser-inspect.sh' --capture-console --capture-network --capture --unsanitized"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "confirmation mismatch"
}
