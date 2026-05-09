load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "obscura adapter: file exists and is readable" {
  [ -f "${LIB_TOOL_DIR}/obscura.sh" ] || fail "adapter file missing"
  [ -r "${LIB_TOOL_DIR}/obscura.sh" ] || fail "adapter not readable"
}

@test "obscura adapter: tool_metadata returns valid JSON" {
  run adapter_run_query obscura tool_metadata
  assert_status 0
  printf '%s' "${output}" | jq -e . >/dev/null
}

@test "obscura adapter: tool_metadata.name == 'obscura' (matches filename)" {
  result="$(adapter_run_query obscura tool_metadata)"
  [ "$(printf '%s' "${result}" | jq -r .name)" = "obscura" ]
}

@test "obscura adapter: tool_metadata.abi_version == BROWSER_SKILL_TOOL_ABI" {
  result="$(adapter_run_query obscura tool_metadata)"
  expected="$(bash -c "source '${LIB_DIR}/common.sh'; printf '%s' \"\${BROWSER_SKILL_TOOL_ABI}\"")"
  [ "$(printf '%s' "${result}" | jq -r .abi_version)" = "${expected}" ]
}

@test "obscura adapter: tool_metadata has version_pin and cheatsheet_path" {
  result="$(adapter_run_query obscura tool_metadata)"
  printf '%s' "${result}" | jq -e '.version_pin and .cheatsheet_path' >/dev/null
}

@test "obscura adapter: tool_capabilities returns valid JSON with .verbs" {
  result="$(adapter_run_query obscura tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs' >/dev/null
}

@test "obscura adapter: tool_capabilities.verbs.extract exists (the unique-lane verb)" {
  result="$(adapter_run_query obscura tool_capabilities)"
  printf '%s' "${result}" | jq -e '.verbs.extract' >/dev/null
}

@test "obscura adapter: tool_capabilities does NOT declare stateful nav verbs (open/click/fill/snapshot)" {
  # Obscura is a one-shot fetch/scrape adapter; stateful navigation belongs to
  # playwright-cli / playwright-lib / chrome-devtools-mcp. Asserting the lane
  # boundary at the capability layer keeps the router from falling back to
  # obscura for verbs it can't actually serve.
  result="$(adapter_run_query obscura tool_capabilities)"
  for verb in open click fill snapshot; do
    printf '%s' "${result}" | jq -e --arg v "${verb}" '.verbs | has($v) | not' >/dev/null \
      || fail "obscura must not declare verb=${verb}"
  done
}

@test "obscura adapter: tool_doctor_check returns valid JSON with .ok boolean" {
  result="$(adapter_run_query obscura tool_doctor_check)"
  printf '%s' "${result}" | jq -e '.ok | type == "boolean"' >/dev/null
}

@test "obscura adapter: all 8 verb-dispatch functions are defined" {
  for fn in tool_open tool_click tool_fill tool_snapshot tool_inspect tool_audit tool_extract tool_eval; do
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh' >/dev/null 2>&1; type ${fn} >/dev/null 2>&1"
    [ "${status}" = "0" ] || fail "function ${fn} is not defined"
  done
}

@test "obscura adapter: tool_open returns 41 (one-shot adapter; no stateful navigation)" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_open --url https://example.com"
  [ "${status}" = "41" ] || fail "expected EXIT_TOOL_UNSUPPORTED_OP (41), got ${status}"
}

@test "obscura adapter: tool_click returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_click --ref e3"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

@test "obscura adapter: tool_fill returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_fill --ref e3 --text foo"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

@test "obscura adapter: tool_snapshot returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_snapshot"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

@test "obscura adapter: tool_inspect returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_inspect"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

@test "obscura adapter: tool_audit returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_audit"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

@test "obscura adapter: tool_extract without flags returns 41 (8-1-iii / other modes deferred)" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract"
  [ "${status}" = "41" ] || fail "expected 41 (no-mode), got ${status}"
}

@test "obscura adapter: tool_eval returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_eval"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}

# --- Phase 8 part 1-ii: tool_extract --scrape real-mode ---

@test "obscura adapter (8-1-ii): tool_extract --scrape with 3 URLs + --eval emits 3 scrape_url events" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape --eval document.title https://example.com https://example.org https://example.net"
  assert_status 0
  # Three event lines, one per URL.
  count="$(printf '%s\n' "${output}" | jq -e -s 'map(select(.event=="scrape_url")) | length')"
  [ "${count}" = "3" ] || fail "expected 3 scrape_url events, got ${count}"
  # First event has expected fields.
  printf '%s' "${lines[0]}" | jq -e '.url == "https://example.com" and .title == "Example Domain" and (.eval | type == "string")' >/dev/null
}

