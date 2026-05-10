load helpers

# Phase 9 part 1-iii — flow record (codegen wrapper + JS→YAML transformer +
# password canary). The transformer is pure / unit-testable; the wrapper
# (spawn playwright codegen + capture stdout + write file) is smoke-tested
# with a mock playwright binary.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# --- flow_record_detect_password ---

@test "flow_record_detect_password: 'Email' → no match (exit 1)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_detect_password 'Email'
  "
  [ "${status}" = "1" ] || fail "expected exit 1 for non-password name; got ${status}"
}

@test "flow_record_detect_password: 'Password' → match (exit 0)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_detect_password 'Password'
  "
  assert_status 0
}

@test "flow_record_detect_password: case-insensitive ('password' matches)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_detect_password 'password'
  "
  assert_status 0
}

@test "flow_record_detect_password: substring match ('ConfirmPassword' matches)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_detect_password 'ConfirmPassword'
  "
  assert_status 0
}

# --- flow_record_transform ---

@test "flow_record_transform: simple fixture → name + open + snapshot + fill + click" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_transform simple-record < '${FIXTURES_DIR}/flow-record/simple.codegen.js'
  "
  assert_status 0
  # Steps are indented per YAML convention (2-space indent under `steps:`).
  printf '%s\n' "${output}" | grep -q '^name: simple-record$'
  printf '%s\n' "${output}" | grep -q -E '^  - open: \{ url: https://example\.com/users/new \}$'
  printf '%s\n' "${output}" | grep -q -E '^  - snapshot: \{\}$'
  printf '%s\n' "${output}" | grep -q -E 'fill:.*\$\{refs\.Email\}.*alice@example\.com'
  printf '%s\n' "${output}" | grep -q -E 'click:.*\$\{refs\.Sign in\}'
}

@test "flow_record_transform: with-password fixture → \${secrets.password} placeholder; literal absent" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_transform login-flow < '${FIXTURES_DIR}/flow-record/with-password.codegen.js'
  "
  assert_status 0
  # Placeholder present.
  printf '%s\n' "${output}" | grep -q -F '${secrets.password}' \
    || fail "expected \${secrets.password} placeholder in output"
  # Literal canary value MUST be absent.
  if printf '%s\n' "${output}" | grep -q 'PWD-CANARY-9-1-iii'; then
    fail "PRIVACY CANARY: literal password 'PWD-CANARY-9-1-iii' leaked into transformer output"
  fi
}

@test "flow_record_transform: privacy canary — literal 'PWD-CANARY-...' never on stdout" {
  # Belt-and-suspenders against test 6: ensure the canary is enforced even
  # if the transformer changes its replacement format.
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_transform login-flow < '${FIXTURES_DIR}/flow-record/with-password.codegen.js'
  "
  if printf '%s' "${output}" | grep -q 'PWD-CANARY'; then
    fail "PRIVACY CANARY: any 'PWD-CANARY' substring leaked"
  fi
}

@test "flow_record_transform: xpath selector → TODO comment + skipped" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_transform x < '${FIXTURES_DIR}/flow-record/with-xpath.codegen.js'
  "
  assert_status 0
  printf '%s\n' "${output}" | grep -q -E '#.*TODO.*xpath' \
    || fail "expected TODO comment for unsupported xpath"
  # No click step emitted for the xpath line. Use `|| true` (not
  # `|| printf '0'`) — grep -c already prints "0" on no-match exit 1; doubling
  # would yield "0\n0" and break the comparison.
  click_count="$(printf '%s\n' "${output}" | grep -c '^  - click:' || true)"
  [ "${click_count}" = "0" ] || fail "xpath click should be skipped, got ${click_count}"
}

@test "flow_record_transform: emits stderr audit line per password redaction" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow_record.sh'
    flow_record_transform login-flow < '${FIXTURES_DIR}/flow-record/with-password.codegen.js' 2>&1 1>/dev/null
  "
  printf '%s\n' "${output}" | grep -q -i 'redacted password' \
    || fail "expected audit line on stderr; got: ${output}"
}

# --- browser-flow.sh record ---

@test "browser-flow.sh record: --tool obscura is rejected with EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" record --tool obscura --out /tmp/x.flow.yaml --url https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "obscura"
}

@test "browser-flow.sh record: missing --out fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" record --url https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--out"
}

@test "browser-flow.sh record: mock-codegen via PLAYWRIGHT_CODEGEN_BIN writes flow file mode 0600" {
  out_file="${BROWSER_SKILL_HOME}/recorded.flow.yaml"
  PLAYWRIGHT_CODEGEN_BIN="${STUBS_DIR}/playwright-codegen-mock" \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" record --url https://example.com --out "${out_file}" --name recorded
  assert_status 0
  [ -f "${out_file}" ] || fail "recorded flow file missing"
  mode="$(stat -f '%Lp' "${out_file}" 2>/dev/null || stat -c '%a' "${out_file}" 2>/dev/null)"
  [ "${mode}" = "600" ] || fail "expected mode 600, got ${mode}"
  # Summary line carries flow_name + step_count + password_redactions.
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "flow" and .why == "record" and .flow_name == "recorded"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.password_redactions | type == "number"' >/dev/null
}
