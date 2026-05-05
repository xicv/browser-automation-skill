load helpers

# Phase 5 part 4-ii: tests for `creds-totp` verb + creds-add's
# --totp-secret-stdin flag end-to-end (using keychain-stub backend).

setup() {
  setup_temp_home
  init_paths

  # Defensive stubs (HANDOFF §60 pattern — never let tests hit real keychain).
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"

  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod --url https://app.example.com >/dev/null 2>&1 || true

  RFC_SECRET="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
}
teardown() {
  teardown_temp_home
}

# Helper: create a totp-enabled cred with the RFC test secret stored.
_seed_totp_cred() {
  local name="$1"
  { printf 'pw\0%s' "${RFC_SECRET}"; } | bash "${SCRIPTS_DIR}/browser-creds-add.sh" \
    --site prod --as "${name}" --backend keychain --password-stdin \
    --enable-totp --yes-i-know-totp --totp-secret-stdin >/dev/null
}

@test "creds-add (4-ii): --totp-secret-stdin without --enable-totp fails EXIT_USAGE_ERROR" {
  run bash -c "printf 'pw\\0secret' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as prod--bogus --backend keychain --password-stdin --totp-secret-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
  printf '%s' "${output}" | grep -q "requires --enable-totp" || fail "error should explain requirement"
}

@test "creds-add (4-ii): --totp-secret-stdin missing NUL chunk fails EXIT_USAGE_ERROR" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as prod--no-totp-chunk --backend keychain --password-stdin --enable-totp --yes-i-know-totp --totp-secret-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
  printf '%s' "${output}" | grep -qE "(got only one chunk|no NUL found)" \
    || fail "error should describe missing NUL/chunk"
}

@test "creds-add (4-ii): --enable-totp + --totp-secret-stdin happy path persists totp_enabled + totp slot" {
  _seed_totp_cred "prod--totpgood"
  enabled="$(jq -r .totp_enabled "${BROWSER_SKILL_HOME}/credentials/prod--totpgood.json")"
  [ "${enabled}" = "true" ] || fail "totp_enabled should be true"
  # The TOTP slot is stored in the keychain stub under "prod--totpgood__totp".
  jq -e '.["prod--totpgood__totp"] != null' "${KEYCHAIN_STUB_STORE}" >/dev/null \
    || fail "TOTP slot not stored in keychain stub: $(cat "${KEYCHAIN_STUB_STORE}" 2>/dev/null)"
}

@test "creds-totp (4-ii): generates a 6-digit code for a totp-enabled cred" {
  _seed_totp_cred "prod--totpcode"
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh" --as prod--totpcode
  assert_status 0
  # Last line is the code (summary_json goes to stderr per common.sh; verify
  # by checking that the stdout 1st line is exactly 6 digits).
  code="$(printf '%s\n' "${lines[0]}")"
  [[ "${code}" =~ ^[0-9]{6}$ ]] || fail "expected 6-digit code as first line, got '${code}'"
}

@test "creds-totp (4-ii): refuses cred without totp_enabled" {
  printf 'pw' | bash "${SCRIPTS_DIR}/browser-creds-add.sh" \
    --site prod --as prod--notenabled --backend keychain --password-stdin >/dev/null
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh" --as prod--notenabled
  assert_status "$EXIT_USAGE_ERROR"
  printf '%s' "${output}" | grep -q "not totp_enabled" || fail "error should mention totp_enabled"
}

@test "creds-totp (4-ii): missing --as fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "as is required"
}

@test "creds-totp (4-ii): unknown cred fails EXIT_SITE_NOT_FOUND" {
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh" --as nonexistent
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "credential not found"
}

@test "creds-totp (4-ii): --dry-run skips code generation" {
  _seed_totp_cred "prod--dryrun"
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh" --as prod--dryrun --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  # No 6-digit code line in dry-run output.
  printf '%s\n' "${output}" | grep -qE '^[0-9]{6}$' \
    && fail "dry-run should NOT emit a code" || true
}

@test "creds-totp (4-ii): privacy — TOTP secret never appears in stdout" {
  _seed_totp_cred "prod--privacy"
  run bash "${SCRIPTS_DIR}/browser-creds-totp.sh" --as prod--privacy
  assert_status 0
  printf '%s' "${output}" | grep -q "${RFC_SECRET}" \
    && fail "secret leaked into stdout" || true
}
