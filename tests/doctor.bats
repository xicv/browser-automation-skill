load helpers

@test "doctor: prints resolved BROWSER_SKILL_HOME at top" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "${BROWSER_SKILL_HOME}"
}

@test "doctor: passes when bash, jq, python3 are present" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "all checks passed"
}

@test "doctor: emits a final JSON summary line on stdout" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "doctor"' >/dev/null
}

@test "doctor: warns when ~/.browser-skill missing" {
  setup_temp_home
  # Don't create BROWSER_SKILL_HOME — should be flagged.
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "does not exist"
}

@test "doctor: warns when ~/.browser-skill mode is not 0700" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 0755 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "mode 755"
  assert_output_contains "expected 700"
}

@test "doctor: prints disk-encryption status (advisory, never fails)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "disk encryption"
}

@test "doctor: missing node fails doctor (required from Phase 3 onward)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  local stub="${TEST_HOME}/bin"
  mkdir -p "${stub}"
  ln -s "$(command -v bash)" "${stub}/bash"
  ln -s "$(command -v jq)" "${stub}/jq"
  ln -s "$(command -v python3)" "${stub}/python3"
  PATH="${stub}:/usr/sbin:/bin:/usr/bin" run "${stub}/bash" "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "node NOT FOUND"
}

@test "doctor: reports each adapter under lib/tool/ as a check line" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "playwright-cli"
}

@test "doctor: streams a JSON line per adapter with check=adapter and adapter=<name>" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  echo "${output}" | grep -E '^\{.*"check":"adapter"' >/dev/null \
    || fail "no adapter check line found"
  echo "${output}" | grep -E '"adapter":"playwright-cli"' >/dev/null \
    || fail "playwright-cli adapter not reported"
}

@test "doctor: summary includes adapters_ok and adapters_failed counts" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e 'has("adapters_ok") and has("adapters_failed")' >/dev/null \
    || fail "summary does not include adapter counts"
}

@test "doctor: well-formed status field even when adapter binary is missing" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.status' >/dev/null
}

@test "doctor: prints credentials count line (zero state)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "credentials: 0 total"
}

@test "doctor: credentials count line reflects per-backend breakdown" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/credentials"
  # Hand-write a plaintext-backed credential metadata file so we don't need
  # to invoke creds-add (which requires --site / --as / stub bins).
  cat > "${BROWSER_SKILL_HOME}/credentials/test--cred.json" <<'EOF'
{"schema_version":1,"name":"test--cred","site":"test","account":"a@b.c","backend":"plaintext","auth_flow":"single-step-username-password","auto_relogin":true,"totp_enabled":false,"created_at":"2026-05-03T00:00:00Z"}
EOF
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/test--cred.json"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "credentials: 1 total"
  assert_output_contains "plaintext: 1"
}