@test "obscura adapter (8-1-ii): tool_extract --scrape mixed-results emits success + error events" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape --eval document.title https://a.example.com https://b.example.com https://c.example.com"
  assert_status 0
  # 3 total events; 2 with .title (success), 1 with .error (failure).
  succ="$(printf '%s\n' "${output}" | jq -s 'map(select(.event=="scrape_url" and (.title // false))) | length')"
  err="$(printf '%s\n'  "${output}" | jq -s 'map(select(.event=="scrape_url" and (.error // false))) | length')"
  [ "${succ}" = "2" ] || fail "expected 2 success events, got ${succ}"
  [ "${err}"  = "1" ] || fail "expected 1 error event, got ${err}"
}

@test "obscura adapter (8-1-ii): tool_extract --scrape with no URLs returns 2 (USAGE_ERROR)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape --eval document.title"
  [ "${status}" = "2" ] || fail "expected EXIT_USAGE_ERROR (2) for empty URL list, got ${status}"
}

@test "obscura adapter (8-1-ii): tool_extract --scrape without --eval emits events with eval:null" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape https://example.com https://example.org"
  assert_status 0
  printf '%s' "${lines[0]}" | jq -e '.eval == null' >/dev/null \
    || fail "first event should have eval=null when --eval omitted"
}

@test "obscura adapter (8-1-ii): tool_extract --scrape passes scrape + URLs + --format json to obscura argv" {
  STUB_LOG_FILE="$(mktemp)"
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape --eval document.title https://example.com https://example.org https://example.net"
  assert_status 0
  grep -qE '^scrape$'                "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing scrape subcommand"; }
  grep -qE '^https://example\.com$'  "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing url 1"; }
  grep -qE '^https://example\.org$'  "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing url 2"; }
  grep -qE '^--eval$'                "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing --eval"; }
  grep -qE '^--format$'              "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing --format"; }
  grep -qE '^json$'                  "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing json"; }
  rm -f "${STUB_LOG_FILE}"
}

@test "obscura adapter (8-1-ii): stub --version short-circuits before fixture lookup (doctor + install tests stay green)" {
  STUB_LOG_FILE="$(mktemp)"
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run "${STUBS_DIR}/obscura" --version
  assert_status 0
  printf '%s' "${output}" | grep -qE '^obscura ' || fail "stub --version should print version line"
  # MUST NOT log to STUB_LOG_FILE — the short-circuit happens before the log write.
  [ ! -s "${STUB_LOG_FILE}" ] || { rm -f "${STUB_LOG_FILE}"; fail "stub --version should NOT touch STUB_LOG_FILE"; }
  rm -f "${STUB_LOG_FILE}"
}

# --- Phase 8 part 1-iii: tool_extract --stealth real-mode (single-URL fetch) ---

@test "obscura adapter (8-1-iii): tool_extract --stealth --eval EXPR <url> emits 1 extract_stealth event" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --stealth --eval document.title https://example.com"
  assert_status 0
  # Adapter doesn't fabricate time_ms (obscura fetch doesn't report it; the
  # verb-script's summary already carries end-to-end duration_ms).
  count="$(printf '%s\n' "${output}" | jq -e -s 'map(select(.event=="extract_stealth")) | length')"
  [ "${count}" = "1" ] || fail "expected 1 extract_stealth event, got ${count}"
  printf '%s' "${lines[0]}" | jq -e '.url == "https://example.com" and .eval == "Example Domain"' >/dev/null
}

@test "obscura adapter (8-1-iii): tool_extract --stealth without URL returns 2 (USAGE_ERROR)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --stealth --eval document.title"
  [ "${status}" = "2" ] || fail "expected USAGE_ERROR (2) for no-URL stealth, got ${status}"
}

@test "obscura adapter (8-1-iii): tool_extract --stealth without --eval returns 2 (USAGE_ERROR)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --stealth https://example.com"
  [ "${status}" = "2" ] || fail "expected USAGE_ERROR (2) for missing --eval, got ${status}"
}

@test "obscura adapter (8-1-iii): tool_extract --scrape --stealth → 41 (modes mutually exclusive)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --scrape --stealth --eval document.title https://example.com"
  [ "${status}" = "41" ] || fail "expected 41 for mutually-exclusive modes, got ${status}"
}

@test "obscura adapter (8-1-iii): tool_extract --stealth passes fetch + url + --stealth + --eval to obscura argv" {
  STUB_LOG_FILE="$(mktemp)"
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract --stealth --eval document.title https://example.com"
  assert_status 0
  grep -qE '^fetch$'                "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing fetch subcommand"; }
  grep -qE '^https://example\.com$' "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing url"; }
  grep -qE '^--stealth$'            "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing --stealth"; }
  grep -qE '^--eval$'               "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing --eval"; }
  grep -qE '^document\.title$'      "${STUB_LOG_FILE}" || { rm -f "${STUB_LOG_FILE}"; fail "missing eval-expr"; }
  # MUST NOT contain --format json (that's --scrape only; obscura fetch has no --format)
  if grep -qE '^--format$' "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"; fail "stealth mode should NOT pass --format flag (only --scrape does)"
  fi
  rm -f "${STUB_LOG_FILE}"
}
