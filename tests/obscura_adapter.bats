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

@test "obscura adapter: tool_extract returns 41 (STUB — real impl in 8-1-ii / 8-1-iii)" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_extract"
  [ "${status}" = "41" ] || fail "expected 41 stub, got ${status}"
}

@test "obscura adapter: tool_eval returns 41" {
  run bash -c "source '${LIB_TOOL_DIR}/obscura.sh'; tool_eval"
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
}
