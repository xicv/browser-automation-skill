load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "lint: passes on the canonical playwright-cli adapter" {
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --static-only
  assert_status 0
}

@test "lint: fails when a fake adapter is missing required functions" {
  fake="${TEST_HOME}/lib/tool/badtool.sh"
  mkdir -p "$(dirname "${fake}")"
  cat > "${fake}" <<'EOF'
just_a_comment=1
EOF
  LIB_TOOL_DIR="$(dirname "${fake}")" run bash "${BATS_TEST_DIRNAME}/lint.sh" --static-only
  [ "${status}" -ne 0 ] || fail "lint should fail for adapter missing required functions"
  assert_output_contains "missing required function"
}

@test "lint: fails when adapter has cd at file scope" {
  fake="${TEST_HOME}/lib/tool/badtool.sh"
  mkdir -p "$(dirname "${fake}")"
  cat > "${fake}" <<'EOF'
cd /tmp
tool_metadata() { :; }
tool_capabilities() { :; }
tool_doctor_check() { :; }
tool_open() { :; }
tool_click() { :; }
tool_fill() { :; }
tool_snapshot() { :; }
tool_inspect() { :; }
tool_audit() { :; }
tool_extract() { :; }
tool_eval() { :; }
EOF
  LIB_TOOL_DIR="$(dirname "${fake}")" run bash "${BATS_TEST_DIRNAME}/lint.sh" --static-only
  [ "${status}" -ne 0 ] || fail "lint should fail for cd at file scope"
  assert_output_contains "cd at file scope"
}

@test "lint: fails when adapter has no corresponding *_adapter.bats" {
  fake="${TEST_HOME}/lib/tool/lonely.sh"
  mkdir -p "$(dirname "${fake}")"
  cat > "${fake}" <<'EOF'
tool_metadata() { :; }
tool_capabilities() { :; }
tool_doctor_check() { :; }
tool_open() { :; }
tool_click() { :; }
tool_fill() { :; }
tool_snapshot() { :; }
tool_inspect() { :; }
tool_audit() { :; }
tool_extract() { :; }
tool_eval() { :; }
EOF
  LIB_TOOL_DIR="$(dirname "${fake}")" \
  REPO_ROOT="${TEST_HOME}" \
    run bash "${BATS_TEST_DIRNAME}/lint.sh" --static-only
  [ "${status}" -ne 0 ] || fail "lint should fail when adapter has no test bats file"
  assert_output_contains "missing tests/lonely_adapter.bats"
}

@test "lint: dynamic tier — passes for canonical playwright-cli" {
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --dynamic-only
  assert_status 0
}

@test "lint: dynamic tier — fails when tool_metadata.name doesn't match filename" {
  fake_dir="${TEST_HOME}/lib/tool"
  mkdir -p "${fake_dir}" "${TEST_HOME}/tests" "${TEST_HOME}/references"
  cat > "${fake_dir}/foo.sh" <<'EOF'
tool_metadata() { printf '{"name":"NOT_FOO","abi_version":1,"version_pin":"any","cheatsheet_path":"references/foo.md"}\n'; }
tool_capabilities() { printf '{"verbs":{}}\n'; }
tool_doctor_check() { printf '{"ok":true}\n'; }
tool_open()    { :; }
tool_click()   { :; }
tool_fill()    { :; }
tool_snapshot(){ :; }
tool_inspect() { :; }
tool_audit()   { :; }
tool_extract() { :; }
tool_eval()    { :; }
EOF
  touch "${TEST_HOME}/tests/foo_adapter.bats"
  touch "${TEST_HOME}/references/foo.md"
  cp -r "${REPO_ROOT}/scripts" "${TEST_HOME}/scripts"
  LIB_TOOL_DIR="${fake_dir}" REPO_ROOT="${TEST_HOME}" \
    run bash "${BATS_TEST_DIRNAME}/lint.sh" --dynamic-only
  [ "${status}" -ne 0 ] || fail "lint should fail when name doesn't match filename"
  assert_output_contains "doesn't match filename"
}

@test "lint: drift tier — passes when generated docs are in sync" {
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --drift-only
  assert_status 0
}

@test "lint: drift tier — fails when references/tool-versions.md is hand-edited" {
  cp "${REPO_ROOT}/references/tool-versions.md" "${REPO_ROOT}/references/tool-versions.md.bak"
  printf '\nstale-junk\n' >> "${REPO_ROOT}/references/tool-versions.md"
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --drift-only
  drift_status="${status}"
  mv "${REPO_ROOT}/references/tool-versions.md.bak" "${REPO_ROOT}/references/tool-versions.md"
  [ "${drift_status}" -ne 0 ] || fail "lint should fail on stale tool-versions.md"
}

@test "lint: drift tier — output-shape — every adapter sources scripts/lib/output.sh" {
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --drift-only
  assert_status 0
}

@test "lint: drift tier — output-shape — fails when an adapter omits 'source .*output.sh'" {
  cat > "${REPO_ROOT}/scripts/lib/tool/_drift-test-adapter.sh" <<'EOF'
tool_metadata()        { printf '{"name":"_drift-test-adapter","abi_version":1}\n'; }
tool_capabilities()    { printf '{"verbs":{}}\n'; }
tool_doctor_check()    { printf '{"ok":true}\n'; }
tool_open()            { printf '{"verb":"open","status":"ok"}\n'; }
tool_click()           { return 41; }
tool_fill()            { return 41; }
tool_snapshot()        { return 41; }
tool_inspect()         { return 41; }
tool_audit()           { return 41; }
tool_extract()         { return 41; }
tool_eval()            { return 41; }
EOF
  run bash "${BATS_TEST_DIRNAME}/lint.sh" --drift-only
  drift_status="${status}"
  rm -f "${REPO_ROOT}/scripts/lib/tool/_drift-test-adapter.sh"
  [ "${drift_status}" -ne 0 ] || fail "lint should fail on adapter missing 'source .*output.sh'"
}

@test "lint: dynamic tier — fails when adapter abi_version doesn't match framework" {
  fake_dir="${TEST_HOME}/lib/tool"
  mkdir -p "${fake_dir}" "${TEST_HOME}/tests" "${TEST_HOME}/references"
  cat > "${fake_dir}/abimismatch.sh" <<'EOF'
tool_metadata() { printf '{"name":"abimismatch","abi_version":99,"version_pin":"any","cheatsheet_path":"references/x.md"}\n'; }
tool_capabilities() { printf '{"verbs":{}}\n'; }
tool_doctor_check() { printf '{"ok":true}\n'; }
tool_open(){ :; }
tool_click(){ :; }
tool_fill(){ :; }
tool_snapshot(){ :; }
tool_inspect(){ :; }
tool_audit(){ :; }
tool_extract(){ :; }
tool_eval(){ :; }
EOF
  touch "${TEST_HOME}/tests/abimismatch_adapter.bats"
  touch "${TEST_HOME}/references/x.md"
  cp -r "${REPO_ROOT}/scripts" "${TEST_HOME}/scripts"
  LIB_TOOL_DIR="${fake_dir}" REPO_ROOT="${TEST_HOME}" \
    run bash "${BATS_TEST_DIRNAME}/lint.sh" --dynamic-only
  [ "${status}" -ne 0 ] || fail "lint should fail on abi_version mismatch"
  assert_output_contains "abi_version mismatch"
}
