load helpers

# Tests for the playwright-lib node-bridge driver in stub mode. Real mode
# (lazy-imports playwright) lands in a follow-up; the contract here is the
# argv-hash → fixture-lookup behavior that the bash adapter relies on.

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "playwright-lib driver: open --url returns canned navigate event from fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "navigate" and .url == "https://example.com"' >/dev/null
}

@test "playwright-lib driver: snapshot returns canned refs array" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs snapshot
  assert_status 0
  printf '%s' "${output}" | jq -e '.refs | length == 2' >/dev/null
}

@test "playwright-lib driver: click --ref e3 returns canned click event" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs click --ref e3
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "click" and .ref == "e3"' >/dev/null
}

@test "playwright-lib driver: missing fixture exits 41 with structured error" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs nope
  [ "${status}" = "41" ] || fail "expected EXIT_TOOL_UNSUPPORTED_OP (41), got ${status}"
  printf '%s' "${output}" | jq -e '.status == "error" and (.reason | startswith("no fixture"))' >/dev/null
}

@test "playwright-lib driver: STUB_LOG_FILE captures argv (one arg per line, ts-prefixed block)" {
  STUB_LOG_FILE="$(mktemp)"
  BROWSER_SKILL_LIB_STUB=1 \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  grep -q '^open$'                "${STUB_LOG_FILE}"
  grep -q '^--url$'               "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "playwright-lib driver: real mode for stateful verbs (snapshot/click/fill/login) returns 41 with daemon-mode hint" {
  # `open` real-mode is implemented (single-shot launch+navigate+close).
  # Stateful verbs require a long-lived browser shared across invocations —
  # daemon mode lands in Phase 4 part 4. Until then they error with hint.
  unset BROWSER_SKILL_LIB_STUB
  run bash -c "node scripts/lib/node/playwright-driver.mjs snapshot 2>&1"
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  echo "${output}" | grep -qE "Phase 4 part 4b|daemon mode" || fail "expected deferred-mode hint, got: ${output}"
}

# --- Adapter contract ---

@test "playwright-lib adapter: file exists and is readable" {
  [ -f "${LIB_TOOL_DIR}/playwright-lib.sh" ] || fail "adapter file missing"
  [ -r "${LIB_TOOL_DIR}/playwright-lib.sh" ] || fail "adapter not readable"
}

@test "playwright-lib adapter: tool_metadata returns valid JSON with required keys + install_hint" {
  result="$(adapter_run_query playwright-lib tool_metadata)"
  printf '%s' "${result}" | jq -e '.name and .abi_version and .version_pin and .cheatsheet_path and .install_hint' >/dev/null
}

@test "playwright-lib adapter: tool_metadata.name == 'playwright-lib' (matches filename)" {
  result="$(adapter_run_query playwright-lib tool_metadata)"
  [ "$(printf '%s' "${result}" | jq -r .name)" = "playwright-lib" ]
}

@test "playwright-lib adapter: tool_metadata.abi_version == BROWSER_SKILL_TOOL_ABI" {
  result="$(adapter_run_query playwright-lib tool_metadata)"
  expected="$(bash -c "source '${LIB_DIR}/common.sh'; printf '%s' \"\${BROWSER_SKILL_TOOL_ABI}\"")"
  [ "$(printf '%s' "${result}" | jq -r .abi_version)" = "${expected}" ]
}

@test "playwright-lib adapter: tool_capabilities declares session_load: true" {
  result="$(adapter_run_query playwright-lib tool_capabilities)"
  printf '%s' "${result}" | jq -e '.session_load == true' >/dev/null
}

@test "playwright-lib adapter: tool_capabilities.fill.flags includes --secret-stdin (Phase 4 promise)" {
  result="$(adapter_run_query playwright-lib tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.fill.flags | index("--secret-stdin")' >/dev/null
}

@test "playwright-lib adapter: tool_capabilities.verbs.login exists (replaces Phase-2 stub)" {
  result="$(adapter_run_query playwright-lib tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.login' >/dev/null
}

@test "playwright-lib adapter: tool_doctor_check returns valid JSON with .ok boolean" {
  result="$(adapter_run_query playwright-lib tool_doctor_check)"
  printf '%s' "${result}" | jq -e '.ok | type == "boolean"' >/dev/null
}

@test "playwright-lib adapter: all 8 verb-dispatch fns + tool_login defined" {
  for fn in tool_open tool_click tool_fill tool_snapshot tool_inspect tool_audit tool_extract tool_eval tool_login; do
    run bash -c "source '${LIB_TOOL_DIR}/playwright-lib.sh' >/dev/null 2>&1; type ${fn} >/dev/null 2>&1"
    [ "${status}" = "0" ] || fail "function ${fn} is not defined"
  done
}

@test "playwright-lib adapter: tool_open dispatches via driver (stub-mode round-trip)" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-lib.sh'; tool_open --url https://example.com"
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "navigate"' >/dev/null
}

@test "playwright-lib adapter: BROWSER_SKILL_STORAGE_STATE forwards as --storage-state to driver" {
  STUB_LOG_FILE="$(mktemp)"
  BROWSER_SKILL_LIB_STUB=1 \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
  BROWSER_SKILL_STORAGE_STATE="/tmp/test-storage.json" \
    run bash -c "source '${LIB_TOOL_DIR}/playwright-lib.sh'; tool_open --url https://example.com"
  # The driver returns 41 here because the argv now includes --storage-state
  # which has no fixture; that's fine — we only verify the env var got
  # forwarded as a flag.
  grep -q '^--storage-state$'      "${STUB_LOG_FILE}"
  grep -q '^/tmp/test-storage.json$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}
