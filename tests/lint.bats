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
